import EidolonCore
import Foundation
import Observation
import UIKit

enum AppPhase: Equatable {
    case loading
    case needsContentBundle
    case ready
    case failed(String)
}

@MainActor
@Observable
final class AppModel {
    private(set) var phase: AppPhase = .loading
    private(set) var characters: [CharacterConfig] = []
    private(set) var latest: [String: LatestActivity] = [:]
    private(set) var bundleInfo: ContentBundleInfo?
    private(set) var avatars: [String: UIImage] = [:]
    private(set) var memories: [MemoryRecord] = []
    var errorMessage: String?
    private(set) var isImporting = false
    private(set) var chatSettings = ChatSettings.load()

    var chatProvider: (any ChatProvider)? {
        chatSettings.config.map { OpenAICompatibleChatProvider(config: $0) as any ChatProvider }
    }

    var tracing: TurnTracing {
        TurnTracing(enabled: chatSettings.tracingEnabled, retention: chatSettings.traceRetention)
    }

    var embeddingProvider: (any EmbeddingProvider)? {
        chatSettings.embeddingConfig.map { SiliconFlowEmbedding(config: $0) as any EmbeddingProvider }
    }

    var rerankProvider: (any RerankProvider)? {
        chatSettings.rerankConfig.map { SiliconFlowRerank(config: $0) as any RerankProvider }
    }

    /// Nil when no judge is usable; turns then go unjudged and affinity stays put (ADR-0005).
    var judgeProvider: (any JudgeProvider)? {
        #if DEBUG
        // Development aid: `SIMCTL_CHILD_EIDOLON_NO_JUDGE=1` leaves the turn unjudged,
        // so the chat model chooses whether to call the recall-story tool itself.
        if ProcessInfo.processInfo.environment["EIDOLON_NO_JUDGE"] == "1" { return nil }
        #endif
        guard let config = chatSettings.judgeConfig(chat: chatSettings.config) else { return nil }
        return ChatJudgeProvider(config: config)
    }

    /// Writing down what the producer said is cut short when the app is closed; those
    /// jobs run again here, before anything else is said.
    private func resumeMemoryJobs() {
        guard let provider = chatProvider else { return }
        let embedder = embeddingProvider
        Task { [core] in
            await core.resumePendingMemories(provider: provider, embedder: embedder)
            await self.loadMemories()
        }
    }

    private var isCatchingUp = false

    /// Whether she reaches out now (ADR-0009): at launch and whenever the app comes back
    /// to the foreground, for every character whose conversation has been quiet long enough.
    func catchUpReachOuts() async {
        guard phase == .ready, !isCatchingUp, let provider = chatProvider else { return }
        isCatchingUp = true
        defer { isCatchingUp = false }
        let embedder = embeddingProvider
        let reranker = rerankProvider
        var hours = Double(chatSettings.reachOutHours)
        #if DEBUG
        // Development aid: `SIMCTL_CHILD_EIDOLON_REACH_OUT_HOURS=0.01` makes the wait short.
        if let override = ProcessInfo.processInfo.environment["EIDOLON_REACH_OUT_HOURS"],
           let value = Double(override) {
            hours = value
        }
        #endif
        var reached = false
        for character in characters {
            let record = try? await core.reachOutIfDue(
                characterID: character.id,
                provider: provider,
                embedder: embedder,
                reranker: reranker,
                hours: hours
            )
            if record != nil { reached = true }
        }
        if reached { await refresh() }
    }

    private func nameUntitledConversations() {
        guard let provider = chatProvider else { return }
        Task { [core] in
            await core.nameUntitledConversations(provider: provider)
        }
    }

    /// A call with her, on the services the settings name. The microphone and the
    /// recognizer are the app's; everything else is the core's (ADR-0015).
    func beginCall(for character: CharacterConfig, now: Date = Date()) async throws -> CallSession {
        guard let provider = chatProvider else {
            throw ChatProviderError.notConfigured
        }
        if let missing = CallSettingsError.missingSonioxKeyWhenNeeded(chatSettings) {
            throw missing
        }
        let (capture, recognition) = callAudio()
        let setup = CallSetup(
            capture: capture,
            playback: SpeechPlayback(),
            recognition: recognition,
            synthesis: speechSynthesis(),
            voiceModel: chatSettings.fishModel,
            provider: provider,
            judge: judgeProvider,
            embedder: embeddingProvider,
            reranker: rerankProvider,
            tracing: tracing,
            reconnectDelay: debugReconnectDelay,
            now: { Date() }
        )
        return try await core.beginCall(characterID: character.id, setup: setup, now: now)
    }

