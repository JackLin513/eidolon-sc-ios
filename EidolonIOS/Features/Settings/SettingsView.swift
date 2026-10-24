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
    @State private var retrievalBaseURL = ""
    @State private var embeddingModel = ""
    @State private var rerankModel = ""
    @State private var retrievalAPIKey = ""
    @State private var sonioxAPIKey = ""
    @State private var sonioxModel = "stt-rt-v5"
    @State private var fishAPIKey = ""
    @State private var fishModel = "s2.1-pro-free"
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
    @State private var showMemories = false
    @State private var showTraces = false

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
                } header: {
                    Text("判断模型")
                } footer: {
                    Text("每回合判断这句话对好感度的影响。留空则使用对话模型；都不可用时不做判断，好感度不变。")
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
                } header: {
                    Text("通话")
                } footer: {
                    Text("Soniox 负责实时识别你说的话，Fish Audio 负责她的声音。密钥保存在钥匙串。")
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
                        LabeledContent("记忆", value: "\(app.memories.filter(\.holds).count) 条")
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

                Section("内容包") {
                    if let info = app.bundleInfo {
                        LabeledContent("剧情", value: "\(info.episodeCount)")
                        LabeledContent("段落", value: "\(info.passageCount)")
                        LabeledContent("角色", value: "\(info.characterCount)")
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
                        isPicking = true
                    }
                    .disabled(app.isImporting)
                } footer: {
                    Text("导入失败时保留当前内容包；对话、记忆和好感度不受影响。")
                }
            }
            .navigationTitle("设置")
            .navigationDestination(isPresented: $showMemories) {
                MemoryListView()
            }
            .navigationDestination(isPresented: $showTraces) {
                TraceListView()
            }
            .task { await app.loadMemories() }
            .onAppear {
                #if DEBUG
                if app.debugShowsMemories { showMemories = true }
                if app.debugShowsTraces { showTraces = true }
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
                    ProgressView("正在导入…")
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
            .fileImporter(
                isPresented: $isPicking,
                allowedContentTypes: [.eidolonPackage, .data],
                allowsMultipleSelection: false
            ) { result in
                guard case .success(let urls) = result, let url = urls.first else { return }
                Task { await app.importBundle(from: url) }
            }
        }
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
        retrievalBaseURL = settings.retrievalBaseURL
        embeddingModel = settings.embeddingModel
        rerankModel = settings.rerankModel
        retrievalAPIKey = settings.retrievalAPIKey
        sonioxAPIKey = settings.sonioxAPIKey
        sonioxModel = settings.sonioxModel
        fishAPIKey = settings.fishAPIKey
        fishModel = settings.fishModel
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

    private func save() async {
        let settings = ChatSettings(
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
            fishModel: fishModel
        )
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
}
