#if DEBUG
import EidolonCore
import Foundation

/// Development aid: `SIMCTL_CHILD_EIDOLON_FAKE_CHAT=1` gives every prompt a fixed reply, so
/// the call and chat pages can be looked at without a model key. Debug builds only.
struct DebugChatProvider: ChatProvider {
    func stream(messages: [PromptMessage]) -> AsyncThrowingStream<String, Error> {
        let system = messages.first?.content ?? ""
        let answer: String
        if system.contains("你负责替") {
            answer = ""
        } else if system.contains("你负责给") {
            answer = ""
        } else {
            let line = "<ja>こんばんは。今日はどうしたの？</ja>"
                + "<zh>晚上好。今天怎么了？</zh>"
            answer = system.contains("场景块")
                ? "<scene>她把杯子放下，抬眼看过来。</scene>" + line
                : line
        }
        return AsyncThrowingStream { continuation in
            continuation.yield(answer)
            continuation.finish()
        }
    }
}
#endif
