import AVFoundation
import EidolonCore
import Foundation
import OSLog
import UIKit

/// The microphone as a call hears it (ADR-0007): the input node's audio, converted to
/// 16 kHz mono PCM16 chunks for the recognizer. The audio session runs in `.voiceChat`,
/// so the system cancels the echo of what is being played.
///
/// The system can take the microphone away mid-call — a phone call, Siri, headphones
/// plugged or pulled, or media services resetting — or leave it stopped when the app comes
/// back from the background. The call notices all of those and opens it again; the
/// recognizer's stream stays the same (spec「通话健壮性」).
final class MicrophoneCapture: AudioCapture, @unchecked Sendable {
    private var engine = AVAudioEngine()
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<Data, Error>.Continuation?
    private var running = false
    private var tapInstalled = false
    /// Whether tap buffers reach the recognizer. Closed while her own voice plays, so the
    /// microphone does not hear the speaker (ADR-0015).
    private var hearing = true
    /// One recovery at a time: the interruption end, the route change and the foreground
    /// return can all arrive together.
    private var recovering = false
    /// When the last recovery succeeded. Reconfiguring the session and restarting the engine
    /// posts route changes of their own; without a quiet window each one would ask for
    /// another recovery and the engine would never settle.
    private var recoveredAt = Date.distantPast

    func start() async throws {
        guard await Self.microphoneAllowed() else {
            throw CaptureError.notPermitted
        }
        setHearingNow(true)
        try await openSession()
        let source = try await installAndStart()
        markRunning()
        Logger(subsystem: "com.jacklin.eidolon", category: "call")
            .notice("microphone open: \(source.sampleRate) Hz, \(source.channelCount) ch")
    }