    private func callAudio() -> (any AudioCapture, any SpeechRecognition) {
        #if DEBUG
        // Development aid: `SIMCTL_CHILD_EIDOLON_CALL_FAKE_SPEECH` answers as if the
        // producer had said one line, so the call can be seen without a microphone.
        if let script = ProcessInfo.processInfo.environment["EIDOLON_CALL_FAKE_SPEECH"],
           !script.isEmpty {
            let lines = script.split(separator: "|").map(String.init)
            return (
                SilentCapture(),
                DebugRecognition(
                    said: lines,
                    dropFirst: ProcessInfo.processInfo.environment["EIDOLON_CALL_DROP_ONCE"] == "1",
                    interval: debugSpeechInterval
                )
            )
        }
        #endif
        return (
            MicrophoneCapture(),
            SonioxRecognition(apiKey: chatSettings.sonioxAPIKey, model: chatSettings.sonioxModel)
        )
    }

    /// Without a Fish Audio key her words are subtitles only (ADR-0011).
    private func speechSynthesis() -> any SpeechSynthesis {
        guard !chatSettings.fishAPIKey.isEmpty else { return UnvoicedSynthesis() }
        return FishSynthesis(apiKey: chatSettings.fishAPIKey)
    }

    func saveProducerProfile(_ profile: ProducerProfile) async throws {
        try await core.updateProducerProfile(profile)
    }

    func loadMemories() async {
        memories = (try? await core.memories()) ?? []
    }

    func saveChatSettings(_ settings: ChatSettings) throws {
        try settings.save()
        chatSettings = settings
    }

    let core: Eidolon

    init() throws {
        // Everything the app writes lives here; nothing else is shared with the Mac.
        let root = URL.applicationSupportDirectory
            .appending(path: "Eidolon", directoryHint: .isDirectory)
        core = try Eidolon(location: .init(root: root))
    }

