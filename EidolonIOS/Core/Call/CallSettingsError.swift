import EidolonCore
import Foundation

enum CallSettingsError: LocalizedError, Equatable {
    case missingRecognitionKey(SpeechToTextService)

    var errorDescription: String? {
        switch self {
        case let .missingRecognitionKey(service):
            switch service {
            case .soniox:
                "先在设置里填写 Soniox 的密钥，才能通话。"
            case .bailian:
                "先在设置里填写阿里云百炼的密钥（DASHSCOPE_API_KEY），才能通话。"
            }
        }
    }

    /// Nil when calls can be made: only a build without the development fake needs the
    /// selected recognizer's key.
    static func missingRecognitionKeyWhenNeeded(_ settings: ChatSettings) -> CallSettingsError? {
        #if DEBUG
        if ProcessInfo.processInfo.environment["EIDOLON_CALL_FAKE_SPEECH"] != nil { return nil }
        #endif
        return settings.recognitionIsConfigured
            ? nil
            : .missingRecognitionKey(settings.speechToText)
    }
}
