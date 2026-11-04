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
        // `EIDOLON_FAKE_CHAT_DELAY_MS` holds the reply open after its text, so the live
        // call rows can be seen while a turn is still going.
        let delay = ProcessInfo.processInfo.environment["EIDOLON_FAKE_CHAT_DELAY_MS"]
            .flatMap(Int.init) ?? 0
        return AsyncThrowingStream { continuation in
            continuation.yield(answer)
            guard delay > 0 else {
                continuation.finish()
                return
            }
            Task {
                try? await Task.sleep(for: .milliseconds(delay))
                continuation.finish()
            }
        }
    }
}
#endif
