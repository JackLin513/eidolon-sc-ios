import Foundation
import Observation

@MainActor
@Observable
final class ChatStore {
    struct LiveSegment: Equatable {
        var ja = ""
        var zh = ""
    }

    struct LiveLine: Identifiable {
        let index: Int
        let ja: String
        let zh: String

        var id: Int { index }
    }

    let client: APIClient
    let character: Character
    let conversationID: String

    var items: [RecordItem] = []
    var draft = ""
    var isSending = false
    var isLoading = false
    var errorMessage: String?
    var pendingUserText: String?

    private var liveSegments: [Int: LiveSegment] = [:]

    init(client: APIClient, character: Character, conversationID: String) {
        self.client = client
        self.character = character
        self.conversationID = conversationID
    }

    var liveLines: [LiveLine] {
        liveSegments.keys.sorted().map { index in
            let segment = liveSegments[index] ?? LiveSegment()
            return LiveLine(index: index, ja: segment.ja, zh: segment.zh)
        }
    }

    func load() async {
        isLoading = items.isEmpty
        defer { isLoading = false }
        do {
            items = try await client.messages(conversationID: conversationID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }

        draft = ""
        isSending = true
        errorMessage = nil
        pendingUserText = text
        liveSegments = [:]

        do {
            for try await event in client.sendTurn(conversationID: conversationID, text: text) {
                switch event.type {
                case "delta":
                    guard let index = event.segment, let lang = event.lang else { continue }
                    var segment = liveSegments[index] ?? LiveSegment()
                    if lang == "ja" {
                        segment.ja += event.text ?? ""
                    } else if lang == "zh" {
                        segment.zh += event.text ?? ""
                    }
                    liveSegments[index] = segment
                case "error":
                    errorMessage = event.detail ?? "这次回复失败了"
                default:
                    break
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        pendingUserText = nil
        liveSegments = [:]
        isSending = false
        await load()
    }
}
