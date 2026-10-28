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
    private(set) var standInfo: StandBundleInfo?
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

    /// Nil when no judge is usable; turns then go unjudged and affinity stays put
    /// (ADR-0005, ADR-0016). Built from the settings as they are now, so a change takes
    /// effect from the next turn.
    var judgeProvider: (any JudgeProvider)? {
        #if DEBUG
        // Development aid: `SIMCTL_CHILD_EIDOLON_NO_JUDGE=1` leaves the turn unjudged,
        // so the chat model chooses whether to call the recall-story tool itself.
        if ProcessInfo.processInfo.environment["EIDOLON_NO_JUDGE"] == "1" { return nil }
        #endif
        return judgeProvider(for: chatSettings)
    }

    /// The judge a given set of settings asks for, whether saved or still being edited —
    /// the settings page tests the fields as they are on screen. Nil while the chosen
    /// service is not filled in.
    func judgeProvider(for settings: ChatSettings) -> (any JudgeProvider)? {
        switch settings.judgeService {
        case .bailian:
            guard let config = settings.bailianJudgeConfig else { return nil }
            return SystemOneJudgeProvider(config: config)
        case .jev:
            guard let config = settings.jevJudgeConfig else { return nil }
            return SystemOneJudgeProvider(config: config)
        case .cloudflare:
            guard let config = settings.cloudflareJudgeConfig else { return nil }
            return SystemOneJudgeProvider(config: config)
        case .chat:
            guard let config = settings.judgeConfig(chat: settings.config) else { return nil }
            return ChatJudgeProvider(config: config)
        }
    }

    /// Judges each segment's emotion for her stand during a call, on the same System One
    /// service that judges turns: only it answers with probabilities. The chat judge has
    /// none, so a call with it has no emotion judged (spec「情绪判断」).
    var emotionJudgeProvider: (any SegmentEmotionJudge)? {
        emotionJudgeProvider(for: chatSettings)
    }

    func emotionJudgeProvider(for settings: ChatSettings) -> (any SegmentEmotionJudge)? {
        let config: SystemOneConfig?
        switch settings.judgeService {
        case .bailian: config = settings.bailianJudgeConfig
        case .jev: config = settings.jevJudgeConfig
        case .cloudflare: config = settings.cloudflareJudgeConfig
        case .chat: config = nil
        }
        guard let config else { return nil }
        return SystemOneSegmentEmotionJudge(
            config: config,
            minProbability: settings.emotionMinProbability,
            timeout: settings.emotionTimeout
        )
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
        // Every character whose time has come is asked at once: six characters are not six
        // model calls one after another before the list shows one of them.
        var reached = false
        await withTaskGroup(of: Bool.self) { group in
            for character in characters {
                group.addTask { [core] in
                    let record = try? await core.reachOutIfDue(
                        characterID: character.id,
                        provider: provider,
                        embedder: embedder,
                        reranker: reranker,
                        hours: hours
                    )
                    return record != nil
                }
            }
            for await didReach in group {
                if didReach { reached = true }
            }
        }
        if reached { await refresh() }
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
        let hotWords = (try? await core.callHotWords()) ?? []
        let readings = (try? await core.readings()) ?? Readings()
        let (capture, recognition) = callAudio(hotWords: hotWords)
        let judge = judgeProvider
        let setup = CallSetup(
            capture: capture,
            playback: SpeechPlayback(),
            recognition: recognition,
            synthesis: speechSynthesis(readings: readings),
            voiceModel: chatSettings.fishModel,
            provider: provider,
            judge: judge,
            emotionJudge: judge == nil ? nil : emotionJudgeProvider,
            embedder: embeddingProvider,
            reranker: rerankProvider,
            tracing: tracing,
            limits: chatSettings.callLimits,
            historyTurns: chatSettings.historyTurns,
            reconnectDelay: debugReconnectDelay,
            now: { Date() }
        )
        return try await core.beginCall(characterID: character.id, setup: setup, now: now)
    }

    private func callAudio(hotWords: [String]) -> (any AudioCapture, any SpeechRecognition) {
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
            SonioxRecognition(
                apiKey: chatSettings.sonioxAPIKey,
                model: chatSettings.sonioxModel,
                terms: hotWords
            )
        )
    }

    /// Without a Fish Audio key her words are subtitles only (ADR-0011).
    private func speechSynthesis(readings: Readings) -> any SpeechSynthesis {
        guard !chatSettings.fishAPIKey.isEmpty else { return UnvoicedSynthesis() }
        return FishSynthesis(apiKey: chatSettings.fishAPIKey, readings: readings)
    }

    func saveProducerProfile(_ profile: ProducerProfile) async throws {
        try await core.updateProducerProfile(profile)
    }

    func loadMemories() async {
        memories = (try? await core.memories()) ?? []
    }

    /// Forgets one of the producer's memories; the list is reloaded from what is kept.
    func deleteMemory(id: String) async throws {
        _ = try await core.deleteMemory(id: id)
        await loadMemories()
    }

    /// Forgets every memory, including what earlier turns are still writing down.
    func clearMemories() async throws {
        try await core.clearMemories()
        await loadMemories()
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
        applyDebugBailianSettings()
        await importBundleForDebuggingIfRequested()
        #endif
        do {
            if let info = try await core.usableContentInfo() {
                bundleInfo = info
                try await load()
                phase = .ready
                resumeMemoryJobs()
                await catchUpReachOuts()
            } else {
                // A bundle from another format or content schema is not run: the app asks
                // for a new import rather than failing later or missing what it added.
                if let stale = try await core.installedContentInfo() {
                    errorMessage = "已安装的内容包是旧格式（格式 \(stale.formatVersion)，"
                        + "内容库 \(stale.contentSchemaVersion)）。请重新导出并导入内容包。"
                }
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

    /// Development aid: `EIDOLON_BAILIAN_WORKSPACE/_REGION/_MODEL/_API_KEY` fill in the
    /// Bailian judge without the keyboard. Everything else — the chat model, the call
    /// keys — stays as it was, so a device already in use is only asked a new question.
    private func applyDebugBailianSettings() {
        let environment = ProcessInfo.processInfo.environment
        guard let key = environment["EIDOLON_BAILIAN_API_KEY"], !key.isEmpty else { return }
        var settings = chatSettings
        settings.judgeService = .bailian
        settings.bailianWorkspace = environment["EIDOLON_BAILIAN_WORKSPACE"] ?? ""
        settings.bailianRegion = BailianRegion(
            rawValue: environment["EIDOLON_BAILIAN_REGION"] ?? ""
        ) ?? .beijing
        settings.bailianModel = environment["EIDOLON_BAILIAN_MODEL"] ?? "decision-model-preview"
        settings.bailianAPIKey = key
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

    /// Development aid: `SIMCTL_CHILD_EIDOLON_OPEN_STAND_PREVIEW=1` opens the stand preview.
    var debugShowsStandPreview: Bool {
        ProcessInfo.processInfo.environment["EIDOLON_OPEN_STAND_PREVIEW"] == "1"
    }

    /// Development aid: `SIMCTL_CHILD_EIDOLON_IMPORT_BUNDLE` points at a bundle
    /// already copied into this app's container, so the simulator can reach the
    /// screens that normally sit behind the file picker.
    private func importBundleForDebuggingIfRequested() async {
        guard let path = ProcessInfo.processInfo.environment["EIDOLON_IMPORT_BUNDLE"] else { return }
        // A bare name is looked up in Documents, so a device can be given a freshly
        // built bundle without knowing its container path.
        let url = path.hasPrefix("/")
            ? URL(fileURLWithPath: path)
            : URL.documentsDirectory.appending(path: path)
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

    /// Installs a stand bundle beside the content bundle. The content bundle and the
    /// user library are untouched when the stand bundle is bad (ADR-0020).
    func importStandBundle(from url: URL) async {
        guard !isImporting else { return }
        isImporting = true
        errorMessage = nil
        defer { isImporting = false }

        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let copy = FileManager.default.temporaryDirectory
            .appending(path: "import-stand-\(UUID().uuidString).eidolonpkg")
        defer { try? FileManager.default.removeItem(at: copy) }

        do {
            try FileManager.default.copyItem(at: url, to: copy)
            standInfo = try await core.installStand(bundleAt: copy)
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
        standInfo = try await core.installedStandInfo()

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