    func bootstrap() async {
        #if DEBUG
        applyDebugChatSettings()
        await importBundleForDebuggingIfRequested()
        #endif
        do {
            if let info = try await core.installedContentInfo() {
                bundleInfo = info
                try await load()
                phase = .ready
                resumeMemoryJobs()
                nameUntitledConversations()
                await catchUpReachOuts()
            } else {
                phase = .needsContentBundle
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    #if DEBUG
    /// Development aid: `SIMCTL_CHILD_EIDOLON_CHAT_BASE_URL/_MODEL/_API_KEY` seed the
    /// chat settings so the simulator can talk to a real model without the keyboard.
    private func applyDebugChatSettings() {
        let environment = ProcessInfo.processInfo.environment
        guard let key = environment["EIDOLON_CHAT_API_KEY"], !key.isEmpty else { return }
        let settings = ChatSettings(
            baseURL: environment["EIDOLON_CHAT_BASE_URL"] ?? "https://api.siliconflow.cn/v1",
            model: environment["EIDOLON_CHAT_MODEL"] ?? "",
            apiKey: key,
            historyTurns: 20,
            extraBody: environment["EIDOLON_CHAT_EXTRA_BODY"] ?? "",
            retrievalBaseURL: environment["EIDOLON_RETRIEVAL_BASE_URL"] ?? "",
            embeddingModel: environment["EIDOLON_EMBEDDING_MODEL"] ?? "",
            rerankModel: environment["EIDOLON_RERANK_MODEL"] ?? "",
            retrievalAPIKey: environment["EIDOLON_RETRIEVAL_API_KEY"] ?? "",
            sonioxAPIKey: environment["EIDOLON_SONIOX_API_KEY"] ?? "",
            sonioxModel: environment["EIDOLON_SONIOX_MODEL"] ?? "stt-rt-v5",
            fishAPIKey: environment["EIDOLON_FISH_API_KEY"] ?? "",
            fishModel: environment["EIDOLON_FISH_MODEL"] ?? "s2.1-pro-free"
        )
        try? saveChatSettings(settings)
    }

    /// Development aid: `SIMCTL_CHILD_EIDOLON_OPEN_CHARACTER` opens that chat directly.
    var debugCharacterID: String? {
        ProcessInfo.processInfo.environment["EIDOLON_OPEN_CHARACTER"]
    }

    /// Development aid: `SIMCTL_CHILD_EIDOLON_SEND_TEXT` sends one line on opening.
    var debugSendText: String? {
        ProcessInfo.processInfo.environment["EIDOLON_SEND_TEXT"]
    }

    /// Development aid: `SIMCTL_CHILD_EIDOLON_CALL_SPEECH_INTERVAL_MS` makes the injected
    /// lines repeat at that interval, for a long call.
    var debugSpeechInterval: Duration? {
        #if DEBUG
        if let milliseconds = ProcessInfo.processInfo.environment["EIDOLON_CALL_SPEECH_INTERVAL_MS"],
           let value = Int(milliseconds), value > 0 {
            return .milliseconds(value)
        }
        #endif
        return nil
    }

    /// Development aid: `SIMCTL_CHILD_EIDOLON_CALL_RECONNECT_MS` slows reconnection so the
    /// 「重连中」 state can be seen in the simulator.
    var debugReconnectDelay: Duration {
        #if DEBUG
        if let milliseconds = ProcessInfo.processInfo.environment["EIDOLON_CALL_RECONNECT_MS"],
           let value = Int(milliseconds), value >= 0 {
            return .milliseconds(value)
        }
        #endif
        return .seconds(1)
    }

    /// Development aid: `SIMCTL_CHILD_EIDOLON_OPEN_CALL=1` starts a call on opening a chat.
    var debugOpensCall: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["EIDOLON_OPEN_CALL"] == "1"
        #else
        false
        #endif
    }

    /// Development aid: `SIMCTL_CHILD_EIDOLON_OPEN_HISTORY=1` opens a chat's history.
    var debugShowsHistory: Bool {
        ProcessInfo.processInfo.environment["EIDOLON_OPEN_HISTORY"] == "1"
    }

    /// Development aid: `SIMCTL_CHILD_EIDOLON_OPEN_TRACES=1` opens the turn traces.
    var debugShowsTraces: Bool {
        ProcessInfo.processInfo.environment["EIDOLON_OPEN_TRACES"] == "1"
    }

    /// Development aid: `SIMCTL_CHILD_EIDOLON_OPEN_LATEST_TRACE=1` opens the newest trace.
    var debugShowsLatestTrace: Bool {
        ProcessInfo.processInfo.environment["EIDOLON_OPEN_LATEST_TRACE"] == "1"
    }

    /// Development aid: `SIMCTL_CHILD_EIDOLON_OPEN_MEMORIES=1` opens the memory list.
    var debugShowsMemories: Bool {
        ProcessInfo.processInfo.environment["EIDOLON_OPEN_MEMORIES"] == "1"
    }

    /// Development aid: `SIMCTL_CHILD_EIDOLON_IMPORT_BUNDLE` points at a bundle
    /// already copied into this app's container, so the simulator can reach the
    /// screens that normally sit behind the file picker.
    private func importBundleForDebuggingIfRequested() async {
        guard let path = ProcessInfo.processInfo.environment["EIDOLON_IMPORT_BUNDLE"] else { return }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            errorMessage = "调试用的内容包不存在：\(path)"
            return
        }
        do {
            _ = try await core.install(bundleAt: url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
    #endif

    /// Copies the picked file out of its security-scoped location first, then
    /// installs it. The old bundle stays in place whenever the new one is bad.
    func importBundle(from url: URL) async {
        guard !isImporting else { return }
        isImporting = true
        errorMessage = nil
        defer { isImporting = false }

        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let copy = FileManager.default.temporaryDirectory
            .appending(path: "import-\(UUID().uuidString).eidolonpkg")
        defer { try? FileManager.default.removeItem(at: copy) }

        do {
            try FileManager.default.copyItem(at: url, to: copy)
            let info = try await core.install(bundleAt: copy)
            bundleInfo = info
            try await load()
            phase = .ready
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refresh() async {
        do {
            try await load()
            bundleInfo = try await core.installedContentInfo()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func avatar(for characterID: String) -> UIImage? {
        avatars[characterID]
    }

    private func load() async throws {
        characters = try await core.characters()
        latest = try await core.latestActivities()

        var images: [String: UIImage] = [:]
        for character in characters {
            guard let url = await core.avatarURL(for: character.id),
                  let image = UIImage(contentsOfFile: url.path)
            else { continue }
            images[character.id] = image
        }
        avatars = images
    }
}
