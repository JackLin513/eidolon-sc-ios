import AVFoundation
import EidolonCore
import Foundation
import OSLog

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
    private var observers: [NSObjectProtocol] = []

    func start() async throws {
        guard await Self.microphoneAllowed() else {
            throw CaptureError.notPermitted
        }
        setHearingNow(true)
        try await openSession()
        let source = try await installAndStart()
        markRunning()
        observeAudioSession()
        Logger(subsystem: "com.jacklin.eidolon", category: "call")
            .notice("microphone open: \(source.sampleRate) Hz, \(source.channelCount) ch")
    }

    func stop() async {
        stopObservingAudioSession()
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
    /// returns to the foreground, where the engine may have been stopped.
    func recover() async {
        guard isRunning(), beginRecovery() else { return }
        defer { endRecovery() }
        do {
            try await activateSession()
            // Always reinstall: the engine can still report itself running after an
            // interruption or a services reset while no audio comes through.
            _ = try await installAndStart()
            Logger(subsystem: "com.jacklin.eidolon", category: "call")
                .notice("microphone recovered")
        } catch {
            Logger(subsystem: "com.jacklin.eidolon", category: "call")
                .error("microphone could not recover: \(error.localizedDescription)")
        }
    }

    // MARK: - Opening

    private func openSession() async throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.defaultToSpeaker, .allowBluetoothHFP]
        )
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
        let source = try await Self.waitForInputFormat(input)
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
        input.installTap(onBus: 0, bufferSize: 1024, format: source) { [weak self] buffer, _ in
            self?.push(buffer, converter: converter, target: target)
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

    // MARK: - The system taking the microphone away

    private func observeAudioSession() {
        let center = NotificationCenter.default
        observers.append(
            center.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let self,
                      let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      let type = AVAudioSession.InterruptionType(rawValue: raw)
                else { return }
                switch type {
                case .began:
                    break
                case .ended:
                    let rawOptions = notification
                        .userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                    if AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume) {
                        Task { await self.recover() }
                    }
                @unknown default:
                    break
                }
            }
        )
        observers.append(
            center.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                Task { await self.recover() }
            }
        )
        observers.append(
            center.addObserver(
                forName: AVAudioSession.mediaServicesWereResetNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                // Every audio object is invalid after a reset: start from a fresh engine.
                self.replaceEngine(AVAudioEngine())
                Task { await self.recover() }
            }
        )
    }

    private func stopObservingAudioSession() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
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
        if installed { currentEngine().inputNode.removeTap(onBus: 0) }
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

        var errorDescription: String? {
            switch self {
            case .notPermitted:
                return "没有麦克风权限，请在系统设置里允许"
            case .noInput:
                return "读不到麦克风：在 Mac 的系统设置 → 隐私与安全性 → 麦克风里允许 Simulator，然后重新通话"
            case .unsupportedFormat:
                return "麦克风格式不受支持"
            }
        }
    }
}
