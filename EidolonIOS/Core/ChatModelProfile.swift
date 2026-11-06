import EidolonCore
import Foundation

/// One saved chat model (spec #116): the fields that change when switching between
/// DeepSeek and a local model. Its key lives in the Keychain under its own account, so
/// two profiles never overwrite each other. Everything else (history, wording, thinking
/// effort, judge, retrieval, call, image) stays global.
struct ChatModelProfile: Identifiable, Codable, Equatable {
    var id: String
    var name: String
    var apiProtocol: ChatProtocol
    var baseURL: String
    var model: String
    var maxTokens: Int?
    var extraBody: String

    init(
        id: String = UUID().uuidString,
        name: String,
        apiProtocol: ChatProtocol = .chatCompletions,
        baseURL: String = "",
        model: String = "",
        maxTokens: Int? = nil,
        extraBody: String = ""
    ) {
        self.id = id
        self.name = name
        self.apiProtocol = apiProtocol
        self.baseURL = baseURL
        self.model = model
        self.maxTokens = maxTokens
        self.extraBody = extraBody
    }

    /// The Keychain account of this profile's key; never the legacy `chat.apiKey` one.
    var keyAccount: String { "chat.profile.\(id).apiKey" }

    var storedAPIKey: String { Keychain.string(account: keyAccount) ?? "" }

    /// Enough to make a request: an address, a model and a key.
    var isComplete: Bool {
        !baseURL.trimmed.isEmpty && !model.trimmed.isEmpty && !storedAPIKey.trimmed.isEmpty
    }

    /// What the list shows under the name: the model, then the address's host.
    var subtitle: String {
        let name = model.trimmed.isEmpty ? "未填模型" : model.trimmed
        let host = URL(string: baseURL)?.host ?? baseURL.trimmed
        return host.isEmpty ? name : "\(name) · \(host)"
    }

    /// Puts this profile's fields into the live settings, key included.
    mutating func apply(to settings: inout ChatSettings) {
        settings.apiProtocol = apiProtocol
        settings.baseURL = baseURL
        settings.model = model
        settings.maxTokens = maxTokens
        settings.extraBody = extraBody
        settings.apiKey = storedAPIKey
    }

    /// Writes this profile's key; a blank key keeps the stored one, `clear` removes it.
    func storeAPIKey(_ key: String, clear: Bool) throws {
        if clear {
            Keychain.remove(account: keyAccount)
        } else if !key.trimmed.isEmpty {
            try Keychain.set(key, account: keyAccount)
        }
    }

    /// Takes the live settings' fields back into this profile; the key is the caller's
    /// to write, so the value type stays out of the Keychain's way.
    mutating func capture(from settings: ChatSettings) {
        apiProtocol = settings.apiProtocol
        baseURL = settings.baseURL.trimmed
        model = settings.model.trimmed
        maxTokens = settings.maxTokens
        extraBody = settings.extraBody.trimmed
    }
}

/// Where the profiles live (spec #116): non-secret fields as JSON in UserDefaults, the
/// active profile's id beside them, each key in the Keychain. The first load turns the
/// existing single chat settings into one profile and adds the two templates.
enum ChatModelProfileStore {
    static let profilesKey = "chat.profiles"
    static let activeKey = "chat.activeProfileID"
    static let deepSeekBaseURL = "https://api.deepseek.com/v1"
    /// 占位地址（RFC 5737 的 TEST-NET-1）：模板只是给你照抄格式，换成自己那台的地址。
    static let localBaseURL = "http://192.0.2.10:8080/v1"

    struct State {
        var profiles: [ChatModelProfile]
        var activeID: String?
    }

    static func load(settings: ChatSettings) -> State {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: profilesKey),
           let decoded = try? JSONDecoder().decode([ChatModelProfile].self, from: data),
           !decoded.isEmpty {
            var active = defaults.string(forKey: activeKey)
            if active == nil || !decoded.contains(where: { $0.id == active }) {
                active = decoded.first?.id
                saveActive(active)
            }
            return State(profiles: decoded, activeID: active)
        }
        return migrate(settings: settings)
    }

    /// Turns the current chat settings into 「当前配置」 and seeds the templates, never
    /// overwriting a profile that already has the same address.
    static func migrate(settings: ChatSettings) -> State {
        var profiles: [ChatModelProfile] = [initialProfile(settings: settings)]
        let current = profiles[0]
        if !profiles.contains(where: { sameAddress($0.baseURL, deepSeekBaseURL) }) {
            profiles.append(
                ChatModelProfile(
                    name: "DeepSeek",
                    baseURL: deepSeekBaseURL,
                    model: "deepseek-chat"
                )
            )
        }
        if !profiles.contains(where: { sameAddress($0.baseURL, localBaseURL) }) {
            profiles.append(
                ChatModelProfile(name: "家里本地", baseURL: localBaseURL)
            )
        }
        save(profiles, activeID: current.id)
        return State(profiles: profiles, activeID: current.id)
    }

    /// For UI tests: start from one known profile instead of yesterday's list.
    static func resetForDebug(settings: ChatSettings) -> State {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: profilesKey),
           let decoded = try? JSONDecoder().decode([ChatModelProfile].self, from: data) {
            for profile in decoded { Keychain.remove(account: profile.keyAccount) }
        }
        let profile = initialProfile(settings: settings)
        save([profile], activeID: profile.id)
        return State(profiles: [profile], activeID: profile.id)
    }

    /// 「当前配置」 from the single chat settings, key included.
    private static func initialProfile(settings: ChatSettings) -> ChatModelProfile {
        let profile = ChatModelProfile(
            name: "当前配置",
            apiProtocol: settings.apiProtocol,
            baseURL: settings.baseURL.trimmed,
            model: settings.model.trimmed,
            maxTokens: settings.maxTokens,
            extraBody: settings.extraBody.trimmed
        )
        try? profile.storeAPIKey(settings.apiKey, clear: false)
        return profile
    }

    static func save(_ profiles: [ChatModelProfile], activeID: String?) {
        let defaults = UserDefaults.standard
        if let data = try? JSONEncoder().encode(profiles) {
            defaults.set(data, forKey: profilesKey)
        }
        if let activeID {
            defaults.set(activeID, forKey: activeKey)
        } else {
            defaults.removeObject(forKey: activeKey)
        }
    }

    static func saveActive(_ id: String?) {
        let defaults = UserDefaults.standard
        if let id {
            defaults.set(id, forKey: activeKey)
        } else {
            defaults.removeObject(forKey: activeKey)
        }
    }

    private static func sameAddress(_ left: String, _ right: String) -> Bool {
        func normalize(_ value: String) -> String {
            var trimmed = value.trimmed.lowercased()
            while trimmed.hasSuffix("/") { trimmed.removeLast() }
            return trimmed
        }
        return !left.trimmed.isEmpty && normalize(left) == normalize(right)
    }
}