    func stop() async {
        let (wasRunning, continuation) = takeContinuation()
        if wasRunning {
            currentEngine().stop()
        }
        removeTapIfNeeded()
        continuation?.finish()
        let session = AVAudioSession.sharedInstance()
        if #available(iOS 27.0, *) {
            _ = try? await session.deactivate(options: .notifyOthersOnDeactivation)
        } else {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
        }
        // `.playAndRecord` means a call holds the session — the hang-up tone reads it to
        // decide whether it has one to play on. Put the category back now that this call has
        // let go, or a later call that never gets the microphone would mistake the stale
        // category for a live session and play its tone on the wrong route.
        try? session.setCategory(.ambient, mode: .default, options: [])
    }

    func chunks() -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            // Each listening connection gets its own stream; the one before it is closed
            // rather than left waiting for audio that will never come.
            replaceContinuation(continuation)?.finish()
        }
    }

    func setHearing(_ hearing: Bool) async {
        setHearingNow(hearing)
    }

    /// Open the microphone again if the system left it closed. Also called when the app
    /// returns to the foreground, where the engine may have been stopped. Says whether the
    /// input feeds the call after the attempt (spec #41).
    func recover() async -> Bool {
        await recover(forced: false)
    }

    func recoverAfterForeground() async -> Bool {
        await recover(forced: true)
    }

    private func recover(forced: Bool) async -> Bool {
        guard isRunning() else { return true }
        // Nothing can be opened while the app is in the background or inactive, and the
        // call asks again when it is active: trying here only fails and stops the engine.
        guard await Self.applicationIsActive() else { return true }
        // A recovery already under way will report its own result.
        guard beginRecovery() else { return true }
        defer { endRecovery() }
        // A route change that came from this very recovery is not another disruption;
        // coming back to the foreground is a real one and is never held off.
        if !forced, recoveryIsTooSoon() {
            return true
        }
        do {
            // The session may belong to something else by now: 朗读 switches it to
            // `.playback`, and a recovery that only activated it would install the input
            // tap on a playback session — AVFAudio raises an Objective-C exception for
            // that, which aborts the app. Put the call's own configuration back first.
            try await openSession()
            // Always reinstall: the engine can still report itself running after an
            // interruption or a services reset while no audio comes through.
            do {
                _ = try await installAndStart()
            } catch CaptureError.tapRefused {
                // A tap refused right after a route change may be reading a graph that is
                // already stale; one fresh engine is worth a second try before giving up.
                replaceEngine(AVAudioEngine())
                try await openSession()
                _ = try await installAndStart()
            }
            markRecovered()
            Logger(subsystem: "com.jacklin.eidolon", category: "call")
                .notice("microphone recovered")
            return true
        } catch {
            Logger(subsystem: "com.jacklin.eidolon", category: "call")
                .error("microphone could not recover: \(error.localizedDescription)")
            return false
        }
    }

    /// The system actions that can take the microphone away, for the call to answer
    /// (spec #41). Replacing the engine after a media services reset stays here, since
    /// every audio object is invalid after one.
    func disruptions() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let center = NotificationCenter.default
            let interruption = center.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: nil,
                queue: .main
            ) { notification in
                guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      let type = AVAudioSession.InterruptionType(rawValue: raw),
                      type == .ended
                else { return }
                let rawOptions = notification
                    .userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                if AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume) {
                    continuation.yield(())
                }
            }
            let route = center.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: nil,
                queue: .main
            ) { _ in
                continuation.yield(())
            }
            let reset = center.addObserver(
                forName: AVAudioSession.mediaServicesWereResetNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                // Every audio object is invalid after a reset: start from a fresh engine.
                self?.replaceEngine(AVAudioEngine())
                continuation.yield(())
            }
            continuation.onTermination = { _ in
                for observer in [interruption, route, reset] {
                    NotificationCenter.default.removeObserver(observer)
                }
            }
        }
    }

    // MARK: - Opening

    private func openSession() async throws {
        let session = AVAudioSession.sharedInstance()
        let options: AVAudioSession.CategoryOptions = [.defaultToSpeaker, .allowBluetoothHFP]
        // Setting the same category again still posts a route change on some routes, and
        // every route change asks for another recovery: only change what is not already so.
        if session.category != .playAndRecord
            || session.mode != .voiceChat
            || session.categoryOptions != options {
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: options)
        }
        try await activateSession()
    }

    private func activateSession() async throws {
        let session = AVAudioSession.sharedInstance()
        if #available(iOS 27.0, *) {
            try await session.activate(options: [])
        } else {
            try session.setActive(true)
        }
    }

    /// Install the input tap and start the engine, returning the input format it runs at.
    /// An engine that is running is stopped first: a tap cannot be replaced under it.
    @discardableResult
    private func installAndStart() async throws -> AVAudioFormat {
        let engine = currentEngine()
        let input = engine.inputNode
        engine.prepare()
        // The input format is zero until the session has a route; installing a tap with
        // it raises an Objective-C exception, which would abort the app (seen on the
        // simulator when the host app has no microphone permission). Wait, then refuse.
        _ = try await Self.waitForInputFormat(input)
        // The format is read again here, after the wait: a route can change while it is
        // being waited for, and a tap installed with the old format raises.
        guard AVAudioSession.sharedInstance().isInputAvailable else {
            throw CaptureError.noInput
        }
        let source = input.inputFormat(forBus: 0)
        guard source.sampleRate >= 8_000, source.channelCount > 0 else {
            throw CaptureError.noInput
        }
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        ), let converter = AVAudioConverter(from: source, to: target) else {
            throw CaptureError.unsupportedFormat
        }

        if engine.isRunning {
            engine.stop()
        }
        removeTapIfNeeded()
        // AVFAudio reports a tap it will not install as an Objective-C exception, which
        // Swift cannot catch; caught here, a recovery fails instead of aborting the app.
        let refused = EIDCatchObjectiveCException {
            input.installTap(onBus: 0, bufferSize: 1024, format: source) { [weak self] buffer, _ in
                self?.push(buffer, converter: converter, target: target)
            }
        }
        if let refused {
            Logger(subsystem: "com.jacklin.eidolon", category: "call")
                .error("microphone tap refused: \(refused)")
            throw CaptureError.tapRefused
        }
        markTapInstalled()
        do {
            try engine.start()
        } catch {
            removeTapIfNeeded()
            throw error
        }
        return source
    }

    // MARK: - State

    private func currentEngine() -> AVAudioEngine {
        lock.lock()
        defer { lock.unlock() }
        return engine
    }

    private func replaceEngine(_ next: AVAudioEngine) {
        lock.lock()
        engine = next
        tapInstalled = false
        lock.unlock()
    }

    private func beginRecovery() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !recovering else { return false }
        recovering = true
        return true
    }

    private func endRecovery() {
        lock.lock()
        recovering = false
        lock.unlock()
    }

    private func recoveryIsTooSoon() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return Date().timeIntervalSince(recoveredAt) < 1
    }

    private func markRecovered() {
        lock.lock()
        recoveredAt = Date()
        lock.unlock()
    }

    private func setHearingNow(_ hearing: Bool) {
        lock.lock()
        self.hearing = hearing
        lock.unlock()
    }

    private func isHearing() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return hearing
    }

    private func markRunning() {
        lock.lock()
        running = true
        lock.unlock()
    }

    private func isRunning() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    private func markTapInstalled() {
        lock.lock()
        tapInstalled = true
        lock.unlock()
    }

    private func removeTapIfNeeded() {
        lock.lock()
        let installed = tapInstalled
        tapInstalled = false
        lock.unlock()
        guard installed else { return }
        // The same kind of exception can come from removing a tap the system already took.
        let input = currentEngine().inputNode
        let refused = EIDCatchObjectiveCException { input.removeTap(onBus: 0) }
        if let refused {
            Logger(subsystem: "com.jacklin.eidolon", category: "call")
                .error("microphone tap would not be removed: \(refused)")
        }
    }

    /// The input format becomes valid once the session is active and routed; on the
    /// simulator it can stay empty when the host app may not use the microphone.
    private static func waitForInputFormat(_ input: AVAudioInputNode) async throws -> AVAudioFormat {
        for _ in 0..<60 {
            let format = input.inputFormat(forBus: 0)
            if format.sampleRate >= 8_000, format.channelCount > 0 {
                return format
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        Logger(subsystem: "com.jacklin.eidolon", category: "call")
            .error("microphone input format never became valid")
        throw CaptureError.noInput
    }

    private func takeContinuation() -> (Bool, AsyncThrowingStream<Data, Error>.Continuation?) {
        lock.lock()
        defer { lock.unlock() }
        let wasRunning = running
        running = false
        let taken = continuation
        continuation = nil
        return (wasRunning, taken)
    }

    private func replaceContinuation(
        _ next: AsyncThrowingStream<Data, Error>.Continuation
    ) -> AsyncThrowingStream<Data, Error>.Continuation? {
        lock.lock()
        let previous = continuation
        continuation = next
        lock.unlock()
        return previous
    }

    private func push(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter, target: AVAudioFormat) {
        // Dropped here, before the stream, so a buffer taken while she spoke can never be
        // handed to the recognizer after the microphone opens again.
        guard isHearing() else { return }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            return
        }
        var fed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, output.frameLength > 0, let data = output.int16ChannelData?[0] else {
            return
        }
        let bytes = Data(
            bytes: data,
            count: Int(output.frameLength) * MemoryLayout<Int16>.size
        )
        lock.lock()
        let continuation = self.continuation
        lock.unlock()
        continuation?.yield(bytes)
    }


    private var debugPushCount = 0
    private var debugLastPushAt = Date.distantPast

    private func debugCount(hearing: Bool) {
        lock.lock()
        debugPushCount += 1
        let count = debugPushCount
        lock.unlock()
        if count == 1 || count % 100 == 0 {
        }
    }

    private func debugPush(frames: AVAudioFrameCount, samples: UnsafeMutablePointer<Int16>, continuation: Bool) {
        let now = Date()
        lock.lock()
        let due = now.timeIntervalSince(debugLastPushAt) >= 1
        if due { debugLastPushAt = now }
        lock.unlock()
        guard due else { return }
        var sum = 0.0
        let n = min(Int(frames), 512)
        for i in 0..<n {
            let v = Double(samples[i]) / 32768.0
            sum += v * v
        }
        let rms = n > 0 ? (sum / Double(n)).squareRoot() : 0
    }

    /// Whether the app can use the session at all right now.
    private static func applicationIsActive() async -> Bool {
        await MainActor.run { UIApplication.shared.applicationState == .active }
    }

    private static func microphoneAllowed() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            return await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default:
            return false
        }
    }

    enum CaptureError: LocalizedError {
        case notPermitted
        case noInput
        case unsupportedFormat
        case tapRefused

        var errorDescription: String? {
            switch self {
            case .notPermitted:
                return "没有麦克风权限，请在系统设置里允许"
            case .noInput:
                return "读不到麦克风：在 Mac 的系统设置 → 隐私与安全性 → 麦克风里允许 Simulator，然后重新通话"
            case .unsupportedFormat:
                return "麦克风格式不受支持"
            case .tapRefused:
                return "麦克风暂时打不开"
            }
        }
    }
}
