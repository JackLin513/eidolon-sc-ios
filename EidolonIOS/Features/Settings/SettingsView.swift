import EidolonCore
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var baseURL = ""
    @State private var model = ""
    @State private var apiKey = ""
    @State private var historyTurns = 20
    @State private var extraBody = ""
    @State private var judgeBaseURL = ""
    @State private var judgeModel = ""
    @State private var judgeAPIKey = ""
    @State private var judgeExtraBody = ""
    @State private var judgeService: JudgeService = .bailian
    @State private var bailianWorkspace = ""
    @State private var bailianRegion: BailianRegion = .beijing
    @State private var bailianModel = "decision-model-preview"
    @State private var bailianAPIKey = ""
    @State private var jevBaseURL = JevJudgeConfig.defaultBaseURL
    @State private var jevModel = JevJudgeConfig.defaultModel
    @State private var jevAPIKey = ""
    @State private var cloudflareAccountID = ""
    @State private var cloudflareModel = CloudflareJudgeConfig.defaultModel
    @State private var cloudflareAPIKey = ""
    /// The judge's minimum probability, blank for the model family's own; and how long a
    /// segment's emotion may take, in seconds (spec「情绪判断」).
    @State private var emotionMinProbability = ""
    @State private var emotionTimeout = "1.5"
    @State private var isTestingJudge = false
    @State private var judgeCheck: JudgeCheck?
    @State private var judgeCheckError: String?
    @State private var retrievalBaseURL = ""
    @State private var embeddingModel = ""
    @State private var rerankModel = ""
    @State private var retrievalAPIKey = ""
    @State private var sonioxAPIKey = ""
    @State private var sonioxModel = "stt-rt-v5"
    @State private var fishAPIKey = ""
    @State private var fishModel = "s2.1-pro-free"
    @State private var callMinutes = 10
    @State private var callTurns = 40
    @State private var saveError: String?
    @State private var savedNotice = false
    @State private var reachOutHours = 6
    @State private var formOfAddress = ""
    @State private var gender = "default"
    @State private var profileTimezone = ""
    @State private var birthdayOn = false
    @State private var birthdayMonth = 1
    @State private var birthdayDay = 1
    @State private var tracingEnabled = true
    @State private var traceRetention = 200
    @State private var isPicking = false
    @State private var importKind: ImportKind = .content
    @State private var showMemories = false
    @State private var showTraces = false
    @State private var showStandPreview = false
    @State private var standIndexURL: URL?
    @State private var confirmingPackageCleanup = false

    private enum ImportKind {
        case content
        case stand
        case bar
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("接口地址，例如 https://api.siliconflow.cn/v1", text: $baseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("模型名", text: $model)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("密钥", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Stepper("历史回合：\(historyTurns)", value: $historyTurns, in: 1...100)
                    TextField("额外参数（JSON，可空）", text: $extraBody, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.footnote.monospaced())
                } header: {
                    Text("对话模型")
                } footer: {
                    Text("任何 OpenAI 兼容的 /chat/completions 服务都可以。密钥保存在钥匙串，地址和模型名存在偏好设置。")
                }

                Section {
                    Picker("判断服务", selection: $judgeService) {
                        ForEach(JudgeService.allCases) { service in
                            Text(service.title).tag(service)
                        }
                    }
                    switch judgeService {
                    case .bailian:
                        TextField("业务空间 ID", text: $bailianWorkspace)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Picker("地域", selection: $bailianRegion) {
                            ForEach(BailianRegion.allCases, id: \.self) { region in
                                Text(region.title).tag(region)
                            }
                        }
                        TextField("模型名（默认 decision-model-preview）", text: $bailianModel)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("百炼密钥", text: $bailianAPIKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    case .jev:
                        TextField(
                            "接口地址（默认 https://openrouter.ai/api/v1）",
                            text: $jevBaseURL
                        )
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        TextField("模型名（默认 typesafe/jev-1.13）", text: $jevModel)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("Jev 密钥", text: $jevAPIKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    case .cloudflare:
                        TextField("账号 ID", text: $cloudflareAccountID)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("模型名（默认 clef-flash）", text: $cloudflareModel)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("Cloudflare 密钥", text: $cloudflareAPIKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    case .chat:
                        TextField("接口地址", text: $judgeBaseURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                        TextField("模型名", text: $judgeModel)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("密钥", text: $judgeAPIKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("额外参数（JSON，可空）", text: $judgeExtraBody, axis: .vertical)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.footnote.monospaced())
                    }
                    if judgeService != .chat {
                        TextField("最低概率（0–1，留空按模型阈值）", text: $emotionMinProbability)
                            .keyboardType(.decimalPad)
                        TextField("超时（秒，默认 1.5）", text: $emotionTimeout)
                            .keyboardType(.decimalPad)
                        Text("她每说完一段，用同一个服务判断这一段的表情和点头；概率低于阈值时按平静演，超时或失败就不判断。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if let note = judgeUncalibratedNote {
                        Text(note)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        Task { await testJudge() }
                    } label: {
                        HStack {
                            Text("测试判断模型")
                            if isTestingJudge {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isTestingJudge)
                } header: {
                    Text("判断模型")
                } footer: {
                    switch judgeService {
                    case .bailian:
                        Text("每回合用百炼的 System One 一次问完六道题，按这个模型所属一族的阈值读概率。业务空间 ID、地域和密钥要互相对应；密钥保存在钥匙串。")
                    case .jev:
                        Text("每回合用 Jev 的 System One 一次问完六道题，地址是接口地址加 /systemone。默认借 OpenRouter 调 typesafe/jev-1.13，按 jev 的阈值读概率；密钥保存在钥匙串。")
                    case .cloudflare:
                        Text("每回合用 Workers AI 上的 clef 或 clef-flash 一次问完六道题，地址由账号 ID 和模型名拼出，模型名只写裸名。clef 与 clef-flash 各自按自己的阈值读概率；每天免费的 1 万 neurons 用完后要等第二天。")
                    case .chat:
                        Text("每回合判断这句话对好感度的影响。留空则使用对话模型；都不可用时不做判断，好感度不变。")
                    }
                }

                Section {
                    TextField("接口地址（默认 https://api.siliconflow.cn/v1）", text: $retrievalBaseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("向量化模型（默认 Qwen/Qwen3-Embedding-0.6B）", text: $embeddingModel)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("重排模型（默认 Qwen/Qwen3-Reranker-0.6B）", text: $rerankModel)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("密钥", text: $retrievalAPIKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("检索（向量化与重排）")
                } footer: {
                    Text("内容包的向量是用 Qwen3-Embedding-0.6B 算的，换模型需要重新向量化并重新导出内容包。没有密钥时不做检索。")
                }

                Section {
                    SecureField("Soniox 密钥", text: $sonioxAPIKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("识别模型（默认 stt-rt-v5）", text: $sonioxModel)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Fish Audio 密钥", text: $fishAPIKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("语音模型（默认 s2.1-pro-free）", text: $fishModel)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("时长上限（分钟，0 为不限）", value: $callMinutes, format: .number)
                        .keyboardType(.numberPad)
                    TextField("回合上限（她的回合数，0 为不限）", value: $callTurns, format: .number)
                        .keyboardType(.numberPad)
                } header: {
                    Text("通话")
                } footer: {
                    Text("Soniox 负责实时识别你说的话，Fish Audio 负责她的声音。密钥保存在钥匙串。默认每通电话最多 10 分钟、她最多 40 个回合，从接通起算；时长与回合都到点时先按时长算。改完从下一通电话开始生效。")
                }

                Section {
                    TextField("称呼（留空沿用默认）", text: $formOfAddress)
                    Picker("性别", selection: $gender) {
                        Text("沿用默认").tag("default")
                        Text("男性").tag("male")
                        Text("女性").tag("female")
                    }
                    TextField("时区（例如 Asia/Shanghai，留空跟随设备）", text: $profileTimezone)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Toggle("设置生日", isOn: $birthdayOn)
                    if birthdayOn {
                        Picker("生日月份", selection: $birthdayMonth) {
                            ForEach(1...12, id: \.self) { month in
                                Text("\(month) 月").tag(month)
                            }
                        }
                        Picker("生日日期", selection: $birthdayDay) {
                            ForEach(1...31, id: \.self) { day in
                                Text("\(day) 日").tag(day)
                            }
                        }
                    }
                } header: {
                    Text("制作人档案")
                } footer: {
                    Text("只影响她当下怎么对待你，不改写剧情。生日只在当天被她主动提起。")
                }

                Section {
                    Stepper("搭话间隔：\(reachOutHours) 小时", value: $reachOutHours, in: 1...72)
                } header: {
                    Text("搭话")
                } footer: {
                    Text("超过这么久没说话，她会在打开 App 时先给你发一条。同一次沉默只发一次。")
                }

                Section {
                    Button {
                        showMemories = true
                    } label: {
                        LabeledContent("记忆", value: "\(heldMemoryCount) 条")
                    }
                } header: {
                    Text("记忆")
                } footer: {
                    Text("回合结束后在后台提炼，所有偶像共享。被新记忆取代的旧记忆仍会列出，但不再被想起。")
                }

                Section {
                    Toggle("记录回合追踪", isOn: $tracingEnabled)
                    Stepper("保留最近 \(traceRetention) 条", value: $traceRetention, in: 20...2000, step: 20)
                        .disabled(!tracingEnabled)
                    Button {
                        showTraces = true
                    } label: {
                        LabeledContent("查看与导出", value: tracingEnabled ? "⇢" : "追踪已关闭")
                    }
                } header: {
                    Text("诊断")
                } footer: {
                    Text("每回合记录提示词、判断原始输出、检索候选与分数和降级原因，只存在这台手机上；关闭后不再写入。")
                }

                Section {
                    Button {
                        showStandPreview = true
                    } label: {
                        LabeledContent("立绘预览", value: "⇢")
                    }
                } header: {
                    Text("立绘")
                } footer: {
                    Text("用立绘包里她的默认衣装看一段待机动作。没有同步 Spine 运行时、页面失败或素材缺失时显示「没有立绘」。")
                }

                standBundleSection

                barBundleSection

                Section("内容包") {
                    if let info = app.bundleInfo {
                        LabeledContent("剧情", value: "\(info.episodeCount)")
                        LabeledContent("段落", value: "\(info.passageCount)")
                        LabeledContent("角色", value: "\(info.characterCount)")
                        if info.standOutfitCount > 0 {
                            LabeledContent("内容包内立绘（旧包）", value: "\(info.standOutfitCount) 套")
                        }
                        LabeledContent("向量模型", value: info.embeddingModel)
                        LabeledContent("向量维度", value: "\(info.embeddingDimensions)")
                        LabeledContent("内容 schema", value: "\(info.contentSchemaVersion)")
                        LabeledContent("安装时间", value: info.installedAt)
                    } else {
                        Text("还没有导入内容包")
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button("重新导入内容包") {
                        importKind = .content
                        isPicking = true
                    }
                    .disabled(app.isImporting)
                } footer: {
                    Text("内容包只带剧情，不含立绘；立绘在立绘包里单独导入。导入失败时保留当前内容包；对话、记忆和好感度不受影响。")
                }
            }
            .navigationTitle("设置")
            .navigationDestination(isPresented: $showMemories) {
                MemoryListView()
            }
            .navigationDestination(isPresented: $showTraces) {
                TraceListView()
            }
            .navigationDestination(isPresented: $showStandPreview) {
                StandPreviewView()
            }
            .task { await app.loadMemories() }
            .onAppear {
                #if DEBUG
                if let destinations = app.consumeDebugSettingsDestinations() {
                    if destinations.memories { showMemories = true }
                    if destinations.traces { showTraces = true }
                    if destinations.standPreview { showStandPreview = true }
                }
                #endif
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") { Task { await save() } }
                        .fontWeight(.semibold)
                }
            }
            .task { await load() }
            .overlay {
                if app.isImporting {
                    VStack(spacing: 10) {
                        if let progress = app.importProgress {
                            ProgressView(value: progress.fraction) {
                                Text(progress.phase == .extracting ? "正在解压…" : "正在校验…")
                                    .font(.callout)
                            }
                            .progressViewStyle(.linear)
                            .frame(maxWidth: 260)
                            Text("\(progress.completed) / \(progress.total)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        } else {
                            ProgressView("正在导入…")
                        }
                        Text("导入期间请保持 App 在前台")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
            .alert("保存失败", isPresented: saveErrorBinding) {
                Button("好") { saveError = nil }
            } message: {
                Text(saveError ?? "")
            }
            .alert("导入失败", isPresented: importErrorBinding) {
                Button("好") { app.errorMessage = nil }
            } message: {
                Text(app.errorMessage ?? "")
            }
            .alert("已保存", isPresented: $savedNotice) {
                Button("好") {}
            }
            .confirmationDialog(
                "清理 Documents 里的内容包？",
                isPresented: $confirmingPackageCleanup
            ) {
                Button("清理", role: .destructive) {
                    _ = app.removeDocumentPackages()
                }
            } message: {
                Text("只删除 Documents 里的 .eidolonpkg 文件；已安装的内容和立绘不受影响。")
            }
            .alert("判断模型可用", isPresented: judgeCheckBinding) {
                Button("好") { judgeCheck = nil }
            } message: {
                Text(judgeCheck.map(judgeCheckSummary) ?? "")
            }
            .alert("判断模型不可用", isPresented: judgeCheckErrorBinding) {
                Button("好") { judgeCheckError = nil }
            } message: {
                Text(judgeCheckError ?? "")
            }
            .fileImporter(
                isPresented: $isPicking,
                allowedContentTypes: [.eidolonPackage, .data],
                allowsMultipleSelection: false
            ) { result in
                guard case .success(let urls) = result, let url = urls.first else { return }
                Task {
                    switch importKind {
                    case .content:
                        await app.importBundle(from: url)
                    case .stand:
                        await app.importStandBundle(from: url)
                    case .bar:
                        await app.importBarBundle(from: url)
                    }
                }
            }
        }
    }

    private func exportStandIndex() async {
        guard let data = await app.standIndexData() else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stand-index.json")
        do {
            try data.write(to: url, options: .atomic)
            standIndexURL = url
        } catch {
            app.errorMessage = error.localizedDescription
        }
    }

    private var heldMemoryCount: Int {
        app.memories.filter(\.holds).count
    }

    @ViewBuilder
    private var standBundleSection: some View {
        Section {
            if let info = app.standInfo {
                LabeledContent("角色", value: "\(info.characterCount)")
                LabeledContent("衣装", value: "\(info.outfitCount) 套")
                LabeledContent("格式", value: "v\(info.formatVersion)")
                LabeledContent("安装时间", value: info.installedAt)
            } else {
                Text("还没有导入立绘包")
                    .foregroundStyle(.secondary)
            }
            Button(app.standInfo == nil ? "导入立绘包" : "重新导入立绘包") {
                importKind = .stand
                isPicking = true
            }
            .disabled(app.isImporting)
            if app.standInfo != nil {
                Button("导出立绘清单") {
                    Task { await exportStandIndex() }
                }
                if let standIndexURL {
                    ShareLink(item: standIndexURL) {
                        Label("分享立绘清单", systemImage: "square.and.arrow.up")
                    }
                }
                Button("清理 Documents 里的内容包", role: .destructive) {
                    confirmingPackageCleanup = true
                }
            }
        } header: {
            Text("立绘包")
        } footer: {
            Text("立绘包和内容包分开导入；第一次导入全量包，之后可以追加增量包。导入失败保留上一份。")
        }
    }

    /// The bar's own package: its pictures, the pixel font and the sound. Without it the
    /// bar asks for one instead of drawing a broken room (ADR-0021).
    private var barBundleSection: some View {
        Section {
            if let info = app.barInfo {
                LabeledContent("画面", value: "\(info.imageCount) 张")
                LabeledContent("字体", value: "\(info.fontCount) 份")
                LabeledContent(
                    "音乐",
                    value: info.hasAudio ? "\(info.trackCount) 首，音效 \(info.sfxCount) 个" : "没有"
                )
                LabeledContent("格式", value: "v\(info.formatVersion)")
                LabeledContent("安装时间", value: info.installedAt)
            } else {
                Text("还没有导入酒吧素材包")
                    .foregroundStyle(.secondary)
            }
            Button(app.barInfo == nil ? "导入酒吧素材包" : "重新导入酒吧素材包") {
                importKind = .bar
                isPicking = true
            }
            .disabled(app.isImporting)
        } header: {
            Text("酒吧素材包")
        } footer: {
            Text(barBundleFooter)
        }
    }

    private var barBundleFooter: String {
        if let barInfo = app.barInfo, !barInfo.hasAudio {
            return "这个包没有音乐，点唱机会显示为灰色；补上音频后重新导出即可。"
        }
        return "酒吧的画面、像素字体和音乐单独打包，和内容包、立绘包分开导入。导入失败保留上一份。"
    }

    private func load() async {
        let settings = app.chatSettings
        baseURL = settings.baseURL
        model = settings.model
        apiKey = settings.apiKey
        historyTurns = settings.historyTurns
        extraBody = settings.extraBody
        judgeBaseURL = settings.judgeBaseURL
        judgeModel = settings.judgeModel
        judgeAPIKey = settings.judgeAPIKey
        judgeExtraBody = settings.judgeExtraBody
        judgeService = settings.judgeService
        bailianWorkspace = settings.bailianWorkspace
        bailianRegion = settings.bailianRegion
        bailianModel = settings.bailianModel
        bailianAPIKey = settings.bailianAPIKey
        jevBaseURL = settings.jevBaseURL
        jevModel = settings.jevModel
        jevAPIKey = settings.jevAPIKey
        cloudflareAccountID = settings.cloudflareAccountID
        cloudflareModel = settings.cloudflareModel
        cloudflareAPIKey = settings.cloudflareAPIKey
        emotionMinProbability = settings.emotionMinProbability.map(Self.numberText) ?? ""
        emotionTimeout = Self.numberText(settings.emotionTimeout)
        retrievalBaseURL = settings.retrievalBaseURL
        embeddingModel = settings.embeddingModel
        rerankModel = settings.rerankModel
        retrievalAPIKey = settings.retrievalAPIKey
        sonioxAPIKey = settings.sonioxAPIKey
        sonioxModel = settings.sonioxModel
        fishAPIKey = settings.fishAPIKey
        fishModel = settings.fishModel
        callMinutes = settings.callMinutes
        callTurns = settings.callTurns
        reachOutHours = settings.reachOutHours
        tracingEnabled = settings.tracingEnabled
        traceRetention = settings.traceRetention
        if let profile = try? await app.core.producerProfile() {
            formOfAddress = profile.formOfAddress ?? ""
            gender = profile.gender?.rawValue ?? "default"
            profileTimezone = profile.timezone ?? ""
            birthdayOn = profile.birthdayMonth != nil && profile.birthdayDay != nil
            birthdayMonth = profile.birthdayMonth ?? 1
            birthdayDay = profile.birthdayDay ?? 1
        }
    }

    /// The settings as they are on screen: what saving writes, and what the trial request
    /// is made with, so the test asks exactly what will be used.
    private var draft: ChatSettings {
        ChatSettings(
            baseURL: baseURL,
            model: model,
            apiKey: apiKey,
            historyTurns: historyTurns,
            extraBody: extraBody,
            judgeBaseURL: judgeBaseURL,
            judgeModel: judgeModel,
            judgeAPIKey: judgeAPIKey,
            judgeExtraBody: judgeExtraBody,
            retrievalBaseURL: retrievalBaseURL,
            embeddingModel: embeddingModel,
            rerankModel: rerankModel,
            retrievalAPIKey: retrievalAPIKey,
            reachOutHours: reachOutHours,
            tracingEnabled: tracingEnabled,
            traceRetention: traceRetention,
            sonioxAPIKey: sonioxAPIKey,
            sonioxModel: sonioxModel,
            fishAPIKey: fishAPIKey,
            fishModel: fishModel,
            callMinutes: callMinutes,
            callTurns: callTurns,
            judgeService: judgeService,
            bailianWorkspace: bailianWorkspace,
            bailianRegion: bailianRegion,
            bailianModel: bailianModel,
            bailianAPIKey: bailianAPIKey,
            jevBaseURL: jevBaseURL,
            jevModel: jevModel,
            jevAPIKey: jevAPIKey,
            cloudflareAccountID: cloudflareAccountID,
            cloudflareModel: cloudflareModel,
            cloudflareAPIKey: cloudflareAPIKey,
            emotionMinProbability: Self.number(emotionMinProbability),
            emotionTimeout: Self.number(emotionTimeout) ?? 1.5
        )
    }

    private func save() async {
        let settings = draft
        if judgeService != .chat {
            let probability = emotionMinProbability.trimmingCharacters(in: .whitespacesAndNewlines)
            if !probability.isEmpty,
               !(Self.number(probability).map { (0...1).contains($0) } ?? false) {
                saveError = "最低概率需要是 0 到 1 之间的数"
                return
            }
            let timeout = emotionTimeout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !timeout.isEmpty,
               !(Self.number(timeout).map { SystemOneSegmentEmotionJudge.timeoutRange.contains($0) } ?? false) {
                saveError = "超时需要是 0.1 到 10 之间的数（秒）"
                return
            }
        }
        do {
            try app.saveChatSettings(settings)
            let zone = profileTimezone.trimmingCharacters(in: .whitespacesAndNewlines)
            if !zone.isEmpty, TimeZone(identifier: zone) == nil {
                saveError = "时区无法识别：\(zone)"
                return
            }
            let address = formOfAddress.trimmingCharacters(in: .whitespacesAndNewlines)
            try await app.saveProducerProfile(
                ProducerProfile(
                    formOfAddress: address.isEmpty ? nil : address,
                    gender: gender == "male" ? .male : gender == "female" ? .female : nil,
                    timezone: zone.isEmpty ? nil : zone,
                    birthdayMonth: birthdayOn ? birthdayMonth : nil,
                    birthdayDay: birthdayOn ? birthdayDay : nil
                )
            )
            savedNotice = true
        } catch {
            saveError = error.localizedDescription
        }
    }

    /// Asks the chosen service one yes-or-no question with the fields as they are now, and
    /// says what answered — or which part of the configuration the service refused.
    private func testJudge() async {
        guard let provider = app.judgeProvider(for: draft) else {
            judgeCheckError = "这个服务还没填完：地址（或账号）、模型名和密钥都要有。"
            return
        }
        isTestingJudge = true
        defer { isTestingJudge = false }
        do {
            judgeCheck = try await provider.checkJudge()
        } catch {
            judgeCheckError = error.localizedDescription
        }
    }

    private func judgeCheckSummary(_ check: JudgeCheck) -> String {
        var lines = ["服务：\(check.service)", "模型：\(check.model)"]
        if let family = check.family {
            lines.append("阈值：\(family.rawValue)")
        }
        if check.uncalibrated {
            lines.append(JudgeCalibration.uncalibratedNote)
        }
        if let tokens = check.inputTokens {
            lines.append("输入 tokens：\(tokens)")
        }
        return lines.joined(separator: "\n")
    }

    /// The note when the chosen service's model has no calibration of its own; nil
    /// otherwise, the chat judge included — it reads no thresholds at all.
    private var judgeUncalibratedNote: String? {
        let model: String
        switch judgeService {
        case .bailian: model = bailianModel
        case .jev: model = jevModel
        case .cloudflare: model = cloudflareModel
        case .chat: return nil
        }
        let name = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, JudgeFamilies.family(of: name) == nil else { return nil }
        return JudgeCalibration.uncalibratedNote
    }

    private var judgeCheckBinding: Binding<Bool> {
        Binding(
            get: { judgeCheck != nil },
            set: { if !$0 { judgeCheck = nil } }
        )
    }

    private var judgeCheckErrorBinding: Binding<Bool> {
        Binding(
            get: { judgeCheckError != nil },
            set: { if !$0 { judgeCheckError = nil } }
        )
    }

    private var saveErrorBinding: Binding<Bool> {
        Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )
    }

    private var importErrorBinding: Binding<Bool> {
        Binding(
            get: { app.errorMessage != nil },
            set: { if !$0 { app.errorMessage = nil } }
        )
    }

    /// A numeric field's text as a number; blank is nil, and so is anything unreadable.
    private static func number(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return Double(trimmed)
    }

    /// A number as its field shows it: `1.5`, `0.4`, `1`, never `1.500000`.
    private static func numberText(_ value: Double) -> String {
        String(
            format: "%g",
            locale: Locale(identifier: "en_US_POSIX"),
            arguments: [value]
        )
    }
}
