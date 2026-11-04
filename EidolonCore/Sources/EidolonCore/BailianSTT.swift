import Foundation

/// How a Bailian (DashScope) real-time recognition task is opened, as upstream
/// `bailian.py` does: a duplex `run-task` for 16 kHz PCM, near-field voice detection,
/// Chinese and Japanese, heartbeats, and the call's hot words as the task's vocabulary.
/// Where each region's real-time recognition is (upstream `REGION_URLS`).
public enum BailianSTTEndpoint {
    public static func url(for region: BailianRegion) -> URL {
        switch region {
        case .beijing:
            URL(string: "wss://dashscope.aliyuncs.com/api-ws/v1/inference")!
        case .singapore:
            URL(string: "wss://dashscope-intl.aliyuncs.com/api-ws/v1/inference")!
        }
    }
}

public struct BailianSTTConfiguration: Sendable, Hashable {
    /// The only model that takes turns as the call needs (upstream
    /// `BAILIAN_STT_MODELS`): without `vad_model`, a cough comes out as an empty or
    /// transcribed sentence.
    public static let defaultModel = "qwen-audio-3.1-asr-flash-streaming"
    public static let sampleRate = 16_000
    /// 3.1's real-time transcription is billed in tokens, not seconds (spec #96); the
    /// price catalog converts its audio-token rate to a per-second estimate.
    public static func isTokenBilled(_ model: String) -> Bool {
        model.contains("3.1-asr")
    }
    /// 100 ms of 16-bit mono audio, which DashScope is sent a packet at a time.
    public static let packetBytes = sampleRate * 2 / 10
    public static let hotWordWeight = 4
    public static let latinHotWordWeight = 50
    public static let maxLatinHotWords = 50

    public var model: String
    public var languageHints: [String]
    public var hotWords: [String]

    public init(
        model: String = BailianSTTConfiguration.defaultModel,
        languageHints: [String] = ["zh", "ja"],
        hotWords: [String] = []
    ) {
        self.model = model
        self.languageHints = languageHints
        self.hotWords = hotWords
    }

    /// The first message of a task, as JSON.
    public func runTaskMessage(taskID: String) throws -> String {
        var parameters: [String: Any] = [
            "format": "pcm",
            "sample_rate": Self.sampleRate,
            "vad_model": "near_meeting_16k",
            "language_hints": languageHints,
            "heartbeat": true,
        ]
        if !hotWords.isEmpty {
            parameters["vocabulary"] = Self.vocabulary(for: hotWords)
        }
        let object: [String: Any] = [
            "header": [
                "action": "run-task",
                "task_id": taskID,
                "streaming": "duplex",
            ],
            "payload": [
                "task_group": "audio",
                "task": "asr",
                "function": "recognition",
                "model": model,
                "parameters": parameters,
                "input": [:] as [String: Any],
            ],
        ]
        return try Self.json(object)
    }

    /// What ends a task after the last audio, as JSON.
    public static func finishTaskMessage(taskID: String) -> String {
        let object: [String: Any] = [
            "header": [
                "action": "finish-task",
                "task_id": taskID,
                "streaming": "duplex",
            ],
            "payload": ["input": [:] as [String: Any]],
        ]
        return (try? json(object)) ?? "{}"
    }

    /// Each hot word with its weight: Latin-letter words are super hot words, as
    /// upstream gives them, so that they are not heard as transliterations.
    public static func vocabulary(for hotWords: [String]) -> [String: Int] {
        let latin = hotWords.filter { word in
            word.unicodeScalars.allSatisfy(\.isASCII)
                && word.unicodeScalars.contains { CharacterSet.letters.contains($0) }
        }
        let superWords = Set(latin.prefix(maxLatinHotWords))
        var vocabulary: [String: Int] = [:]
        for word in hotWords {
            vocabulary[word] = superWords.contains(word) ? latinHotWordWeight : hotWordWeight
        }
        return vocabulary
    }

    private static func json(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}

/// Reads the events of a Bailian recognition task. A sentence is shown as far as it has
/// been heard (`result-generated`), and ends when DashScope says so (`sentence_end`);
/// heartbeats and empty sentences are not speech.
public struct BailianTranscript: Sendable {
    private var lastPartial = ""

    public init() {}

    public mutating func feed(_ data: Data) throws -> [SpeechUpdate] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let header = object["header"] as? [String: Any],
              let event = header["event"] as? String
        else { return [] }
        switch event {
        case "task-failed":
            throw BailianError.service(
                header["error_code"] as? String ?? "",
                header["error_message"] as? String ?? ""
            )
        case "task-finished":
            return [.ended]
        case "result-generated":
            guard let payload = object["payload"] as? [String: Any],
                  let output = payload["output"] as? [String: Any],
                  let sentence = output["sentence"] as? [String: Any]
            else { return [] }
            if sentence["heartbeat"] as? Bool == true { return [] }
            let text = (sentence["text"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if sentence["sentence_end"] as? Bool == true {
                lastPartial = ""
                guard Self.hasWords(text) else { return [.final("")] }
                return [.final(text)]
            }
            guard Self.hasWords(text), text != lastPartial else { return [] }
            lastPartial = text
            return [.partial(text)]
        default:
            return []
        }
    }

    /// Whether `text` has a letter or a digit: more than punctuation and spaces.
    static func hasWords(_ text: String) -> Bool {
        text.unicodeScalars.contains {
            CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0)
        }
    }
}

/// Buffers audio into the 100 ms packets DashScope is sent, and pads the last one with
/// silence so that a task told to finish does not leave audio behind.
public struct BailianAudioPackets: Sendable {
    private var held = Data()

    public init() {}

    public mutating func append(_ data: Data) -> [Data] {
        held.append(data)
        var packets: [Data] = []
        while held.count >= BailianSTTConfiguration.packetBytes {
            packets.append(Data(held.prefix(BailianSTTConfiguration.packetBytes)))
            held.removeFirst(BailianSTTConfiguration.packetBytes)
        }
        return packets
    }

    /// The audio not yet sent, made up to a packet with silence; nil when there is none.
    public mutating func drainPadded() -> Data? {
        guard !held.isEmpty else { return nil }
        var packet = held
        packet.append(Data(count: BailianSTTConfiguration.packetBytes - packet.count))
        held.removeAll()
        return packet
    }
}

/// DashScope ends a task that has been sent nothing for 23 seconds. While her voice keeps
/// the microphone closed, the service sends 100 ms of silence itself (upstream
/// `bailian.py`).
public enum BailianKeepalive {
    public static let interval: Duration = .seconds(1)
    public static let idle: Duration = .seconds(1)

    public static func silence() -> Data {
        Data(count: BailianSTTConfiguration.packetBytes)
    }

    public static func isDue(now: Date, lastAudio: Date) -> Bool {
        now.timeIntervalSince(lastAudio) >= idle.inSeconds
    }
}

public enum BailianError: LocalizedError, Equatable {
    case service(String, String)

    public var errorDescription: String? {
        switch self {
        case let .service(code, message):
            let head = code.isEmpty ? "" : "\(code)："
            return "百炼识别出错：\(head)\(message)"
        }
    }
}
