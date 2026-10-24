import Foundation

enum CallSettingsError: LocalizedError {
    case missingSonioxKey

    var errorDescription: String? {
        switch self {
        case .missingSonioxKey:
            "先在设置里填写 Soniox 的密钥，才能通话。"
        }
    }

    /// Nil when calls can be made: only a build without the development fake needs a key.
    static func missingSonioxKeyWhenNeeded(_ settings: ChatSettings) -> CallSettingsError? {
        #if DEBUG
        if ProcessInfo.processInfo.environment["EIDOLON_CALL_FAKE_SPEECH"] != nil { return nil }
        #endif
        return settings.sonioxAPIKey.isEmpty ? .missingSonioxKey : nil
    }
}
