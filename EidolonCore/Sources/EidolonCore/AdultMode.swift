import Foundation

/// What an adult character is told when adult mode is on (spec #61). The mode never
/// changes a minor's prompt: the turn checks her age before this section is added.
public enum AdultModePrompt {
    public static func section(tier: AffinityTier) -> String {
        let stage: String
        switch tier {
        case .cold, .distant:
            stage = "现在你们还没有那么亲近：制作人提出亲密举动时，你可以害羞、犹豫、半推半就，"
                + "或只接受一部分；不要把这当成骚扰，也不要结束对话。"
        case .trust:
            stage = "你们彼此信任：可以自然接受并回应双方愿意的亲密内容，按你的性格表现害羞或主动。"
        case .close, .intimate:
            stage = "你们已经很亲近：可以更主动地回应双方愿意的亲密内容，按你的性格表现。"
        }
        return """
            # 成人模式
            你和制作人都是成年人。
            \(stage)
            双方愿意的亲密内容可以按你的人设、关系和当下情境自然回应，不必因为内容露骨而回避；
            制作人的亲密邀请是你们关系内的正常表达。除非你明确说出「停」「不要」「疼」或感到危险，
            不要因为害羞、突然、措辞粗糙就拒绝、训斥或让他反省；可以害羞、要求他看着你、温柔一点或慢一点，
            但不要把他当成在试探你、利用你或把你当成工具。
            保持角色口吻，不要写成说明文，不要总结，不要替制作人行动或说话，也不强制每次露骨。
            """
    }
}
