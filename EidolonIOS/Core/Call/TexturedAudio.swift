import AVFoundation
import EidolonCore
import Foundation
import OSLog

/// Puts one synthesized segment through 电话质感 before it is played (spec #36): decode
/// the MP3, run every channel through the telephone line, and encode the result as a WAV
/// in memory. Nil means the segment could not be made over and is played as it came.
enum TexturedAudio {
    private static let log = Logger(subsystem: "com.jacklin.eidolon", category: "call")

    static func wav(fromMP3 mp3: Data) -> Data? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("eidolon-voice-\(UUID().uuidString).mp3")
        do {
            try mp3.write(to: url)
            defer { try? FileManager.default.removeItem(at: url) }
            let file = try AVAudioFile(forReading: url)
            let format = file.processingFormat
            let frames = AVAudioFrameCount(file.length)
            guard frames > 0 else {
                log.error("phone texture skipped: the segment decoded to no frames")
                return nil
            }
            guard format.commonFormat == .pcmFormatFloat32, format.channelCount > 0 else {
                log.error("phone texture skipped: unexpected decoding format")
                return nil
            }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
                log.error("phone texture skipped: no buffer for \(frames) frames")
                return nil
            }
            try file.read(into: buffer)
            guard let channels = buffer.floatChannelData else {
                log.error("phone texture skipped: the decoded segment has no channel data")
                return nil
            }
            let texture = PhoneTexture(sampleRate: format.sampleRate)
            var processed: [[Float]] = []
            for channel in 0..<Int(format.channelCount) {
                let samples = Array(UnsafeBufferPointer(
                    start: channels[channel],
                    count: Int(buffer.frameLength)
                ))
                processed.append(texture.process(samples))
            }
            return wav(processed, sampleRate: format.sampleRate)
        } catch {
            log.error("phone texture skipped: \(error.localizedDescription)")
            return nil
        }
    }

    /// A 16-bit PCM WAV of the processed channels, whole in memory.
    private static func wav(_ channels: [[Float]], sampleRate: Double) -> Data {
        let channelCount = channels.count
        let frames = channels.first?.count ?? 0
        let dataBytes = frames * channelCount * 2
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + dataBytes))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(channelCount))
        append(UInt32(sampleRate.rounded()))
        append(UInt32((sampleRate * Double(channelCount * 2)).rounded()))
        append(UInt16(channelCount * 2))
        append(UInt16(16))
        data.append(contentsOf: Array("data".utf8))
        append(UInt32(dataBytes))
        for frame in 0..<frames {
            for channel in 0..<channelCount {
                let sample = max(-1, min(1, channels[channel][frame]))
                append(Int16((sample * 32_767).rounded()))
            }
        }
        return data
    }
}
