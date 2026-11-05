import EidolonCore
import SwiftUI
import UIKit
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
    @State private var testingImage = false
    @State private var confirmingImage = false
    @State private var testImage: UIImage?
    @State private var imageTestError: String?
    @State private var switchToast: String?
    @State private var editingProfile: ChatModelProfile?
    @State private var deletingProfile: ChatModelProfile?
    @State private var profileError: String?

    private enum SecretField: Hashable {
        case chat, background, judge, retrieval, gemini, soniox, dashscope, fish,
             bailian, jev, cloudflare, novelAI, gptImage
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
            profilesSection
            summarySection
            importSection
            chatSection
            backgroundSection
            judgeSection
            retrievalSection
            callSection
            imageSection
            gptImageSection
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
        .onChange(of: app.chatSettings) { _, new in
            // A profile switch or an editor save happens elsewhere; the page follows it
            // without asking, since the switch itself was already saved.
            guard new != saved else { return }
            saved = new
            settings = new
            settings.baseURL = APIServiceRouting.baseURLForImportedSettings(
                settings.baseURL, protocol: settings.apiProtocol
            )
            cleared.removeAll()
        }
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
        .onChange(of: settings.geminiAPIKey) { _, value in
            if !value.isEmpty { cleared.remove(.gemini) }
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
        .onChange(of: settings.novelAIAPIKey) { _, value in
            if !value.isEmpty { cleared.remove(.novelAI) }
        }
        .onChange(of: settings.gptImageAPIKey) { _, value in
            if !value.isEmpty { cleared.remove(.gptImage) }
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
        .sheet(item: $editingProfile) { profile in
            ChatModelProfileEditor(
                profile: profile,
                existingNames: app.chatProfiles
                    .filter { $0.id != profile.id }
                    .map(\.name)
            ) { updated, key in
                do {
                    try app.saveChatProfile(updated, apiKey: key)
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }
        }
        .confirmationDialog(
            "删除「\(deletingProfile?.name ?? "")」？",
            isPresented: Binding(
                get: { deletingProfile != nil },
                set: { if !$0 { deletingProfile = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                guard let profile = deletingProfile else { return }
                deletingProfile = nil
                do {
                    if !(try app.deleteChatProfile(profile.id)) {
                        profileError = "最后一个配置不能删除。"
                    }
                } catch {
                    profileError = error.localizedDescription
                }
            }
            Button("取消", role: .cancel) { deletingProfile = nil }
        } message: {
            Text("密钥也会一并删除，不能撤销。")
        }
        .alert("模型配置", isPresented: Binding(
            get: { profileError != nil },
            set: { if !$0 { profileError = nil } }
        )) {
            Button("好") { profileError = nil }
        } message: {
            Text(profileError ?? "")
        }
        .overlay(alignment: .top) {
            if let switchToast {
                Text(switchToast)
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 8)
                    .transition(.opacity)
                    .accessibilityIdentifier("api.profile.toast")
                    .task(id: switchToast) {
                        try? await Task.sleep(for: .seconds(1.2))
                        withAnimation { self.switchToast = nil }
                    }
            }
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

    /// The saved chat models (spec #116): one row each, a check on the active one, and
    /// what is missing when a row is not filled in. Tapping switches and saves at once.
    private var profilesSection: some View {
        Section {
            ForEach(app.chatProfiles) { profile in
                Button {
                    switchProfile(profile.id)
                } label: {
                    profileRow(profile)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("api.profile.row.\(profile.id)")
                .accessibilityLabel(profile.name)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    if app.chatProfiles.count > 1 {
                        Button(role: .destructive) {
                            deletingProfile = profile
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                    Button {
                        editingProfile = profile
                    } label: {
                        Label("编辑", systemImage: "pencil")
                    }
                }
                .contextMenu {
                    Button("编辑") { editingProfile = profile }
                    Button("复制") { editingProfile = app.duplicateChatProfile(profile) }
                    if app.chatProfiles.count > 1 {
                        Button("删除", role: .destructive) { deletingProfile = profile }
                    }
                }
            }
            Button {
                editingProfile = app.addChatProfile()
            } label: {
                Label("新建配置", systemImage: "plus")
            }
            .accessibilityIdentifier("api.profile.new")
        } header: {
            Text("模型配置")
        } footer: {
            Text("点一行即切换并立即保存，不用再按「保存」。只换对话模型；后台模型留空时跟着它走，"
                + "判断、检索、通话和生图不变。左滑或长按可编辑、复制、删除。")
        }
    }

    private func profileRow(_ profile: ChatModelProfile) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(profile.name)
                    .foregroundStyle(.primary)
                Text(profile.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !profile.isComplete {
                Text("未填完")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if profile.id == app.activeChatProfileID {
                Image(systemName: "checkmark")
                    .foregroundStyle(.tint)
            }
        }
        .contentShape(Rectangle())
    }

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
                configured: settings.retrievalEmbeddingConfig(for: app.contentEmbeddingSpace) != nil,
                note: app.retrievalUnavailableReason
            )
            SummaryRow(
                title: "通话（\(settings.speechToText.title) + Fish）",
                configured: settings.recognitionIsConfigured
                    && !settings.fishAPIKey.trimmed.isEmpty
            )
            SummaryRow(
                title: "生图",
                configured: settings.imageIsConfigured,
                note: settings.gptImageIsConfigured ? "GPT Image" : nil
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
            // Four erased chunks, not one big tuple: a single Section content type with
            // this many rows overflows the device's Swift demangler at launch.
            AnyView(chatAddressRows)
            AnyView(chatModelRows)
            AnyView(chatSecretRows)
            AnyView(chatExtraRows)
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

    @ViewBuilder
    private var chatAddressRows: some View {
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
        SettingsHint("服务根地址，OpenAI 兼容通常以 /v1 结尾；DeepSeek 是 https://api.deepseek.com/v1。")
    }

    @ViewBuilder
    private var chatModelRows: some View {
        modelRow(
            title: "模型名",
            text: $settings.model,
            key: .chat,
            identifier: "api.chat.model"
        ) {
            fetch(key: .chat, service: modelListService, baseURL: settings.baseURL,
                  apiKey: settings.apiKey) { settings.model = $0 }
        }
        SettingsHint("服务上的模型标识，例如 deepseek-chat；可点「获取模型」从列表里选。")
    }

    @ViewBuilder
    private var chatSecretRows: some View {
        SecureField("密钥（留空保留已存密钥）", text: $settings.apiKey)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .accessibilityIdentifier("api.chat.key")
        clearSecretButton(.chat, hasStored: !saved.apiKey.trimmed.isEmpty) {
            settings.apiKey = ""
        }
        SettingsHint("只存钥匙串，属于当前这套模型配置；留空保留已存密钥，点「清除密钥」才会删。")
    }

    @ViewBuilder
    private var chatExtraRows: some View {
        TextField("max tokens（可空）", value: $settings.maxTokens, format: .number)
            .keyboardType(.numberPad)
            .accessibilityIdentifier("api.chat.maxTokens")
        SettingsHint(
            "单次回复最多多少 token；留空用服务默认，不限制。",
            identifier: "api.hint.chat.maxTokens"
        )
        effortPicker("文字对话思考强度", selection: $settings.textReasoningEffort)
            .accessibilityIdentifier("api.chat.effort")
        SettingsHint("文字回合想多深；不发送 = 交给模型默认。本地模型想完全关掉思考，用额外参数。")
        effortPicker("通话思考强度", selection: $settings.callReasoningEffort)
            .accessibilityIdentifier("api.chat.callEffort")
        SettingsHint("通话里想多深；想得越久她开口越慢。不发送 = 模型默认。")
        TextField("额外参数（JSON 对象，可空）", text: $settings.extraBody, axis: .vertical)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .font(.footnote.monospaced())
            .accessibilityIdentifier("api.chat.extraBody")
        SettingsHint(
            "JSON 对象，深合并进请求；不能覆盖 model/stream/messages/tools。例：{\"enable_thinking\": false}",
            identifier: "api.hint.chat.extraBody"
        )
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
            SettingsHint("留空 = 用对话模型的地址；填了才把记忆和标题发去别处。")
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
            SettingsHint("留空 = 沿用对话模型的模型名。")
            SecureField("密钥（留空沿用对话模型）", text: $settings.backgroundAPIKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SettingsHint("留空 = 沿用对话模型的密钥；只存钥匙串。")
            clearSecretButton(.background, hasStored: !saved.backgroundAPIKey.trimmed.isEmpty) {
                settings.backgroundAPIKey = ""
            }
            TextField("max tokens（可空，不沿用对话模型）", value: $settings.backgroundMaxTokens, format: .number)
                .keyboardType(.numberPad)
            SettingsHint("后台模型自己的单次上限；留空 = 不限制，不会沿用对话模型的值。")
            effortPicker(
                "思考强度",
                selection: $settings.backgroundTextReasoningEffort,
                protocolValue: settings.backgroundProtocol ?? settings.apiProtocol
            )
            TextField("额外参数（JSON 对象，不沿用对话模型）", text: $settings.backgroundExtraBody, axis: .vertical)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.footnote.monospaced())
            SettingsHint("JSON 对象；留空 = 不加，不会沿用对话模型。")

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
            SettingsHint("每回合判断越界、好感度和检索；通话里逐段判断情绪。没有它也能聊，只是少了这些判断。")

            switch settings.judgeService {
            case .bailian:
                TextField("业务空间 ID", text: $settings.bailianWorkspace)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SettingsHint(
                    "阿里云百炼控制台右上角「业务空间」里的 ID；默认空间可以留空。",
                    identifier: "api.hint.judge.bailianWorkspace"
                )
                Picker("地域", selection: $settings.bailianRegion) {
                    ForEach(BailianRegion.allCases, id: \.self) { region in
                        Text(region.title).tag(region)
                    }
                }
                SettingsHint("百炼服务所在地域，要和业务空间一致。")
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
                SettingsHint("百炼上的判断模型名，默认 decision-model-preview。")
                SecureField("百炼密钥", text: $settings.bailianAPIKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SettingsHint("阿里云百炼的 API Key（DASHSCOPE_API_KEY）；只存钥匙串。")
                clearSecretButton(.bailian, hasStored: !saved.bailianAPIKey.trimmed.isEmpty) {
                    settings.bailianAPIKey = ""
                }
            case .jev:
                TextField("接口地址（默认 https://openrouter.ai/api/v1）", text: $settings.jevBaseURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                SettingsHint("Jev 服务地址，默认走 OpenRouter；留空用默认值。")
                modelRow(
                    title: "模型名（默认 typesafe/jev-1.13）",
                    text: $settings.jevModel,
                    key: .jev,
                    identifier: "api.judge.jev.model"
                ) {
                    fetch(key: .jev, service: .openAICompatible, baseURL: settings.jevBaseURL,
                          apiKey: settings.jevAPIKey) { settings.jevModel = $0 }
                }
                SettingsHint("用于判断的模型名，默认 typesafe/jev-1.13。")
                SecureField("Jev 密钥", text: $settings.jevAPIKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SettingsHint("OpenRouter / Jev 的 API Key；只存钥匙串。")
                clearSecretButton(.jev, hasStored: !saved.jevAPIKey.trimmed.isEmpty) {
                    settings.jevAPIKey = ""
                }
            case .cloudflare:
                TextField("账号 ID", text: $settings.cloudflareAccountID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SettingsHint(
                    "Cloudflare 控制台 Workers & Pages 右侧的 Account ID。",
                    identifier: "api.hint.judge.cloudflareAccount"
                )
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
                SettingsHint("Cloudflare Workers AI 上的模型名，默认 clef-flash。")
                SecureField("Cloudflare 密钥", text: $settings.cloudflareAPIKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SettingsHint("Cloudflare API Token；只存钥匙串。")
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
                SettingsHint("留空 = 用对话模型的地址；只支持 Chat Completions。")
                modelRow(
                    title: "模型名",
                    text: $settings.judgeModel,
                    key: nil,
                    identifier: "api.judge.chat.model"
                ) {}
                SettingsHint("留空 = 用对话模型的模型名。")
                SecureField("密钥", text: $settings.judgeAPIKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SettingsHint("留空 = 用对话模型的密钥；只存钥匙串。")
                clearSecretButton(.judge, hasStored: !saved.judgeAPIKey.trimmed.isEmpty) {
                    settings.judgeAPIKey = ""
                }
                TextField("额外参数（JSON 对象，可空）", text: $settings.judgeExtraBody, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.footnote.monospaced())
                SettingsHint("JSON 对象，深合并进判断请求；留空不加。")
            }

            if settings.judgeService != .chat {
                TextField("最低概率（0–1，留空按模型阈值）", text: emotionProbability)
                    .keyboardType(.decimalPad)
                SettingsHint("情绪判断的置信度门槛，0 到 1；留空用模型族自己的默认。")
                TextField("超时（秒，默认 1.5）", text: emotionTimeout)
                    .keyboardType(.decimalPad)
                SettingsHint("一段话最多等判断多久；超时就先不标情绪，不拖慢回复。")
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
            let service = settings.retrievalService(for: app.contentEmbeddingSpace)
            if let space = app.contentEmbeddingSpace {
                LabeledContent("当前内容包", value: "\(space.model) / \(space.dimensions) 维")
                LabeledContent("对应服务", value: space.service.title)
                TextField(
                    "向量化模型（由内容包决定）",
                    text: Binding(get: { space.model }, set: { _ in })
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .disabled(true)
                .accessibilityIdentifier("api.retrieval.embeddingModel")
                Text("要换向量化模型，先在 Mac 上用上游工具重新向量化并重新导出内容包。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Picker("向量化服务", selection: $settings.embeddingProvider) {
                    ForEach(EmbeddingService.allCases) { provider in
                        Text(provider.title).tag(provider)
                    }
                }
                .accessibilityIdentifier("api.retrieval.provider")
                TextField("向量化模型", text: $settings.embeddingModel)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("api.retrieval.embeddingModel")
                SettingsHint("内容包的向量化模型必须和它一致；这里是还没导入内容包时的默认值。")
                if settings.embeddingProvider == .gemini {
                    TextField("向量维度（默认 1536）", value: $settings.embeddingDimensions, format: .number)
                        .keyboardType(.numberPad)
                    SettingsHint("向量维度；留空用内容包或服务默认，常见是 1536。")
                }
            }

            if service == .gemini {
                SecureField("Gemini 密钥", text: $settings.geminiAPIKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("api.retrieval.geminiKey")
                SettingsHint("内容包用 Gemini 向量化时才需要；只存钥匙串。")
                clearSecretButton(.gemini, hasStored: !saved.geminiAPIKey.trimmed.isEmpty) {
                    settings.geminiAPIKey = ""
                }
                TextField(
                    "Gemini 接口地址（默认 https://generativelanguage.googleapis.com/v1beta）",
                    text: $settings.geminiBaseURL
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                SettingsHint("留空用默认地址；一般不用改。")
                if app.contentEmbeddingSpace == nil {
                    modelRow(
                        title: "向量化模型",
                        text: $settings.embeddingModel,
                        key: nil,
                        identifier: "api.retrieval.geminiModel"
                    ) {
                        picker = ModelPickerRequest(
                            title: "Gemini 向量化模型",
                            models: ["gemini-embedding-2", "gemini-embedding-001"],
                            current: settings.embeddingModel
                        ) { settings.embeddingModel = $0 }
                    }
                    SettingsHint("导入内容包后以内容包为准，这里只影响还没有内容包时的检索。")
                }
            } else {
                SecureField("硅基流动密钥（向量化）", text: $settings.retrievalAPIKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SettingsHint("硅基流动的 API Key；只存钥匙串。没有它就不做剧情检索。")
                clearSecretButton(.retrieval, hasStored: !saved.retrievalAPIKey.trimmed.isEmpty) {
                    settings.retrievalAPIKey = ""
                }
                TextField(
                    "硅基流动接口地址（默认 https://api.siliconflow.cn/v1）",
                    text: $settings.retrievalBaseURL
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                SettingsHint("留空用默认地址；向量化和重排都走这里。")
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
            SettingsHint("检索结果的重排模型；留空不重排，只用向量相似度。")
            if service == .gemini {
                SecureField("硅基流动密钥（重排用）", text: $settings.retrievalAPIKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SettingsHint("重排仍走硅基流动，所以 Gemini 向量化时两个 key 都要有。")
                clearSecretButton(.retrieval, hasStored: !saved.retrievalAPIKey.trimmed.isEmpty) {
                    settings.retrievalAPIKey = ""
                }
                TextField(
                    "硅基流动接口地址（默认 https://api.siliconflow.cn/v1）",
                    text: $settings.retrievalBaseURL
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                SettingsHint("留空用默认地址；向量化和重排都走这里。")
            }
            if service == .gemini {
                fetchButton(.rerank, title: "获取重排模型") {
                    fetch(
                        key: .rerank,
                        service: .openAICompatible,
                        baseURL: APIServiceRouting.retrievalBaseURL(settings.retrievalBaseURL),
                        apiKey: settings.retrievalAPIKey
                    ) { settings.rerankModel = $0 }
                }
            }

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
                configured: settings.retrievalEmbeddingConfig(for: app.contentEmbeddingSpace) != nil
            )
        } footer: {
            Text("内容包的向量化模型决定查询向量；换模型或维度必须重新导出内容包。"
                + "Gemini 只做向量化，重排仍在硅基流动，所以两个 key 都要有。没有密钥时不做检索。")
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
            SettingsHint("通话时听你说话的识别服务；选哪家就填哪家的密钥。")
            switch settings.speechToText {
            case .soniox:
                sonioxRows
            case .bailian:
                bailianRows
            }
            SecureField("Fish Audio 密钥", text: $settings.fishAPIKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SettingsHint("Fish Audio 的 API Key；只存钥匙串。没有它通话只有文字，没有声音。")
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
            SettingsHint("语音合成模型，默认免费的 s2.1-pro-free。")
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
        SettingsHint("Soniox 的 API Key；只存钥匙串。")
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
        SettingsHint("实时识别模型，默认 stt-rt-v5；一般不用改。")
        probeButton(.soniox, title: "测试 Soniox") { await testSoniox() }
        probeStatus(.soniox)
    }

    @ViewBuilder
    private var bailianRows: some View {
        SecureField("阿里云百炼密钥（DASHSCOPE_API_KEY）", text: $settings.dashscopeAPIKey)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .accessibilityIdentifier("api.call.dashscopeKey")
        SettingsHint("阿里云百炼的 API Key；只存钥匙串。")
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
        SettingsHint("百炼实时识别模型，目前固定为默认值。")
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

    private var imageSection: some View {
        Section {
            Picker("接口形式", selection: $settings.imageAPIFormat) {
                ForEach(ImageAPIFormat.allCases) { format in
                    Text(format.title).tag(format)
                }
            }
            .accessibilityIdentifier("api.image.format")
            SettingsHint("NovelAI 原生接口，或 OpenAI 兼容的图片接口。")
            TextField("接口地址，例如 https://image.novelai.net", text: $settings.imageBaseURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            SettingsHint("NovelAI 原生格式写到域名根；OpenAI 图像格式写到 /v1。")
            SecureField("NovelAI 密钥（留空保留已存密钥）", text: $settings.novelAIAPIKey)
            clearSecretButton(.novelAI, hasStored: !saved.novelAIAPIKey.trimmed.isEmpty) {
                settings.novelAIAPIKey = ""
            }
            TextField("普通模型", text: $settings.imageModel)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SettingsHint("全年龄照片用的 NovelAI 模型名。")
            TextField("成人模型", text: $settings.imageAdultModel)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SettingsHint("成人模式且角色 18 岁以上时才用；普通照片不用它。")
            TextField("画风（可选，原样写进提示词）", text: $settings.imageStyle)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SettingsHint("风格 tag，原样拼进生图提示词；留空不加。")
            TextField("制作人形象 tag（他入镜时用）", text: $settings.imageProducerTags)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SettingsHint("他入镜时的第二个角色提示词，例如西装领带；留空用内置形象。")
            Stepper(value: $settings.imageHourlyLimit, in: 0...50) {
                Text("每小时最多 \(settings.imageHourlyLimit) 张（0 不限）")
            }
            SettingsHint("滚动一小时内最多发几张；0 = 不限制。")
            Button {
                confirmingImage = true
            } label: {
                HStack {
                    Text("试一张")
                    if testingImage { Spacer(); ProgressView() }
                }
            }
            .disabled(testingImage || !settings.imageSettings.isConfigured)
            .accessibilityIdentifier("api.image.try")
            .confirmationDialog(
                "试一张会真的生成一张图，并花掉一张的钱；用 4.5 的 Curated 模型，"
                    + "不计入用量和每小时额度。",
                isPresented: $confirmingImage,
                titleVisibility: .visible
            ) {
                Button("生成一张") {
                    Task { await testImageGeneration() }
                }
                Button("取消", role: .cancel) {}
            }
            if let testImage {
                Image(uiImage: testImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .accessibilityIdentifier("api.image.tried")
            }
            if let imageTestError {
                Text(imageTestError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            APIStatusHeader(title: "生图", configured: settings.imageIsConfigured)
        } footer: {
            Text("NovelAI 原生格式把地址写到域名根；OpenAI 图像格式写到 /v1。密钥只保存在钥匙串；"
                + "「试一张」会真的花一张的钱，固定用 4.5 的 Curated 模型，不计入用量和每小时额度。")
        }
    }

    private var gptImageSection: some View {
        Section {
            Toggle("用 GPT Image 画无人配图", isOn: $settings.gptImageEnabled)
                .accessibilityIdentifier("api.gptImage.enabled")
            SettingsHint("只给风景、食物、物品这类没有人的朋友圈配图；人物仍走 NovelAI。")
            if settings.gptImageEnabled {
                TextField("接口地址", text: $settings.gptImageBaseURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                SettingsHint("OpenAI 兼容的图片接口地址，通常以 /v1 结尾。")
                SecureField("GPT Image 密钥（留空保留已存密钥）", text: $settings.gptImageAPIKey)
                clearSecretButton(.gptImage, hasStored: !saved.gptImageAPIKey.trimmed.isEmpty) {
                    settings.gptImageAPIKey = ""
                }
                TextField("模型", text: $settings.gptImageModel)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SettingsHint("图片模型名，例如 gpt-image-1。")
                Picker("质量", selection: $settings.gptImageQuality) {
                    ForEach(GPTImageQuality.allCases) { quality in
                        Text(quality.title).tag(quality)
                    }
                }
                SettingsHint("质量越高越慢也越贵；朋友圈配图用默认的中档就够。")
                TextField("画风", text: $settings.gptImageStyle, axis: .vertical)
                    .lineLimit(2...5)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SettingsHint("文字描述的画面风格，原样拼进提示词；可留空。")
            }
        } header: {
            APIStatusHeader(title: "GPT Image（可选）", configured: settings.gptImageIsConfigured)
        } footer: {
            Text("只给朋友圈里没有人的风景、食物和物品配图；人物、合照和照片始终走 NovelAI。")
        }
    }

    private func testImageGeneration() async {
        testingImage = true
        imageTestError = nil
        defer { testingImage = false }
        do {
            // The fixed all-ages try-out, with the style the producer set, on the cheaper
            // 4.5 model. It writes no photo row and no usage record, so it neither uses up
            // this hour's pictures nor shows up in the ledger (spec #98).
            let style = settings.imageStyle.trimmingCharacters(in: .whitespacesAndNewlines)
            let prompt = style.isEmpty
                ? "1girl, solo, smile, simple background"
                : "1girl, solo, smile, simple background, \(style)"
            let imageSettings = settings.imageSettings.testSettings
            let request = ImageRequest(
                prompt: prompt,
                negativePrompt: "nsfw, lowres, bad anatomy, text, watermark",
                width: PhotoGeometry.width,
                height: PhotoGeometry.height,
                model: imageSettings.model
            )
            let data = try await RemoteImageGenerator().generate(
                request,
                settings: imageSettings
            )
            guard let image = UIImage(data: data) else {
                throw ImageGenerationError.badImage("图片解不开")
            }
            testImage = image
        } catch {
            imageTestError = error.localizedDescription
        }
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

    private func switchProfile(_ id: String) {
        guard id != app.activeChatProfileID else { return }
        do {
            try app.activateChatProfile(id)
            let name = app.activeChatProfile?.name ?? ""
            withAnimation { switchToast = "已切换到 \(name)" }
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func save() async {
        guard var draft = resolvedSecrets() else { return }
        if let error = validate(draft) {
            saveError = error
            return
        }
        do {
            let normalized = try app.saveChatSettings(draft)
            try app.captureActiveChatProfile(
                from: normalized, clearKey: cleared.contains(.chat)
            )
            saved = normalized
            settings = normalized
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
        if !cleared.contains(.gemini), draft.geminiAPIKey.trimmed.isEmpty {
            draft.geminiAPIKey = saved.geminiAPIKey
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
        if !cleared.contains(.novelAI), draft.novelAIAPIKey.trimmed.isEmpty {
            draft.novelAIAPIKey = saved.novelAIAPIKey
        }
        if !cleared.contains(.gptImage), draft.gptImageAPIKey.trimmed.isEmpty {
            draft.gptImageAPIKey = saved.gptImageAPIKey
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
        if !draft.imageBaseURL.trimmed.isEmpty, !isURL(draft.imageBaseURL) {
            return "生图接口地址不是有效的 URL"
        }
        if draft.gptImageEnabled,
           !draft.gptImageBaseURL.trimmed.isEmpty,
           !isURL(draft.gptImageBaseURL) {
            return "GPT Image 接口地址不是有效的 URL"
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
            guard let config = settings.retrievalEmbeddingConfig(for: app.contentEmbeddingSpace) else {
                return ProbeResult(ok: false, milliseconds: 0, detail: "检索还没填齐")
            }
            switch config {
            case let .siliconFlow(config):
                return await ServiceProbe().embedding(
                    config,
                    expectedDimensions: app.contentEmbeddingSpace?.dimensions
                )
            case let .gemini(config):
                return await ServiceProbe().geminiEmbedding(
                    config,
                    expectedDimensions: app.contentEmbeddingSpace?.dimensions
                )
            }
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
