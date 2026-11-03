import Foundation

/// The few provider-specific address adjustments the settings page can make safely.
/// A service may serve its OpenAI surfaces at one base and its Anthropic surface at
/// another; the chat model keeps one address, so switching protocols moves it.
public enum APIServiceRouting {
    public static let siliconFlowBaseURL = "https://api.siliconflow.cn/v1"
    public static let deepSeekAnthropicBaseURL = "https://api.deepseek.com/anthropic"

    private static let deepSeekRoots: Set<String> = [
        "https://api.deepseek.com",
        "https://api.deepseek.com/v1",
    ]

    private static let deepSeekAnthropicRoots: Set<String> = [
        "https://api.deepseek.com/anthropic",
        "https://api.deepseek.com/anthropic/v1",
    ]

    /// What the address should become when the protocol changes. Only the handful of
    /// official bases that are known to move are touched; anything else is left as the
    /// producer wrote it.
    public static func baseURL(
        _ text: String,
        movingTo newProtocol: ChatProtocol,
        from oldProtocol: ChatProtocol
    ) -> String {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        if newProtocol == .anthropic, deepSeekRoots.contains(normalized) {
            return deepSeekAnthropicBaseURL
        }
        if oldProtocol == .anthropic, newProtocol != .anthropic,
           deepSeekAnthropicRoots.contains(normalized) {
            return "https://api.deepseek.com"
        }
        return text
    }

    /// The address for an imported `.env`, whose previous protocol is unknown: an
    /// Anthropic chat model on DeepSeek's root base gets its `/anthropic` prefix.
    public static func baseURLForImportedSettings(
        _ text: String,
        protocol newProtocol: ChatProtocol
    ) -> String {
        baseURL(text, movingTo: newProtocol, from: .chatCompletions)
    }

    /// The default retrieval address when the producer left the field blank.
    public static func retrievalBaseURL(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? siliconFlowBaseURL : trimmed
    }
}
