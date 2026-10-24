import AVFoundation
import EidolonCore
import Foundation

/// The microphone as a call hears it (ADR-0007): the input node's audio, converted to
/// 16 kHz mono PCM16 chunks for the recognizer. The audio session runs in `.voiceChat`,
/// so the system cancels the echo of what is being played.
final class MicrophoneCapture: AudioCapture, @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<Data, Error>.Continuation?
    private var running = false

    func start() async throws {
        guard await Self.microphoneAllowed() else {
            throw CaptureError.notPermitted
        }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.defaultToSpeaker, .allowBluetoothHFP]
        )
        // Activation can wait on the route; the asynchronous form does not hold the call.
        if #available(iOS 27.0, *) {
            try await session.activate(options: [])
        } else {
            try session.setActive(true)
        }

        let input = engine.inputNode
        let source = input.outputFormat(forBus: 0)
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        ), let converter = AVAudioConverter(from: source, to: target) else {
            throw CaptureError.unsupportedFormat
        }

        input.installTap(onBus: 0, bufferSize: 1024, format: source) { [weak self] buffer, _ in
            self?.push(buffer, converter: converter, target: target)
        }
        engine.prepare()
        try engine.start()
        markRunning()
    }

    func stop() async {
        let (wasRunning, continuation) = takeContinuation()
        if wasRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        continuation?.finish()
        let session = AVAudioSession.sharedInstance()
        if #available(iOS 27.0, *) {
            try? await session.deactivate(options: .notifyOthersOnDeactivation)
        } else {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    func chunks() -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            setContinuation(continuation)
        }
    }

    private func markRunning() {
        lock.lock()
        running = true
        lock.unlock()
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

    private func setContinuation(_ next: AsyncThrowingStream<Data, Error>.Continuation) {
        lock.lock()
        continuation = next
        lock.unlock()
    }

    private func push(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter, target: AVAudioFormat) {
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
        case unsupportedFormat

        var errorDescription: String? {
            switch self {
            case .notPermitted:
                return "没有麦克风权限，请在系统设置里允许"
            case .unsupportedFormat:
                return "麦克风格式不受支持"
            }
        }
    }
}
