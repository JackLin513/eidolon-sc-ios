import EidolonCore
import SwiftUI
import UniformTypeIdentifiers

/// 设置 → API 与模型 (spec #80): every external service in one page, with an upstream
/// `.env` import, model listing, probes and explicit saving. Non-API settings stay on the
/// settings page.
struct APISettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var saved = ChatSettings.load()
    @State private var settings = ChatSettings.load()
    @State private var cleared: Set<SecretField> = []
    @State private var saveError: String?
    @State private var savedNotice = false
    @State private var confirmingLeave = false
    @State private var isPickingEnv = false
    @State private var imported: ImportedEnvFile?
    @State private var importError: String?
    @State private var didAutoImport = false
    @State private var picker: ModelPickerRequest?
    @State private var fetching: Set<FetchKey> = []
    @State private var fetchErrors: [FetchKey: String] = [:]
    @State private var probes: [ProbeKey: ProbeStatus] = [:]

    private enum SecretField: Hashable {
        case chat, background, judge, retrieval, soniox, dashscope, fish, bailian, jev, cloudflare
    }

    private enum FetchKey: Hashable {
        case chat, background, jev, cloudflare, bailian, embedding, rerank
    }

    private enum ProbeKey: Hashable {
        case chat, background, judge, embedding, rerank, soniox, bailianSTT, fish
    }

    private struct ImportedEnvFile: Identifiable {
        let id = UUID()
        let name: String
        let report: EnvImportReport
    }

    var body: some View {
        Form {
            summarySection
            importSection
            chatSection
            backgroundSection
            judgeSection
            retrievalSection
            callSection
        }
        .navigationTitle("API 与模型")
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("返回") { attemptLeave() }
                    .accessibilityIdentifier("api.back")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("保存") { Task { await save() } }
                    .fontWeight(.semibold)
                    .accessibilityIdentifier("api.save")
            }
        }
        .task { await load() }
        .onChange(of: settings.apiProtocol) { old, new in
            settings.baseURL = APIServiceRouting.baseURL(
                settings.baseURL,
                movingTo: new,
                from: old
            )
        }
        .onChange(of: settings.apiKey) { _, value in
            if !value.isEmpty { cleared.remove(.chat) }
        }
        .onChange(of: settings.backgroundAPIKey) { _, value in
            if !value.isEmpty { cleared.remove(.background) }
        }
        .onChange(of: settings.judgeAPIKey) { _, value in
            if !value.isEmpty { cleared.remove(.judge) }
        }
        .onChange(of: settings.retrievalAPIKey) { _, value in
            if !value.isEmpty { cleared.remove(.retrieval) }
        }
        .onChange(of: settings.sonioxAPIKey) { _, value in
            if !value.isEmpty { cleared.remove(.soniox) }
        }
        .onChange(of: settings.dashscopeAPIKey) { _, value in
            if !value.isEmpty { cleared.remove(.dashscope) }
        }
        .onChange(of: settings.fishAPIKey) { _, value in
            if !value.isEmpty { cleared.remove(.fish) }
        }
        .onChange(of: settings.bailianAPIKey) { _, value in
            if !value.isEmpty { cleared.remove(.bailian) }
        }
        .onChange(of: settings.jevAPIKey) { _, value in
            if !value.isEmpty { cleared.remove(.jev) }
        }
        .onChange(of: settings.cloudflareAPIKey) { _, value in
            if !value.isEmpty { cleared.remove(.cloudflare) }
        }
        .fileImporter(
            isPresented: $isPickingEnv,
            allowedContentTypes: [.plainText, .data],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            Task { await readEnv(at: url) }
        }
        .sheet(item: $imported) { file in
            EnvImportPreviewView(report: file.report, name: file.name) {
                imported = nil
                apply(file.report)
                Task { await save() }
            }
        }
        .sheet(item: $picker) { request in
            ModelPickerView(request: request)
        }
        .alert("保存失败", isPresented: saveErrorBinding) {
            Button("好") { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
        .alert("导入失败", isPresented: importErrorBinding) {
            Button("好") { importError = nil }
        } message: {
            Text(importError ?? "")
        }
        .alert("已保存", isPresented: $savedNotice) {
            Button("好") {}
        }
        .confirmationDialog(
            "有未保存的改动",
            isPresented: $confirmingLeave,
            titleVisibility: .visible
        ) {
            Button("放弃改动并返回", role: .destructive) { dismiss() }
            Button("继续编辑", role: .cancel) {}
        } message: {
            Text("返回会丢掉这一页还没保存的修改。")
        }
    }

    // MARK: - Sections

    private var summarySection: some View {
        Section {
            SummaryRow(title: "对话模型", configured: settings.isConfigured)
            SummaryRow(
                title: "后台模型",
                configured: settings.hasBackgroundModel
                    ? settings.backgroundConfig != nil
                    : settings.isConfigured,
                note: settings.hasBackgroundModel ? nil : "沿用对话模型"
            )
            SummaryRow(title: "判断模型", configured: app.judgeProvider(for: settings) != nil)
            SummaryRow(
                title: "检索",
                configured: settings.embeddingConfig(for: app.contentEmbeddingSpace) != nil,
                note: app.retrievalUnavailableReason
            )
            SummaryRow(
                title: "通话（\(settings.speechToText.title) + Fish）",
                configured: settings.recognitionIsConfigured
                    && !settings.fishAPIKey.trimmed.isEmpty
            )
        } header: {
            Text("当前配置")
        } footer: {
            Text("每一项显示是否已填齐。密钥保存在钥匙串，地址和模型名存在偏好设置。")
        }
    }

    private var importSection: some View {
        Section {
            Button {
                isPickingEnv = true
            } label: {
                Label("从 Files 导入 .env…", systemImage: "doc.badge.plus")
            }
            .accessibilityIdentifier("api.import")
        } header: {
            Text("导入")
        } footer: {
            Text("选上游 eidolon-sc 的 .env：先预览将改动、未识别和暂不支持的项，确认后合并并保存。"
                + "空值不覆盖现有配置；密钥只显示「将设置」，不进日志。")
        }
    }

    private var chatSection: some View {
        Section {
            Picker("接口协议", selection: $settings.apiProtocol) {
                ForEach(ChatProtocol.allCases) { chatProtocol in
                    Text(chatProtocol.title).tag(chatProtocol)
                }
            }
            .accessibilityIdentifier("api.chat.protocol")
            Text(settings.apiProtocol.path)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            if settings.apiProtocol == .anthropic {
                Text("Anthropic 地址要写到服务商的 Anthropic 前缀；DeepSeek 用 "
                    + APIServiceRouting.deepSeekAnthropicBaseURL)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            TextField("接口地址，例如 https://api.siliconflow.cn/v1", text: $settings.baseURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .accessibilityIdentifier("api.chat.baseURL")

            modelRow(
                title: "模型名",
                text: $settings.model,
                key: .chat,
                identifier: "api.chat.model"
            ) {
                fetch(key: .chat, service: modelListService, baseURL: settings.baseURL,
                      apiKey: settings.apiKey) { settings.model = $0 }
            }

            SecureField("密钥（留空保留已存密钥）", text: $settings.apiKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("api.chat.key")
            clearSecretButton(.chat, hasStored: !saved.apiKey.trimmed.isEmpty) {
                settings.apiKey = ""
            }

            TextField("max tokens（可空）", value: $settings.maxTokens, format: .number)
                .keyboardType(.numberPad)
                .accessibilityIdentifier("api.chat.maxTokens")
            effortPicker("文字对话思考强度", selection: $settings.textReasoningEffort)
                .accessibilityIdentifier("api.chat.effort")
            effortPicker("通话思考强度", selection: $settings.callReasoningEffort)
                .accessibilityIdentifier("api.chat.callEffort")
            TextField("额外参数（JSON 对象，可空）", text: $settings.extraBody, axis: .vertical)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.footnote.monospaced())
                .accessibilityIdentifier("api.chat.extraBody")

            probeButton(.chat, title: "测试对话模型") {
                await testChat()
            }
            probeStatus(.chat)
        } header: {
            APIStatusHeader(title: "对话模型", configured: settings.isConfigured)
        } footer: {
            Text(footerChat)
        }
    }

    private var backgroundSection: some View {
        Section {
            Picker("接口协议", selection: $settings.backgroundProtocol) {
                Text("沿用对话模型").tag(ChatProtocol?.none)
                ForEach(ChatProtocol.allCases) { chatProtocol in
                    Text(chatProtocol.title).tag(Optional(chatProtocol))
                }
            }
            TextField("接口地址（留空沿用对话模型）", text: $settings.backgroundBaseURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            modelRow(
                title: "模型名",
                text: $settings.backgroundModel,
                key: .background,
                identifier: "api.background.model"
            ) {
                fetch(key: .background, service: backgroundModelListService,
                      baseURL: effectiveBackgroundBaseURL,
                      apiKey: effectiveBackgroundAPIKey) { settings.backgroundModel = $0 }
            }
            SecureField("密钥（留空沿用对话模型）", text: $settings.backgroundAPIKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            clearSecretButton(.background, hasStored: !saved.backgroundAPIKey.trimmed.isEmpty) {
                settings.backgroundAPIKey = ""
            }
            TextField("max tokens（可空，不沿用对话模型）", value: $settings.backgroundMaxTokens, format: .number)
                .keyboardType(.numberPad)
            effortPicker(
                "思考强度",
                selection: $settings.backgroundTextReasoningEffort,
                protocolValue: settings.backgroundProtocol ?? settings.apiProtocol
            )
            TextField("额外参数（JSON 对象，不沿用对话模型）", text: $settings.backgroundExtraBody, axis: .vertical)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.footnote.monospaced())

            probeButton(.background, title: "测试后台模型") {
                await testBackground()
            }
            probeStatus(.background)
        } header: {
            APIStatusHeader(
                title: "后台模型（记忆与标题）",
                configured: settings.hasBackgroundModel
                    ? settings.backgroundConfig != nil
                    : settings.isConfigured,
                note: settings.hasBackgroundModel ? nil : "沿用对话模型"
            )
        } footer: {
            Text("记忆抽取和对话标题用它；角色回复和通话仍用对话模型。协议、地址、模型和密钥留空时逐项沿用对话模型；"
                + "max tokens、思考强度和额外参数是它自己的，不沿用。全部留空时不启用。")
        }
    }

    private var judgeSection: some View {
        Section {
            Picker("判断服务", selection: $settings.judgeService) {
                ForEach(JudgeService.allCases) { service in
                    Text(service.title).tag(service)
                }
            }
            .accessibilityIdentifier("api.judge.service")

            switch settings.judgeService {
            case .bailian:
                TextField("业务空间 ID", text: $settings.bailianWorkspace)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Picker("地域", selection: $settings.bailianRegion) {
                    ForEach(BailianRegion.allCases, id: \.self) { region in
                        Text(region.title).tag(region)
                    }
                }
                modelRow(
                    title: "模型名（默认 decision-model-preview）",
                    text: $settings.bailianModel,
                    key: .bailian,
                    identifier: "api.judge.bailian.model"
                ) {
                    picker = ModelPickerRequest(
                        title: "百炼判断模型",
                        models: ["decision-model-preview"],
                        current: settings.bailianModel
                    ) { settings.bailianModel = $0 }
                }
                SecureField("百炼密钥", text: $settings.bailianAPIKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                clearSecretButton(.bailian, hasStored: !saved.bailianAPIKey.trimmed.isEmpty) {
                    settings.bailianAPIKey = ""
                }
            case .jev:
                TextField("接口地址（默认 https://openrouter.ai/api/v1）", text: $settings.jevBaseURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                modelRow(
                    title: "模型名（默认 typesafe/jev-1.13）",
                    text: $settings.jevModel,
                    key: .jev,
                    identifier: "api.judge.jev.model"
                ) {
                    fetch(key: .jev, service: .openAICompatible, baseURL: settings.jevBaseURL,
                          apiKey: settings.jevAPIKey) { settings.jevModel = $0 }
                }
                SecureField("Jev 密钥", text: $settings.jevAPIKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                clearSecretButton(.jev, hasStored: !saved.jevAPIKey.trimmed.isEmpty) {
                    settings.jevAPIKey = ""
                }
            case .cloudflare:
                TextField("账号 ID", text: $settings.cloudflareAccountID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                modelRow(
                    title: "模型名（默认 clef-flash）",
                    text: $settings.cloudflareModel,
                    key: .cloudflare,
                    identifier: "api.judge.cloudflare.model"
                ) {
                    picker = ModelPickerRequest(
                        title: "Cloudflare 判断模型",
                        models: ["clef-flash", "clef"],
                        current: settings.cloudflareModel
                    ) { settings.cloudflareModel = $0 }
                }
                SecureField("Cloudflare 密钥", text: $settings.cloudflareAPIKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                clearSecretButton(.cloudflare, hasStored: !saved.cloudflareAPIKey.trimmed.isEmpty) {
                    settings.cloudflareAPIKey = ""
                }
            case .chat:
                if settings.apiProtocol == .chatCompletions {
                    Text("留空时使用对话模型。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("主对话协议不是 Chat Completions，判断模型不会继承它的地址、模型和密钥；"
                        + "要单独填齐，否则不做判断。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                TextField("接口地址", text: $settings.judgeBaseURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                modelRow(
                    title: "模型名",
                    text: $settings.judgeModel,
                    key: nil,
                    identifier: "api.judge.chat.model"
                ) {}
                SecureField("密钥", text: $settings.judgeAPIKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                clearSecretButton(.judge, hasStored: !saved.judgeAPIKey.trimmed.isEmpty) {
                    settings.judgeAPIKey = ""
                }
                TextField("额外参数（JSON 对象，可空）", text: $settings.judgeExtraBody, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.footnote.monospaced())
            }

            if settings.judgeService != .chat {
                TextField("最低概率（0–1，留空按模型阈值）", text: emotionProbability)
                    .keyboardType(.decimalPad)
                TextField("超时（秒，默认 1.5）", text: emotionTimeout)
                    .keyboardType(.decimalPad)
            }

            probeButton(.judge, title: "测试判断模型") {
                await testJudge()
            }
            probeStatus(.judge)
        } header: {
            APIStatusHeader(
                title: "判断模型",
                configured: app.judgeProvider(for: settings) != nil
            )
        } footer: {
            Text("每回合判断好感度、越界和检索需要；通话里逐段判断情绪。"
                + "Jev / Cloudflare / 百炼使用各家自己的 System One 接口；"
                + "「对话模型（JSON）」固定走 Chat Completions。")
        }
    }

    private var retrievalSection: some View {
        Section {
            if let space = app.contentEmbeddingSpace {
                LabeledContent("当前内容包", value: "\(space.model) / \(space.dimensions) 维")
                LabeledContent("对应服务", value: space.service.title)
                TextField(
                    "向量化模型（由内容包决定）",
                    text: Binding(
                        get: { space.model },
                        set: { _ in }
                    )
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .disabled(true)
                .accessibilityIdentifier("api.retrieval.embeddingModel")
                Text("要换向量化模型，先在 Mac 上用上游工具重新向量化并重新导出内容包。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                TextField("向量化模型（默认 Qwen/Qwen3-Embedding-0.6B）", text: $settings.embeddingModel)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("api.retrieval.embeddingModel")
            }
            modelRow(
                title: "重排模型（默认 Qwen/Qwen3-Reranker-0.6B）",
                text: $settings.rerankModel,
                key: .rerank,
                identifier: "api.retrieval.rerankModel"
            ) {
                fetch(
                    key: .rerank,
                    service: .openAICompatible,
                    baseURL: APIServiceRouting.retrievalBaseURL(settings.retrievalBaseURL),
                    apiKey: settings.retrievalAPIKey
                ) { settings.rerankModel = $0 }
            }
            TextField("接口地址（默认 https://api.siliconflow.cn/v1）", text: $settings.retrievalBaseURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            SecureField("检索密钥", text: $settings.retrievalAPIKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            clearSecretButton(.retrieval, hasStored: !saved.retrievalAPIKey.trimmed.isEmpty) {
                settings.retrievalAPIKey = ""
            }
            fetchButton(.embedding, title: "获取向量化模型") {
                fetch(
                    key: .embedding,
                    service: .openAICompatible,
                    baseURL: APIServiceRouting.retrievalBaseURL(settings.retrievalBaseURL),
                    apiKey: settings.retrievalAPIKey,
                    allows: embeddingModelAllowed
                ) { settings.embeddingModel = $0 }
            }
            fetchError(.embedding)
            probeButton(.embedding, title: "测试向量化") { await testEmbedding() }
            probeStatus(.embedding)
            probeButton(.rerank, title: "测试重排") { await testRerank() }
            probeStatus(.rerank)
            if let reason = app.retrievalUnavailableReason {
                Text(reason)
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        } header: {
            APIStatusHeader(
                title: "检索（向量化与重排）",
                configured: settings.embeddingConfig(for: app.contentEmbeddingSpace) != nil
            )
        } footer: {
            Text("内容包的向量化模型决定查询向量；换模型或维度必须重新导出内容包。没有密钥时不做检索。")
        }
    }

    private var callSection: some View {
        Section {
            Picker("语音识别", selection: $settings.speechToText) {
                ForEach(SpeechToTextService.allCases) { service in
                    Text(service.title).tag(service)
                }
            }
            .accessibilityIdentifier("api.call.sttProvider")
            switch settings.speechToText {
            case .soniox:
                sonioxRows
            case .bailian:
                bailianRows
            }
            SecureField("Fish Audio 密钥", text: $settings.fishAPIKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            clearSecretButton(.fish, hasStored: !saved.fishAPIKey.trimmed.isEmpty) {
                settings.fishAPIKey = ""
            }
            modelRow(
                title: "语音模型（默认 s2.1-pro-free）",
                text: $settings.fishModel,
                key: nil,
                identifier: "api.call.fishModel"
            ) {
                picker = ModelPickerRequest(
                    title: "Fish Audio 模型",
                    models: ["s2.1-pro-free", "s2.1-pro", "drama-3", "s2-pro", "s1"],
                    current: settings.fishModel
                ) { settings.fishModel = $0 }
            }
            probeButton(.fish, title: "测试 Fish Audio") { await testFish() }
            probeStatus(.fish)
        } header: {
            APIStatusHeader(
                title: "通话",
                configured: settings.recognitionIsConfigured
                    && !settings.fishAPIKey.trimmed.isEmpty
            )
        } footer: {
            Text("\(settings.speechToText.title)负责实时识别，Fish Audio 负责她的声音。"
                + "识别和 Fish 的密钥都填了才能语音通话；测试只验证密钥和地址，"
                + "不产生识别或合成费用。通话时长、回合与电话质感仍在设置页。")
        }
    }

    @ViewBuilder
    private var sonioxRows: some View {
        SecureField("Soniox 密钥", text: $settings.sonioxAPIKey)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        clearSecretButton(.soniox, hasStored: !saved.sonioxAPIKey.trimmed.isEmpty) {
            settings.sonioxAPIKey = ""
        }
        modelRow(
            title: "识别模型（默认 stt-rt-v5）",
            text: $settings.sonioxModel,
            key: nil,
            identifier: "api.call.sonioxModel"
        ) {
            picker = ModelPickerRequest(
                title: "Soniox 识别模型",
                models: ["stt-rt-v5"],
                current: settings.sonioxModel
            ) { settings.sonioxModel = $0 }
        }
        probeButton(.soniox, title: "测试 Soniox") { await testSoniox() }
        probeStatus(.soniox)
    }

    @ViewBuilder
    private var bailianRows: some View {
        SecureField("阿里云百炼密钥（DASHSCOPE_API_KEY）", text: $settings.dashscopeAPIKey)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .accessibilityIdentifier("api.call.dashscopeKey")
        clearSecretButton(.dashscope, hasStored: !saved.dashscopeAPIKey.trimmed.isEmpty) {
            settings.dashscopeAPIKey = ""
        }
        modelRow(
            title: "识别模型（默认 \(BailianSTTConfiguration.defaultModel)）",
            text: $settings.bailianSTTModel,
            key: nil,
            identifier: "api.call.bailianSTTModel"
        ) {
            picker = ModelPickerRequest(
                title: "百炼识别模型",
                models: [BailianSTTConfiguration.defaultModel],
                current: settings.bailianSTTModel
            ) { settings.bailianSTTModel = $0 }
        }
        probeButton(.bailianSTT, title: "测试百炼识别") { await testBailianSTT() }
        probeStatus(.bailianSTT)
    }

    // MARK: - Rows

    private var modelListService: ModelListService {
        settings.apiProtocol == .anthropic ? .anthropic : .openAICompatible
    }

    private var backgroundModelListService: ModelListService {
        let protocolValue = settings.backgroundProtocol ?? settings.apiProtocol
        return protocolValue == .anthropic ? .anthropic : .openAICompatible
    }

    private var effectiveBackgroundBaseURL: String {
        let trimmed = settings.backgroundBaseURL.trimmed
        return trimmed.isEmpty ? settings.baseURL : trimmed
    }

    private var effectiveBackgroundAPIKey: String {
        let trimmed = settings.backgroundAPIKey.trimmed
        return trimmed.isEmpty ? settings.apiKey : trimmed
    }

    private var footerChat: String {
        switch settings.apiProtocol {
        case .chatCompletions:
            return "任何 OpenAI 兼容的 /chat/completions 服务都可以。额外参数按 JSON 对象深合并，"
                + "不能覆盖 model、stream、messages、tools 等 App 生成的字段。"
        case .responses:
            return "请求 {地址}/responses，store 为 false，system 作为 instructions；"
                + "流式文本、工具调用和加密 reasoning 都会回传。"
        case .anthropic:
            return "请求 {地址}/messages，带 x-api-key 和 anthropic-version；"
                + "回复长度上限留空时用 16384，思考强度没有 minimal。"
        }
    }

    @ViewBuilder
    private func modelRow(
        title: String,
        text: Binding<String>,
        key: FetchKey?,
        identifier: String,
        fetch: @escaping () -> Void
    ) -> some View {
        TextField(title, text: text)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .accessibilityIdentifier(identifier)
        HStack {
            if let key {
                fetchButton(key, title: "获取模型", action: fetch)
            } else {
                Button("选择模型") { fetch() }
                    .font(.footnote)
            }
        }
        if let key {
            fetchError(key)
            if !fetchReady(key) {
                Text("先填接口地址和密钥才能获取模型")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func effortPicker(
        _ title: String,
        selection: Binding<ReasoningEffort?>,
        protocolValue: ChatProtocol? = nil
    ) -> some View {
        Picker(title, selection: selection) {
            Text("不发送（交给模型默认）").tag(ReasoningEffort?.none)
            let chosen = protocolValue ?? settings.apiProtocol
            ForEach(ReasoningEffort.allCases.filter { chosen.supports($0) }) { effort in
                Text(effort.title).tag(Optional(effort))
            }
        }
    }

    @ViewBuilder
    private func clearSecretButton(
        _ field: SecretField,
        hasStored: Bool,
        clear: @escaping () -> Void
    ) -> some View {
        if hasStored || cleared.contains(field) {
            Button("清除密钥", role: .destructive) {
                clear()
                cleared.insert(field)
            }
            .font(.footnote)
            .accessibilityIdentifier("api.clearSecret.\(field)")
        }
    }

    @ViewBuilder
    private func fetchButton(
        _ key: FetchKey,
        title: String,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            action()
        } label: {
            HStack {
                Text(title)
                if fetching.contains(key) {
                    Spacer()
                    ProgressView()
                }
            }
        }
        .disabled(fetching.contains(key) || !fetchReady(key))
        .font(.footnote)
        .accessibilityIdentifier("api.fetch.\(key)")
    }

    @ViewBuilder
    private func fetchError(_ key: FetchKey) -> some View {
        if let error = fetchErrors[key] {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private func probeButton(
        _ key: ProbeKey,
        title: String,
        action: @escaping () async -> Void
    ) -> some View {
        Button {
            Task { await action() }
        } label: {
            HStack {
                Text(title)
                if case .running = probes[key] {
                    Spacer()
                    ProgressView()
                }
            }
        }
        .disabled(isRunning(key))
        .accessibilityIdentifier("api.test.\(key)")
    }

    @ViewBuilder
    private func probeStatus(_ key: ProbeKey) -> some View {
        switch probes[key] {
        case let .success(result):
            ProbeStatusRow(result: result)
                .accessibilityIdentifier("api.probe.\(key)")
        case let .failure(result):
            ProbeStatusRow(result: result)
                .accessibilityIdentifier("api.probe.\(key)")
        default:
            EmptyView()
        }
    }

    private func isRunning(_ key: ProbeKey) -> Bool {
        if case .running = probes[key] { return true }
        return false
    }

    // MARK: - Loading and leaving

    private func load() async {
        saved = app.chatSettings
        settings = app.chatSettings
        settings.baseURL = APIServiceRouting.baseURLForImportedSettings(
            settings.baseURL,
            protocol: settings.apiProtocol
        )
        #if DEBUG
        // UI tests load a sample without a file picker; the text lives only in the
        // launch environment, never in the app's storage. Only the first appearance.
        guard !didAutoImport else { return }
        didAutoImport = true
        if let text = ProcessInfo.processInfo.environment["EIDOLON_API_ENV_TEXT"],
           !text.isEmpty {
            let file = EnvParser.parse(text: text)
            let report = EnvImporter.map(file, contentEmbedding: app.contentEmbeddingSpace)
            if report.blockingError == nil {
                imported = ImportedEnvFile(name: "sample.env", report: report)
            }
        } else if let path = ProcessInfo.processInfo.environment["EIDOLON_API_ENV_FILE"],
                  !path.isEmpty {
            await readEnv(at: URL(fileURLWithPath: path))
        }
        #endif
    }

    private func attemptLeave() {
        if settings == saved {
            dismiss()
        } else {
            confirmingLeave = true
        }
    }

    // MARK: - Saving

    private func save() async {
        guard var draft = resolvedSecrets() else { return }
        if let error = validate(draft) {
            saveError = error
            return
        }
        do {
            try app.saveChatSettings(draft)
            saved = draft
            settings = draft
            cleared.removeAll()
            savedNotice = true
        } catch {
            saveError = error.localizedDescription
        }
    }

    /// Blank secret fields mean "keep what is stored" unless the producer tapped 清除密钥.
    private func resolvedSecrets() -> ChatSettings? {
        var draft = settings
        if !cleared.contains(.chat), draft.apiKey.trimmed.isEmpty {
            draft.apiKey = saved.apiKey
        }
        if !cleared.contains(.background), draft.backgroundAPIKey.trimmed.isEmpty {
            draft.backgroundAPIKey = saved.backgroundAPIKey
        }
        if !cleared.contains(.judge), draft.judgeAPIKey.trimmed.isEmpty {
            draft.judgeAPIKey = saved.judgeAPIKey
        }
        if !cleared.contains(.retrieval), draft.retrievalAPIKey.trimmed.isEmpty {
            draft.retrievalAPIKey = saved.retrievalAPIKey
        }
        if !cleared.contains(.soniox), draft.sonioxAPIKey.trimmed.isEmpty {
            draft.sonioxAPIKey = saved.sonioxAPIKey
        }
        if !cleared.contains(.dashscope), draft.dashscopeAPIKey.trimmed.isEmpty {
            draft.dashscopeAPIKey = saved.dashscopeAPIKey
        }
        if !cleared.contains(.fish), draft.fishAPIKey.trimmed.isEmpty {
            draft.fishAPIKey = saved.fishAPIKey
        }
        if !cleared.contains(.bailian), draft.bailianAPIKey.trimmed.isEmpty {
            draft.bailianAPIKey = saved.bailianAPIKey
        }
        if !cleared.contains(.jev), draft.jevAPIKey.trimmed.isEmpty {
            draft.jevAPIKey = saved.jevAPIKey
        }
        if !cleared.contains(.cloudflare), draft.cloudflareAPIKey.trimmed.isEmpty {
            draft.cloudflareAPIKey = saved.cloudflareAPIKey
        }
        return draft
    }

    private func validate(_ draft: ChatSettings) -> String? {
        if !draft.baseURL.trimmed.isEmpty, !isURL(draft.baseURL) {
            return "对话接口地址不是有效的 URL"
        }
        if !draft.backgroundBaseURL.trimmed.isEmpty, !isURL(draft.backgroundBaseURL) {
            return "后台模型接口地址不是有效的 URL"
        }
        if !draft.judgeBaseURL.trimmed.isEmpty, !isURL(draft.judgeBaseURL) {
            return "判断模型的接口地址不是有效的 URL"
        }
        if !draft.retrievalBaseURL.trimmed.isEmpty, !isURL(draft.retrievalBaseURL) {
            return "检索接口地址不是有效的 URL"
        }
        if !draft.jevBaseURL.trimmed.isEmpty, !isURL(draft.jevBaseURL) {
            return "Jev 接口地址不是有效的 URL"
        }
        if let maxTokens = draft.maxTokens, maxTokens <= 0 {
            return "max tokens 需要是正整数"
        }
        if let maxTokens = draft.backgroundMaxTokens, maxTokens <= 0 {
            return "后台模型的 max tokens 需要是正整数"
        }
        if let effort = draft.textReasoningEffort, !draft.apiProtocol.supports(effort) {
            return "Anthropic 接口没有 \(effort.rawValue) 这一档思考强度"
        }
        if let effort = draft.callReasoningEffort, !draft.apiProtocol.supports(effort) {
            return "Anthropic 接口没有 \(effort.rawValue) 这一档思考强度"
        }
        let backgroundProtocol = draft.backgroundProtocol ?? draft.apiProtocol
        if let effort = draft.backgroundTextReasoningEffort,
           !backgroundProtocol.supports(effort) {
            return "Anthropic 接口没有 \(effort.rawValue) 这一档思考强度"
        }
        if draft.speechToText == .bailian,
           draft.bailianSTTModel.trimmed != BailianSTTConfiguration.defaultModel {
            return "百炼识别模型目前只能是 \(BailianSTTConfiguration.defaultModel)"
        }
        do {
            _ = try ChatRequestExtras.decode(draft.extraBody)
            _ = try ChatRequestExtras.decode(draft.judgeExtraBody)
            _ = try ChatRequestExtras.decode(draft.backgroundExtraBody)
        } catch {
            return error.localizedDescription
        }
        if draft.judgeService != .chat {
            let probability = emotionProbability.wrappedValue.trimmed
            if !probability.isEmpty,
               !(Double(probability).map { (0...1).contains($0) } ?? false) {
                return "最低概率需要是 0 到 1 之间的数"
            }
            let timeout = emotionTimeout.wrappedValue.trimmed
            if !timeout.isEmpty,
               !(Double(timeout).map {
                   SystemOneSegmentEmotionJudge.timeoutRange.contains($0)
               } ?? false) {
                return "超时需要是 0.1 到 10 之间的数（秒）"
            }
        }
        return nil
    }

    private func fetchReady(_ key: FetchKey) -> Bool {
        let base: String
        let apiKey: String
        switch key {
        case .chat:
            base = settings.baseURL
            apiKey = settings.apiKey
        case .background:
            base = effectiveBackgroundBaseURL
            apiKey = effectiveBackgroundAPIKey
        case .jev:
            base = settings.jevBaseURL
            apiKey = settings.jevAPIKey
        case .embedding, .rerank:
            base = APIServiceRouting.retrievalBaseURL(settings.retrievalBaseURL)
            apiKey = settings.retrievalAPIKey
        case .cloudflare, .bailian:
            return true
        }
        return isURL(base) && !apiKey.trimmed.isEmpty
    }

    private func isURL(_ text: String) -> Bool {
        guard let url = URL(string: text.trimmed), url.scheme != nil, url.host != nil else {
            return false
        }
        return true
    }

    // MARK: - Import

    private func readEnv(at url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let file = try EnvParser.parse(data: data)
            let report = EnvImporter.map(file, contentEmbedding: app.contentEmbeddingSpace)
            if let error = report.blockingError {
                importError = error.localizedDescription
                return
            }
            imported = ImportedEnvFile(name: url.lastPathComponent, report: report)
        } catch {
            importError = error.localizedDescription
        }
    }

    private func apply(_ report: EnvImportReport) {
        settings.apply(report.values)
        // Imported secrets are no longer "cleared"; an explicit clear is undone.
        cleared.removeAll()
    }

    // MARK: - Models

    private func embeddingModelAllowed(_ model: String) -> Bool {
        app.contentEmbeddingSpace.map { $0.model == model } ?? true
    }

    private func fetch(
        key: FetchKey,
        service: ModelListService,
        baseURL: String,
        apiKey: String,
        allows: ((String) -> Bool)? = nil,
        select: @escaping (String) -> Void
    ) {
        #if DEBUG
        if let list = debugModelList {
            picker = ModelPickerRequest(
                title: "选择模型",
                models: list,
                current: currentModel(for: key),
                allows: allows,
                select: select
            )
            return
        }
        #endif
        guard let url = URL(string: baseURL.trimmed), url.scheme != nil, url.host != nil else {
            fetchErrors[key] = "先填接口地址"
            return
        }
        guard !apiKey.trimmed.isEmpty else {
            fetchErrors[key] = "先填密钥"
            return
        }
        fetchErrors[key] = nil
        fetching.insert(key)
        Task {
            defer { fetching.remove(key) }
            do {
                let models = try await ModelCatalog.fetch(
                    baseURL: url,
                    apiKey: apiKey,
                    service: service
                )
                picker = ModelPickerRequest(
                    title: "选择模型",
                    models: models,
                    current: currentModel(for: key),
                    allows: allows,
                    select: select
                )
            } catch {
                fetchErrors[key] = error.localizedDescription
            }
        }
    }

    private func currentModel(for key: FetchKey) -> String {
        switch key {
        case .chat: settings.model
        case .background: settings.backgroundModel
        case .jev: settings.jevModel
        case .cloudflare: settings.cloudflareModel
        case .bailian: settings.bailianModel
        case .embedding: settings.embeddingModel
        case .rerank: settings.rerankModel
        }
    }

    #if DEBUG
    private var debugModelList: [String]? {
        guard let value = ProcessInfo.processInfo.environment["EIDOLON_API_MODEL_LIST"],
              !value.isEmpty
        else { return nil }
        return value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private var debugProbeResult: ProbeResult? {
        switch ProcessInfo.processInfo.environment["EIDOLON_API_PROBE"] {
        case "success":
            return ProbeResult(ok: true, milliseconds: 42, statusCode: 200, detail: "调试注入：成功")
        case "failure":
            return ProbeResult(ok: false, milliseconds: 42, statusCode: 401, detail: "调试注入：密钥无效")
        default:
            return nil
        }
    }
    #endif

    // MARK: - Probes

    private func runProbe(
        _ key: ProbeKey,
        _ operation: @escaping () async -> ProbeResult
    ) async {
        probes[key] = .running
        #if DEBUG
        if let injected = debugProbeResult {
            try? await Task.sleep(for: .milliseconds(150))
            probes[key] = injected.ok ? .success(injected) : .failure(injected)
            return
        }
        #endif
        let result = await operation()
        probes[key] = result.ok ? .success(result) : .failure(result)
    }

    private func testChat() async {
        await runProbe(.chat) {
            guard let config = settings.config else {
                return ProbeResult(ok: false, milliseconds: 0, detail: "还差地址、模型名或密钥")
            }
            var result = await ServiceProbe().chatModel(config)
            if !result.ok, result.statusCode == 404, settings.apiProtocol == .anthropic {
                result.detail += "（Anthropic 地址一般要写到服务商的 Anthropic 前缀，"
                    + "例如 DeepSeek 是 \(APIServiceRouting.deepSeekAnthropicBaseURL)）"
            }
            return result
        }
    }

    private func testBackground() async {
        await runProbe(.background) {
            guard let config = settings.backgroundConfig else {
                return ProbeResult(ok: false, milliseconds: 0, detail: "后台模型和对话模型都还没填齐")
            }
            return await ServiceProbe().backgroundModel(config)
        }
    }

    private func testJudge() async {
        await runProbe(.judge) {
            guard let provider = app.judgeProvider(for: settings) else {
                return ProbeResult(ok: false, milliseconds: 0, detail: "这个服务还没填完")
            }
            let started = ContinuousClock.now
            do {
                let check = try await provider.checkJudge()
                let elapsed = ContinuousClock.now - started
                let milliseconds = Int(elapsed.components.seconds) * 1000
                    + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
                var detail = "服务：\(check.service) · 模型：\(check.model)"
                if let family = check.family { detail += " · 阈值：\(family.rawValue)" }
                if check.uncalibrated { detail += " · \(JudgeCalibration.uncalibratedNote)" }
                return ProbeResult(
                    ok: true,
                    milliseconds: milliseconds,
                    model: check.model,
                    detail: detail
                )
            } catch {
                return ProbeResult(ok: false, milliseconds: 0, detail: error.localizedDescription)
            }
        }
    }

    private func testEmbedding() async {
        await runProbe(.embedding) {
            guard let config = settings.embeddingConfig(for: app.contentEmbeddingSpace) else {
                return ProbeResult(ok: false, milliseconds: 0, detail: "检索还没填齐或服务暂未接入")
            }
            return await ServiceProbe().embedding(
                config,
                expectedDimensions: app.contentEmbeddingSpace?.dimensions
            )
        }
    }

    private func testRerank() async {
        await runProbe(.rerank) {
            guard let config = settings.rerankConfig else {
                return ProbeResult(ok: false, milliseconds: 0, detail: "检索还没填齐")
            }
            return await ServiceProbe().rerank(config)
        }
    }

    private func testSoniox() async {
        await runProbe(.soniox) {
            await ServiceProbe().soniox(apiKey: settings.sonioxAPIKey)
        }
    }

    private func testBailianSTT() async {
        await runProbe(.bailianSTT) {
            await ServiceProbe().bailianSTT(
                apiKey: settings.dashscopeAPIKey,
                model: settings.bailianSTTModel
            )
        }
    }

    private func testFish() async {
        await runProbe(.fish) {
            await ServiceProbe().fish(apiKey: settings.fishAPIKey)
        }
    }

    // MARK: - Bindings

    private var saveErrorBinding: Binding<Bool> {
        Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })
    }

    private var importErrorBinding: Binding<Bool> {
        Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })
    }

    private var emotionProbability: Binding<String> {
        Binding(
            get: { settings.emotionMinProbability.map(Self.numberText) ?? "" },
            set: { settings.emotionMinProbability = Double($0.trimmed) }
        )
    }

    private var emotionTimeout: Binding<String> {
        Binding(
            get: { Self.numberText(settings.emotionTimeout) },
            set: { settings.emotionTimeout = Double($0.trimmed) ?? 1.5 }
        )
    }

    private static func numberText(_ value: Double) -> String {
        String(format: "%g", locale: Locale(identifier: "en_US_POSIX"), arguments: [value])
    }
}
