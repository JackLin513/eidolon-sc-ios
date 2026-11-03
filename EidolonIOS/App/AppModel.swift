import EidolonCore
import Foundation
import Observation
import OSLog
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
    /// Who has a stand, answered before `characters` is published so the chat page's
    /// toolbar can settle on its first frame (spec #44).
    private(set) var standCharacterIDs: Set<String> = []
    private(set) var latest: [String: LatestActivity] = [:]
    private(set) var bundleInfo: ContentBundleInfo?
    private(set) var standInfo: StandBundleInfo?
    private(set) var barInfo: BarBundleInfo?
    private(set) var avatars: [String: UIImage] = [:]
    private(set) var memories: [MemoryRecord] = []
    var errorMessage: String?
    private(set) var isImporting = false
    private(set) var importProgress: ImportProgress?
    private(set) var chatSettings = ChatSettings.load()
    /// The one call the app is in, owned here so changing pages does not end it (spec #46).
    let call = CallController()
    /// Bumped when a conversation is started from somewhere other than the page that
    /// shows it — a past conversation in the history sheet. The current page reloads to
    /// the new one and the sheet closes (spec #37).
    private(set) var conversationRevision = 0

    /// The chat's 朗读: one for the whole app, so only one line ever plays (spec #32).
    let readAloud = ChatReadAloud()

    /// The system-calendar export (spec #56): its switch and last result, and the EventKit
    /// store behind the core synchronizer.
    let calendarExport = CalendarExportController()

    /// This phone's roster tidy choices (spec #48); not part of the user library.
    private(set) var roster = RosterStore.load()

    /// Whether the debug page is offered on a character's chat page (spec #62). It lives
    /// on this phone, is off by default, and exists in every build.
    private(set) var debugMode = UserDefaults.standard.bool(forKey: AppModel.debugModeKey)

    private static let debugModeKey = "debug.mode"

    /// The phone's own call sounds: one for the whole app, so a hang-up tone outlives the
    /// call page and a redial cuts whatever the last call left playing (spec #35).
    let callTones = CallTonesPlayer()

    /// Whether the debug chat provider is answering instead of a configured model.
    var isUsingFakeChat: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["EIDOLON_FAKE_CHAT"] == "1"
        #else
        false
        #endif
    }

    var chatProvider: (any ChatProvider)? {
        #if DEBUG
        // Development aid: open the call and chat pages without a model key.
        if isUsingFakeChat {
            return DebugChatProvider()
        }
        #endif
        guard let config = chatSettings.config else { return nil }
        return ChatProviderFactory.make(config: config)
    }

    /// What writes memories and names conversations (spec #80): the background model with
    /// the chat model's missing fields, or the chat model itself when none is set — no
    /// second provider is built then.
    var backgroundProvider: (any ChatProvider)? {
        guard chatSettings.hasBackgroundModel else { return chatProvider }
        guard let config = chatSettings.backgroundConfig else { return nil }
        return ChatProviderFactory.make(config: config)
    }

    var tracing: TurnTracing {
        TurnTracing(enabled: chatSettings.tracingEnabled, retention: chatSettings.traceRetention)
    }

    /// What a typed turn is asked to write; calls pass their own style.
    var replyStyle: ReplyStyle {
        chatSettings.atmosphericText ? .richText : .text
    }

    /// Adult mode only ever applies to a character whose content age is 18 or older.
    /// Missing ages fail closed (spec #61).
    func adultMode(for character: CharacterConfig) -> Bool {
        chatSettings.adultMode && character.isAdult
    }

    /// The installed bundle's vector space: retrieval's query vector must live in it
    /// (spec #80).
    var contentEmbeddingSpace: ContentEmbeddingSpace? {
        guard let info = bundleInfo else { return nil }
        return ContentEmbeddingSpace(
            model: info.embeddingModel,
            dimensions: info.embeddingDimensions
        )
    }

    var embeddingProvider: (any EmbeddingProvider)? {
        chatSettings.embeddingConfig(for: contentEmbeddingSpace).map {
            SiliconFlowEmbedding(config: $0) as any EmbeddingProvider
        }
    }

    /// Why retrieval is off, in the producer's terms; nil when it is on. A bundle made with
    /// a service this build does not speak keeps retrieval off without blocking chat.
    /// The one reason worth telling the producer on the chat page: this bundle cannot be
    /// embedded by any service this build speaks.
    var contentBundleRetrievalWarning: String? {
        guard let space = contentEmbeddingSpace, space.service != .siliconflow else {
            return nil
        }
        return "这个内容包需要 \(space.service.title) 的向量，检索暂不可用"
    }

    var retrievalUnavailableReason: String? {
        if let warning = contentBundleRetrievalWarning { return warning }
        if contentEmbeddingSpace == nil,
           EmbeddingService(model: chatSettings.embeddingModel) == .gemini {
            return "Gemini embedding 暂未接入，检索暂不可用"
        }
        if chatSettings.embeddingConfig(for: contentEmbeddingSpace) == nil {
            return chatSettings.retrievalAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "还没有填写检索密钥，检索关闭"
                : "检索的接口地址或密钥不完整"
        }
        return nil
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
        guard let provider = backgroundProvider else { return }
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
        var cadence: ReachOutCadence = chatSettings.reachOutByTier
            ? .byTier
            : .fixed(hours: Double(chatSettings.reachOutHours))
        #if DEBUG
        // Development aid: `SIMCTL_CHILD_EIDOLON_REACH_OUT_HOURS=0.01` makes the wait short,
        // on a fixed interval.
        if let override = ProcessInfo.processInfo.environment["EIDOLON_REACH_OUT_HOURS"],
           let value = Double(override) {
            cadence = .fixed(hours: value)
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
                        cadence: cadence
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
        guard let provider = chatSettings.callConfig.map({
            ChatProviderFactory.make(config: $0)
        }) else {
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
            playback: SpeechPlayback(phoneTexture: chatSettings.phoneTexture),
            recognition: recognition,
            synthesis: speechSynthesis(readings: readings),
            voiceModel: chatSettings.fishModel,
            provider: provider,
            background: backgroundProvider,
            judge: judge,
            emotionJudge: judge == nil ? nil : emotionJudgeProvider,
            embedder: embeddingProvider,
            reranker: rerankProvider,
            tracing: tracing,
            limits: chatSettings.callLimits,
            historyTurns: chatSettings.historyTurns,
            reconnectDelay: debugReconnectDelay,
            tones: callTones,
            adultMode: adultMode(for: character),
            now: { Date() }
        )
        return try await core.beginCall(characterID: character.id, setup: setup, now: now)
    }

    // MARK: - The bar

    /// The bar over this app's library and content (ADR-0021): one, as there is one user, made
    /// the first time it is asked for and kept, so a visit under way survives the page.
    private var barRoomBox: BarRoom?

    func barRoom() async -> BarRoom {
        if let barRoomBox { return barRoomBox }
        let made = await core.barRoom()
        barRoomBox = made
        return made
    }

    /// What a visit's calls run on: the chat model and what she is told of the producer. Nil
    /// while no chat model is set up — the bar then says so instead of calling.
    var barSetup: BarRoom.Setup? {
        guard let provider = chatProvider else { return nil }
        let embedder = embeddingProvider
        let reranker = rerankProvider
        return BarRoom.Setup(
            chat: provider,
            embedder: embedder,
            reranker: reranker,
            aboutProducer: aboutProducer,
            clock: { Date() }
        )
    }

    /// What the prompts are told of the producer, kept as one line (upstream
    /// `producer_prompt(read_profile(…))`), read on the way in.
    private(set) var aboutProducer = ""
    /// The producer's own profile, for the calendar page (spec #49).
    private(set) var producerProfile = ProducerProfile.default
    /// Japan's holidays as the content bundle lists them; nil before the bundle is read.
    private(set) var holidays: HolidayTable?
    /// Whether the installed bundle carries the weekly job list (format 4). The schedule
    /// pages and their menu entry exist only then.
    private(set) var hasJobList = false
    /// Whether her cycle is told in prompts (spec #52); on until switched off.
    private(set) var cyclesEnabled = true

    /// The time zone the producer's days go by: the profile's, else this device's.
    var producerTimeZone: TimeZone {
        TimeZone(identifier: producerProfile.timezone ?? "") ?? .current
    }

    /// The bar's pictures, font and sound (nil until its package is imported), and what its
    /// preferences say; read when the bar's page opens.
    private(set) var barPackage: (info: BarBundleInfo, directory: URL)?
    private(set) var barAudio = BarAudio()
    private(set) var barSettingsValue = BarSettings.default
    private(set) var barJukeboxState = BarJukebox.State(slots: [])
    private(set) var barTutorialDone = false
    /// Whether today's first visit is still rewarded (the roster card's line).
    private(set) var barRewardToday = true

    /// Reads what the bar's page needs: its package, the music and sound that package holds,
    /// and the preferences kept beside it.
    func loadBar() async {
        aboutProducer = ((try? await core.producerProfile())?.prompt) ?? ""
        barPackage = try? await core.installedBar()
        let catalog = (try? BarAudioCatalog.read(in: core.location.contentDirectory)) ?? nil
        let package = barPackage.map {
            BarAudioPackage(tracks: $0.info.manifest.tracks, sfx: $0.info.manifest.sfx)
        }
        barAudio = catalog?.available(with: package) ?? BarAudio()
        barSettingsValue = (try? await core.barSettings()) ?? .default
        barJukeboxState = (try? await core.barJukebox(barAudio))
            ?? BarJukebox.State(slots: BarJukebox.defaultSlots(barAudio))
        barTutorialDone = (try? await core.barTutorialWalked()) ?? false
    }

    func saveBarSettings(_ settings: BarSettings) async {
        barSettingsValue = settings
        try? await core.saveBarSettings(settings)
    }

    func saveBarJukebox(_ state: BarJukebox.State) async {
        barJukeboxState = state
        try? await core.saveBarJukebox(state)
    }

    func markBarTutorialWalked() async {
        barTutorialDone = true
        try? await core.saveBarTutorialWalked()
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

    // MARK: - 朗读

    /// 朗读 her voice, if there is one: a Fish Audio key in settings and a `voice_id` in the
    /// bundle. Without either the chat has no 朗读 button rather than one that fails (ADR-0011
    /// keeps her words subtitles-only in that case).
    func readAloudVoice(for character: CharacterConfig) -> CallVoice? {
        guard !chatSettings.fishAPIKey.isEmpty,
              let voiceID = character.voiceID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !voiceID.isEmpty
        else { return nil }
        return CallVoice(id: voiceID, model: chatSettings.fishModel)
    }

    /// One line, one request — upstream `read_aloud.py` asks Fish Audio for the whole line at
    /// the selected quality rather than a call's streamed segments. The same key, voice and
    /// readings as a call, so a line sounds the same read as it does spoken.
    func readAloud(_ text: String, voice: CallVoice) async throws -> Data {
        guard !chatSettings.fishAPIKey.isEmpty else { throw FishSynthesisError.missingKey }
        let readings = (try? await core.readings()) ?? Readings()
        return try await FishSynthesis(
            apiKey: chatSettings.fishAPIKey,
            readings: readings,
            latency: ReadAloud.latency,
            timeout: ReadAloud.timeout
        ).synthesize(text, voice: voice)
    }

    func saveProducerProfile(_ profile: ProducerProfile) async throws {
        try await core.updateProducerProfile(profile)
        // The calendar, prompts and time zone read this copy, not the database (spec #55).
        // A failed re-read must not turn a successful write into a failed save.
        let saved = (try? await core.producerProfile()) ?? profile
        producerProfile = saved
        aboutProducer = saved.prompt
        await calendarExport.syncIfEnabled(source: await calendarExportSource())
    }

    /// What the system-calendar export should mirror (spec #56): every character's birthday,
    /// the producer's, and every saved job across all weeks and characters.
    func calendarExportSource() async -> CalendarExportSource {
        let saved = (try? await core.savedPlacements()) ?? []
        let names = Dictionary(
            uniqueKeysWithValues: characters.map { ($0.id, $0.nameZh ?? $0.name) }
        )
        return CalendarExportSource(
            characters: characters.map {
                CalendarExportCharacter(
                    id: $0.id, name: $0.nameZh ?? $0.name, birthday: $0.birthday
                )
            },
            producerBirthday: producerProfile.birthday.map {
                Birthday(month: $0.month, day: $0.day)
            },
            saved: saved,
            characterNames: names,
            timeZone: producerTimeZone
        )
    }

    func setCalendarExportEnabled(_ on: Bool) async {
        await calendarExport.setEnabled(on, source: await calendarExportSource())
    }

    func syncCalendarExport() async {
        await calendarExport.sync(source: await calendarExportSource())
    }

    func deleteCalendarExportEvents() async {
        await calendarExport.deleteEvents(source: await calendarExportSource())
    }

    /// Saves a week's drafts through the core and mirrors a successful save to the system
    /// calendar when the export is on (spec #56).
    func saveSchedule(
        characterID: String, week: CalendarDay, placements: [PlacementInput],
        now: Date, timeZone: TimeZone
    ) async throws -> ScheduleSave {
        let result = try await core.saveSchedule(
            characterID: characterID, week: week, placements: placements,
            now: now, timeZone: timeZone
        )
        if !result.saved.isEmpty {
            await calendarExport.syncIfEnabled(source: await calendarExportSource())
        }
        return result
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

    // MARK: - Debug mode (spec #62)

    func setDebugMode(_ on: Bool) {
        debugMode = on
        UserDefaults.standard.set(on, forKey: Self.debugModeKey)
    }

    func debugAffinity(characterID: String) async throws -> Affinity {
        try await core.debugAffinity(characterID: characterID)
    }

    func setDebugAffinity(characterID: String, value: Double) async throws {
        try await core.debugSetAffinity(characterID: characterID, value: value)
    }

    func debugMemories(conversationID: String) async throws -> [MemoryRecord] {
        try await core.debugMemories(conversationID: conversationID)
    }

    @discardableResult
    func deleteDebugMemories(ids: [String]) async throws -> Int {
        let deleted = try await core.debugDeleteMemories(ids: ids)
        await loadMemories()
        return deleted
    }

    @discardableResult
    func reopenDebugConversation(id: String) async throws -> Bool {
        try await core.debugReopenConversation(id: id)
    }

    func debugNoEnding(conversationID: String) async throws -> Bool {
        try await core.debugNoEnding(conversationID: conversationID)
    }

    func setDebugNoEnding(conversationID: String, on: Bool) async throws {
        try await core.setDebugNoEnding(conversationID: conversationID, on: on)
    }

    @discardableResult
    func setDebugCurrentConversation(
        characterID: String,
        id: String,
        reopen: Bool
    ) async throws -> Bool {
        let moved = try await core.debugSetCurrentConversation(
            characterID: characterID,
            id: id,
            reopen: reopen
        )
        if moved {
            noteConversationChanged()
        }
        return moved
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
        call.attach(self)
    }

    func bootstrap() async {
        #if DEBUG
        applyDebugAdultMode()
        applyDebugChatSettings()
        applyDebugBailianSettings()
        await importBundleForDebuggingIfRequested()
        await importStandBundleForDebuggingIfRequested()
        await importBarBundleForDebuggingIfRequested()
        #endif
        do {
            if let info = try await core.usableContentInfo() {
                bundleInfo = info
                _ = try? await core.migrateLegacyStandIfNeeded()
                try await load()
                phase = .ready
                #if DEBUG
                importAPIEnvForDebuggingIfRequested()
                #endif
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
    /// Development aid: `EIDOLON_API_ENV_FILE` names an `.env` in Documents (or an
    /// absolute path). It is applied and saved once at launch, then removed so the keys
    /// do not stay in the app container. Used to set up a device without typing keys.
    private func importAPIEnvForDebuggingIfRequested() {
        let environment = ProcessInfo.processInfo.environment
        guard let name = environment["EIDOLON_API_ENV_FILE"], !name.isEmpty else { return }
        let url = name.hasPrefix("/")
            ? URL(fileURLWithPath: name)
            : URL.documentsDirectory.appending(path: name)
        guard let data = try? Data(contentsOf: url),
              let file = try? EnvParser.parse(data: data)
        else { return }
        let report = EnvImporter.map(file, contentEmbedding: contentEmbeddingSpace)
        guard report.blockingError == nil else { return }
        var settings = chatSettings
        settings.apply(report.values)
        // An unsigned UI-test build can fail the Keychain write; this run still needs the
        // values, as the other debug seeding does.
        try? saveChatSettings(settings)
        chatSettings = settings
        try? FileManager.default.removeItem(at: url)
        Logger(subsystem: "com.jacklin.eidolon", category: "settings").notice(
            "imported .env: \(report.mapped.count) mapped, \(report.unsupported.count) unsupported, \(report.unknown.count) unknown"
        )
    }

    /// Development aid: `SIMCTL_CHILD_EIDOLON_CHAT_BASE_URL/_MODEL/_API_KEY` seed the
    /// chat settings so the simulator can talk to a real model without the keyboard.
    private func applyDebugChatSettings() {
        let environment = ProcessInfo.processInfo.environment
        guard let key = environment["EIDOLON_CHAT_API_KEY"], !key.isEmpty else { return }
        var settings = ChatSettings.load()
        settings.baseURL = environment["EIDOLON_CHAT_BASE_URL"] ?? "https://api.siliconflow.cn/v1"
        settings.model = environment["EIDOLON_CHAT_MODEL"] ?? ""
        settings.apiKey = key
        settings.historyTurns = 20
        settings.extraBody = environment["EIDOLON_CHAT_EXTRA_BODY"] ?? ""
        settings.retrievalBaseURL = environment["EIDOLON_RETRIEVAL_BASE_URL"] ?? ""
        settings.embeddingModel = environment["EIDOLON_EMBEDDING_MODEL"] ?? ""
        settings.rerankModel = environment["EIDOLON_RERANK_MODEL"] ?? ""
        settings.retrievalAPIKey = environment["EIDOLON_RETRIEVAL_API_KEY"] ?? ""
        settings.sonioxAPIKey = environment["EIDOLON_SONIOX_API_KEY"] ?? ""
        settings.sonioxModel = environment["EIDOLON_SONIOX_MODEL"] ?? "stt-rt-v5"
        settings.fishAPIKey = environment["EIDOLON_FISH_API_KEY"] ?? ""
        settings.fishModel = environment["EIDOLON_FISH_MODEL"] ?? "s2.1-pro-free"
        // A setting this seeding does not carry (atmospheric text, phone texture, the
        // judge) stays as the device had it. The UI-test build is unsigned and Keychain
        // writes can fail; the server just seeded must still answer this run, so the
        // in-memory settings are set even when saving the key did not work.
        try? saveChatSettings(settings)
        chatSettings = settings
    }

    /// Development aid: `SIMCTL_CHILD_EIDOLON_ADULT_MODE=1` turns adult mode on without
    /// the settings page. It stands alone, unlike the model settings below, which need a
    /// chat key.
    private func applyDebugAdultMode() {
        let environment = ProcessInfo.processInfo.environment
        guard let adultMode = environment["EIDOLON_ADULT_MODE"] else { return }
        var settings = ChatSettings.load()
        settings.adultMode = adultMode == "1"
        // The UI-test build is unsigned and Keychain writes can fail; the toggle itself
        // is UserDefaults, which is written before the Keychain step, so keep it in memory.
        try? settings.save()
        chatSettings = settings
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

    /// Development aid: `SIMCTL_CHILD_EIDOLON_OPEN_BAR=1` opens the bar directly.
    var debugBarRequested: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["EIDOLON_OPEN_BAR"] == "1"
        #else
        false
        #endif
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

    #if DEBUG
    private var didAutoOpenDebugSettings = false
    private var didConsumeDebugSettingsDestinations = false
    private var didConsumeDebugLatestTrace = false
    /// True only for a Settings sheet opened by a debug launch flag, not the gear button.
    private(set) var settingsOpenedByDebug = false

    private var hasDebugSettingsEntry: Bool {
        debugShowsMemories || debugShowsTraces || debugShowsStandPreview
    }

    /// The launch flag may auto-open Settings once; pressing the gear later must not
    /// keep re-opening the debug destination on every appearance.
    func openDebugSettingsIfRequested() -> Bool {
        guard !didAutoOpenDebugSettings, hasDebugSettingsEntry else { return false }
        didAutoOpenDebugSettings = true
        settingsOpenedByDebug = true
        return true
    }

    func markSettingsOpenedManually() {
        settingsOpenedByDebug = false
    }

    func consumeDebugSettingsDestinations() -> (
        memories: Bool,
        traces: Bool,
        standPreview: Bool
    )? {
        guard settingsOpenedByDebug, !didConsumeDebugSettingsDestinations,
              debugShowsMemories || debugShowsTraces || debugShowsStandPreview
        else { return nil }
        didConsumeDebugSettingsDestinations = true
        return (debugShowsMemories, debugShowsTraces, debugShowsStandPreview)
    }

    func consumeDebugLatestTrace() -> Bool {
        guard !didConsumeDebugLatestTrace, debugShowsLatestTrace else { return false }
        didConsumeDebugLatestTrace = true
        return true
    }
    #endif

    /// Development aid: `SIMCTL_CHILD_EIDOLON_IMPORT_BUNDLE` points at a bundle
    /// already copied into this app's container, so the simulator can reach the
    /// screens that normally sit behind the file picker.
    private func importStandBundleForDebuggingIfRequested() async {
        guard let path = ProcessInfo.processInfo.environment["EIDOLON_IMPORT_STAND_BUNDLE"] else {
            return
        }
        let url = path.hasPrefix("/")
            ? URL(fileURLWithPath: path)
            : URL.documentsDirectory.appending(path: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            errorMessage = "调试用的立绘包不存在：\(path)"
            return
        }
        #if DEBUG
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }
        #endif
        do {
            standInfo = try await core.installStand(bundleAt: url)
            await refreshStandCharacterIDs()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// `EIDOLON_IMPORT_BAR_BUNDLE` is the bar package's twin of the switch above.
    private func importBarBundleForDebuggingIfRequested() async {
        guard let path = ProcessInfo.processInfo.environment["EIDOLON_IMPORT_BAR_BUNDLE"] else {
            return
        }
        let url = path.hasPrefix("/")
            ? URL(fileURLWithPath: path)
            : URL.documentsDirectory.appending(path: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            errorMessage = "调试用的酒吧素材包不存在：\(path)"
            return
        }
        do {
            barInfo = try await core.installBar(bundleAt: url)
            debugLog("bar imported: \(String(describing: barInfo))")
        } catch {
            debugLog("bar import failed: \(error)")
            errorMessage = error.localizedDescription
        }
    }

    private func debugLog(_ message: String) {
        #if DEBUG
        NSLog("[eidolon] %@", message)
        #endif
    }

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
        importProgress = nil
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }

        do {
            try FileManager.default.copyItem(at: url, to: copy)
            let info = try await core.install(bundleAt: copy) { [weak self] progress in
                Task { @MainActor in self?.importProgress = progress }
            }
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
        importProgress = nil
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }

        do {
            try FileManager.default.copyItem(at: url, to: copy)
            standInfo = try await core.installStand(bundleAt: copy) { [weak self] progress in
                Task { @MainActor in self?.importProgress = progress }
            }
            await refreshStandCharacterIDs()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Installs the bar package: its pictures, its font and (when it has them) its sound.
    /// The content and stand bundles are untouched when the package is bad (ADR-0021).
    func importBarBundle(from url: URL) async {
        guard !isImporting else { return }
        isImporting = true
        errorMessage = nil
        defer { isImporting = false }

        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let copy = FileManager.default.temporaryDirectory
            .appending(path: "import-bar-\(UUID().uuidString).eidolonpkg")
        defer { try? FileManager.default.removeItem(at: copy) }
        importProgress = nil
        do {
            try FileManager.default.copyItem(at: url, to: copy)
            barInfo = try await core.installBar(bundleAt: copy) { [weak self] progress in
                Task { @MainActor in self?.importProgress = progress }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// The installed stand index, for sharing with the Mac to build a delta bundle.
    func standIndexData() async -> Data? {
        try? await core.standIndexData()
    }

    /// Deletes `.eidolonpkg` files left in the app's Documents by a USB copy or an
    /// earlier import. The installed content/stand directories are untouched.
    @discardableResult
    func removeDocumentPackages() -> Int {
        let fileManager = FileManager.default
        guard let urls = try? fileManager.contentsOfDirectory(
            at: URL.documentsDirectory,
            includingPropertiesForKeys: nil
        ) else { return 0 }
        var removed = 0
        for url in urls where url.pathExtension.lowercased() == "eidolonpkg" {
            try? fileManager.removeItem(at: url)
            removed += 1
        }
        return removed
    }

    /// The current conversation moved somewhere other than the page that shows it — a
    /// new one from the history sheet, or a debug move back to an older one (spec #37,
    /// #62). The current page reloads and the sheet closes.
    func noteConversationChanged() {
        conversationRevision += 1
    }

    /// Pins or unpins a role in this phone's roster (spec #48).
    func togglePinned(_ characterID: String) {
        roster.togglePinned(characterID)
        RosterStore.save(roster)
    }

    /// Hides or shows a role in this phone's roster (spec #48). Hidden only takes her out
    /// of the list; nothing else about her changes.
    func toggleHidden(_ characterID: String) {
        roster.toggleHidden(characterID)
        RosterStore.save(roster)
    }

    /// Switches her cycle for every character; the position itself does not change.
    func setCyclesEnabled(_ on: Bool) async {
        let before = cyclesEnabled
        cyclesEnabled = on
        do {
            try await core.setCycleEnabled(on)
        } catch {
            cyclesEnabled = before
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

    /// Whether the chat page may offer dressing her. Read from the snapshot taken with the
    /// character list, never from an on-page lookup, so the toolbar does not change after
    /// its first layout (spec #44).
    func hasStand(for characterID: String) -> Bool {
        standCharacterIDs.contains(characterID)
    }

    /// Re-reads who can be dressed after a stand package changed (spec #44).
    private func refreshStandCharacterIDs() async {
        standCharacterIDs = await core.characterIDsWithStands()
    }

    private func load() async throws {
        let characters = try await core.characters()
        // Publish the stand snapshot first: a view observing `characters` then sees a
        // consistent "who can be dressed" answer on the very first frame.
        await refreshStandCharacterIDs()
        self.characters = characters
        latest = try await core.latestActivities()
        producerProfile = (try? await core.producerProfile()) ?? .default
        aboutProducer = producerProfile.prompt
        holidays = try? await core.holidayTable()
        if let jobs = try? await core.jobList() {
            hasJobList = !jobs.isEmpty
        } else {
            hasJobList = false
        }
        cyclesEnabled = (try? await core.cycleEnabled()) ?? true
        standInfo = try await core.installedStandInfo()
        barInfo = try await core.installedBarInfo()
        barRewardToday = (try? await core.barRewardToday()) ?? true

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
