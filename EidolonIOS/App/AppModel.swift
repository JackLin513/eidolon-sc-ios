import Foundation
import Observation

enum AppPhase {
    case loading
    case signedOut
    case needsConsent
    case ready
}

@MainActor
@Observable
final class AppModel {
    var phase: AppPhase = .loading
    var client: APIClient
    var characters: [Character] = []
    var latest: [String: LatestConversation] = [:]
    var account: Account?
    var errorMessage: String?
    var isBusy = false

    init() {
        client = APIClient()
    }

    /// Whether the existing session still works, or what has to happen first.
    func bootstrap() async {
        guard account == nil else { return }
        phase = .loading
        errorMessage = nil
        do {
            account = try await client.account()
            phase = .ready
            await refresh()
        } catch let error as APIError {
            switch error {
            case let .status(code, detail):
                switch code {
                case 401:
                    phase = .signedOut
                case 428:
                    phase = .needsConsent
                default:
                    phase = .signedOut
                    errorMessage = detail.isEmpty ? error.localizedDescription : detail
                }
            case .invalidResponse:
                phase = .signedOut
                errorMessage = error.localizedDescription
            }
        } catch {
            phase = .signedOut
            errorMessage = error.localizedDescription
        }
    }

    func signIn(name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "先填一个名字"
            return
        }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }

        do {
            try await client.signIn(name: trimmed)
            account = try await client.account()
            phase = .ready
            await refresh()
        } catch let error as APIError {
            if case let .status(code, detail) = error {
                switch code {
                case 401:
                    phase = .signedOut
                case 428:
                    phase = .needsConsent
                    return
                default:
                    break
                }
                errorMessage = detail.isEmpty ? error.localizedDescription : detail
            } else {
                errorMessage = error.localizedDescription
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func agree() async {
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }

        do {
            try await client.agreeToTerms()
            account = try await client.account()
            phase = .ready
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refresh() async {
        guard phase == .ready else { return }
        do {
            async let roster = client.characters()
            async let recents = client.latestConversations()
            let loadedCharacters = try await roster
            let loadedLatest = try await recents
            characters = loadedCharacters
            latest = Dictionary(
                loadedLatest.map { ($0.characterId, $0) },
                uniquingKeysWith: { _, last in last }
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// The conversation to open for a character: her latest, or a new one if there is none.
    func open(_ character: Character) async -> ChatTarget? {
        if let recents = latest[character.id] {
            return ChatTarget(character: character, conversationID: recents.conversationId)
        }
        do {
            let conversation = try await client.createConversation(characterID: character.id)
            await refresh()
            return ChatTarget(character: character, conversationID: conversation.id)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func startNewConversation(_ character: Character) async -> ChatTarget? {
        do {
            let conversation = try await client.createConversation(characterID: character.id)
            await refresh()
            return ChatTarget(character: character, conversationID: conversation.id)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func signOut() async {
        isBusy = true
        defer { isBusy = false }
        try? await client.signOut()
        account = nil
        characters = []
        latest = [:]
        errorMessage = nil
        phase = .signedOut
    }

    /// Points the client at another backend and starts over. Returns false if the address
    /// cannot be parsed.
    @discardableResult
    func setBaseURL(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme != nil, url.host != nil else {
            errorMessage = "后端地址不合法"
            return false
        }
        Backend.url = url
        client = APIClient(baseURL: url)
        account = nil
        characters = []
        latest = [:]
        errorMessage = nil
        phase = .loading
        Task { await bootstrap() }
        return true
    }
}
