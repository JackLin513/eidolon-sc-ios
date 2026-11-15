import EidolonCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.isEidolonPadShell) private var isPadShell
    @Environment(\.isEidolonSystemSidebarShell) private var isSystemSidebarShell
    @Environment(\.isEidolonForceCompactContent) private var forceCompactContent
    @State private var selectedCategory: SettingsCategory? = .server

    private var isRegularWidth: Bool { sizeClass == .regular }

    /// A content package can describe the user as someone other than an SC producer.
    /// Hide the producer-only profile and calendar fields in that case; the rest of
    /// the category (cycles, reach-out) belongs to the character, not the producer role.
    private var showsProducerProfile: Bool {
        (app.bundleInfo?.franchise ?? "shiny") == "shiny"
    }

    @State private var historyTurns = 20
    @State private var atmosphericText = true
    @State private var adultMode = false
    @State private var callMinutes = 10
    @State private var callTurns = 40
    @State private var phoneTexture = false
    @State private var saveError: String?
    @State private var savedNotice = false
    @State private var reachOutHours = 6
    @State private var reachOutByTier = true
    @State private var formOfAddress = ""
    @State private var gender = "default"
    @State private var profileTimezone = ""
    @State private var birthdayOn = false
    @State private var birthdayDate = SettingsView.date(
        year: 2024, month: 1, day: 1, timeZone: .current
    )
    @State private var birthdayError: String?
    @State private var tracingEnabled = true
    @State private var traceRetention = 200
    @State private var isPicking = false
    @State private var importKind: ImportKind = .content
    @State private var showMemories = false
    @State private var showTraces = false
    @State private var showStandPreview = false
    @State private var showStaticStandPreview = false
    #if DEBUG
    @State private var showStoryTheater = false
    #endif
    @State private var standIndexURL: URL?
    @State private var confirmingPackageCleanup = false
    @State private var packageToDelete: String?
    @State private var confirmingCalendarDelete = false

    /// 「账号」那一行右边写什么：没登录就说没登录。
    private var accountValue: String {
        guard let session = app.server.session else { return "未登录" }
        return session.isAdmin ? "\(session.username)（管理员）" : session.username
    }

    /// 服务器不是 App 的前提：这一行在没登录时也要说清楚。
    private var downloadedFooter: String {
        app.server.isSignedIn
            ? "内容包、公告和管理都在这里。"
            : "登录以后可以下载内容包、看公告。不登录、没有网，对话和别的功能照旧能用。"
    }

    private enum ImportKind {
        case content
        case stand
        case bar
    }


    var body: some View {
        VStack(spacing: 0) {
            if isPadShell {
                HStack(spacing: 0) {
                    padSettingsSidebar
                        .frame(width: ResponsiveLayout.settingsSidebarWidth)
                    PadBoundaryLine()
                    settingsStack(category: selectedCategory)
                }
            } else if isSystemSidebarShell || forceCompactContent {
                // The system tab sidebar already owns first-level navigation on Duo;
                // a second split would make three columns. Use the phone list -> detail
                // flow inside the tab.
                phoneSettings
            } else if isRegularWidth {
                NavigationSplitView {
                    settingsSidebar
                } detail: {
                    settingsStack(category: selectedCategory)
                }
                .navigationSplitViewStyle(.balanced)
            } else {
                phoneSettings
            }
        }
    }

    /// The compact phone is a category list that drills into one detail form. The iPad
    /// keeps its sidebar; both render the same `settingsForm`.
    private var phoneSettings: some View {
        NavigationStack {
            List {
                ForEach(SettingsCategory.groups, id: \.title) { group in
                    Section(group.title) {
                        ForEach(group.categories) { category in
                            NavigationLink {
                                phoneSettingsDetail(category)
                            } label: {
                                Label(category.title(for: app.bundleInfo?.franchise), systemImage: category.symbol)
                            }
                            .accessibilityIdentifier("settings.category.\(category.rawValue)")
                        }
                    }
                }
            }
            .navigationTitle("设置")
        }
        .task { await load() }
    }

    private func phoneSettingsDetail(_ category: SettingsCategory) -> some View {
        settingsForm(category: category)
            .navigationTitle(category.title(for: app.bundleInfo?.franchise))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") { Task { await save() } }
                        .fontWeight(.semibold)
                }
            }
            .navigationDestination(isPresented: $showMemories) {
                MemoryListView()
            }
            .navigationDestination(isPresented: $showTraces) {
                TraceListView()
            }
            .navigationDestination(isPresented: $showStandPreview) {
                StandPreviewView()
            }
            .navigationDestination(isPresented: $showStaticStandPreview) {
                StaticStandPreviewView()
            }
            #if DEBUG
            .navigationDestination(isPresented: $showStoryTheater) {
                StoryTheaterView()
            }
            #endif
            .onAppear {
                #if DEBUG
                if let destinations = app.consumeDebugSettingsDestinations() {
                    if destinations.memories { showMemories = true }
                    if destinations.traces { showTraces = true }
                    if destinations.standPreview { showStandPreview = true }
                }
                #endif
            }
    }

    /// One category on the iPad; nil means the phone's full form.
    private func settingsForm(category: SettingsCategory?) -> some View {
        Form {

                    // 登录以后是账号，没登录时点进去就是登录页（spec #120）。放最上面，
                    // 不然它和「服务器」一样要找半天。
                    if visible(category, .server) {
Section {
                        NavigationLink {
                            AccountView()
                        } label: {
                            LabeledContent("账号", value: accountValue)
                        }
                        .accessibilityIdentifier("settings.account")
                    } header: {
                        Text("服务器")
                    } footer: {
                        Text(downloadedFooter)
                    }
                    }

                    if visible(category, .server) {
Section {
                        Button("重新观看欢迎页") { app.replayWelcome() }
                            .accessibilityIdentifier("settings.welcome")
                    }
                    }

                    if visible(category, .api) {
Section {
                        NavigationLink {
                            APISettingsView()
                        } label: {
                            LabeledContent("API 与模型", value: apiSummary)
                        }
                        .accessibilityIdentifier("settings.api")
                    } header: {
                        Text("外部服务")
                    } footer: {
                        Text("对话、后台、判断、检索和通话的地址、模型与密钥都在这里。")
                    }
                    }

                    if visible(category, .moments) {
Section {
                        NavigationLink {
                            MomentsSettingsView()
                        } label: {
                            LabeledContent(
                                "朋友圈", value: app.momentsSettings.enabled ? "已开启" : "未开启"
                            )
                        }
                        .accessibilityIdentifier("settings.moments")
                    } header: {
                        Text("朋友圈")
                    }
                    }

                    if visible(category, .stats) {
Section {
                        NavigationLink {
                            StatsView()
                        } label: {
                            LabeledContent("统计", value: "⇢")
                        }
                        .accessibilityIdentifier("settings.stats")
                        NavigationLink {
                            UsageView()
                        } label: {
                            LabeledContent("用量与花费", value: "⇢")
                        }
                        .accessibilityIdentifier("settings.usage")
                    } header: {
                        Text("统计")
                    } footer: {
                        Text("统计是和她往来多少；用量与花费是每次外部调用用了多少、按现价大概花了多少。两者都不离开这台手机。")
                    }
                    }

                    if visible(category, .conversation) {
Section {
                        Stepper("历史回合：\(historyTurns)", value: $historyTurns, in: 1...100)
                        SettingsHint("每次带上最近多少条对话；越多越记得久，也更花 token。")
                        Toggle("文字氛围模式", isOn: $atmosphericText)
                            .accessibilityIdentifier("settings.atmosphericText")
                    } header: {
                        Text("对话")
                    } footer: {
                        Text("文字氛围模式让文字回合的台词更长、并显示动作与环境描写；通话和搭话不受影响。")
                    }
                    }

                    if visible(category, .conversation) {
Section {
                        Toggle("成人模式", isOn: $adultMode)
                            .accessibilityIdentifier("settings.adultMode")
                    } header: {
                        Text("成人模式")
                    } footer: {
                        Text("只对内容包中 18 岁及以上的角色生效，未成年角色不受影响。开启后，双方愿意的亲密内容不会被判越界，也不会因此结束对话；真正的骚扰、威胁、辱骂仍然会结束对话。")
                    }
                    }

                    if visible(category, .conversation) {
Section {
                        TextField("时长上限（分钟，0 为不限）", value: $callMinutes, format: .number)
                            .keyboardType(.numberPad)
                        SettingsHint("一通电话最长多少分钟；0 = 不限制。")
                        TextField("回合上限（她的回合数，0 为不限）", value: $callTurns, format: .number)
                            .keyboardType(.numberPad)
                        SettingsHint("她在一通电话里最多说多少回合；0 = 不限制。")
                        Toggle("电话质感", isOn: $phoneTexture)
                    } header: {
                        Text("通话行为")
                    } footer: {
                        Text("默认每通电话最多 10 分钟、她最多 40 个回合，从接通起算；时长与回合都到点时先按时长算。"
                            + "电话质感让角色的声音像隔着电话听筒，改完从下一通电话开始生效。Soniox 与 Fish Audio 的密钥在「API 与模型」。")
                    }
                    }


                    if showsProducerProfile, visible(category, .producer) {
Section {
                        TextField("称呼（留空沿用默认）", text: $formOfAddress)
                        SettingsHint("她叫你什么；留空用内容包里的默认称呼。")
                        Picker("性别", selection: $gender) {
                            Text("沿用默认").tag("default")
                            Text("男性").tag("male")
                            Text("女性").tag("female")
                        }
                        TextField("时区（例如 Asia/Shanghai，留空跟随设备）", text: $profileTimezone)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SettingsHint("制作人的时区，影响日程和搭话时间；留空跟随这台手机。")
                        Toggle("设置生日", isOn: $birthdayOn)
                            .accessibilityIdentifier("settings.birthdayOn")
                        if birthdayOn {
                            DatePicker(
                                "生日",
                                selection: $birthdayDate,
                                in: birthdayRange,
                                displayedComponents: .date
                            )
                            .environment(\.timeZone, birthdayTimeZone)
                            .accessibilityIdentifier("settings.birthday")
                            if let birthdayError {
                                Text(birthdayError)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                        }
                    } header: {
                        Text("制作人档案")
                    } footer: {
                        Text("只影响她当下怎么对待你，不改写剧情。生日只在当天被她主动提起。年份会保存，但提示词和日历只用到月日。")
                    }
                    }

                    if showsProducerProfile, visible(category, .producer) {
Section {
                        Toggle("导出到系统日历", isOn: Binding(
                            get: { app.calendarExport.enabled },
                            set: { on in Task { await app.setCalendarExportEnabled(on) } }
                        ))
                        .accessibilityIdentifier("settings.calendarExport")
                        Button {
                            Task { await app.syncCalendarExport() }
                        } label: {
                            HStack {
                                Text("立即同步")
                                if app.calendarExport.syncing {
                                    Spacer(minLength: 0)
                                    ProgressView()
                                }
                            }
                        }
                        .disabled(app.calendarExport.syncing || !app.calendarExport.enabled)
                        .accessibilityIdentifier("settings.calendarExport.sync")
                        if let last = app.calendarExport.lastSyncedAt {
                            Text("上次同步：\(last.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let error = app.calendarExport.lastError {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                            if app.calendarExport.authorizationDenied {
                                Button("去系统设置") {
                                    if let url = URL(string: UIApplication.openSettingsURLString) {
                                        UIApplication.shared.open(url)
                                    }
                                }
                            }
                        }
                        Button("删除 Eidolon 日历事件", role: .destructive) {
                            confirmingCalendarDelete = true
                        }
                        .disabled(app.calendarExport.deleting || app.calendarExport.syncing)
                        .accessibilityIdentifier("settings.calendarExport.delete")
                        .anchoredConfirmation(
                            "删除 Eidolon 日历事件？",
                            message: "只删除带 Eidolon 标记的事件；你自己的日历事件不会被删。",
                            isPresented: $confirmingCalendarDelete,
                            onConfirm: { Task { await app.deleteCalendarExportEvents() } }
                        )
                    } header: {
                        Text("系统日历")
                    } footer: {
                        Text("打开后把她的生日、你的生日和所有已保存的排班写进单独的「Eidolon」日历。同步是单向的：只写不读，不碰你自己的事件；手动改过或删掉的导出事件下次同步会恢复。关掉开关只停止同步，保留已写入的事件。")
                    }
                    }

                    if visible(category, .producer) {
Section {
                        Toggle("周期", isOn: Binding(
                            get: { app.cyclesEnabled },
                            set: { on in Task { await app.setCyclesEnabled(on) } }
                        ))
                    } header: {
                        Text("她的周期")
                    } footer: {
                        Text("关掉后，她的提示词不再带经期和经期前的状态；周期本身照常推进，重新打开还是原来的位置。")
                    }
                    }

                    if visible(category, .producer) {
Section {
                        Toggle("按好感度随机", isOn: $reachOutByTier)
                        Stepper("搭话间隔：\(reachOutHours) 小时", value: $reachOutHours, in: 1...72)
                            .disabled(reachOutByTier)
                        SettingsHint("固定间隔：超过这么多小时没说话，她可能先开口；开启随机时按好感度档位抽。")
                    } header: {
                        Text("搭话")
                    } footer: {
                        Text(
                            "超过这么久没说话，她会在打开 App 时先给你发一条。同一次沉默只发一次。\n"
                                + "开启随机时按好感度档位抽时间：亲密 3–6 小时，亲近 8–16 小时，信任 20–36 小时；"
                                + "冷淡和疏远不搭话。每天最多三次。关闭后一律用上面的固定间隔。"
                        )
                    }
                    }

                    if visible(category, .memories) {
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
                    }

                    if visible(category, .diagnostics) {
Section {
                        Toggle("记录回合追踪", isOn: $tracingEnabled)
                        Stepper("保留最近 \(traceRetention) 条", value: $traceRetention, in: 20...2000, step: 20)
                            .disabled(!tracingEnabled)
                        Button {
                            showTraces = true
                        } label: {
                            LabeledContent("查看与导出", value: tracingEnabled ? "⇢" : "追踪已关闭")
                        }
                        if let failure = app.lastRuntimeFailure {
                            LabeledContent("最近立绘回退", value: failure.description)
                        }
                    } header: {
                        Text("诊断")
                    } footer: {
                        Text("每回合记录提示词、判断原始输出、检索候选与分数和降级原因，只存在这台手机上；关闭后不再写入。")
                    }
                    }

                    if visible(category, .look) {
Section {
                        Picker(
                            "立绘风格",
                            selection: Binding(
                                get: { app.runtimePreference },
                                set: { app.setRuntimePreference($0) }
                            )
                        ) {
                            ForEach(RuntimePreference.allCases) { preference in
                                Text(preference.title)
                                    .tag(preference)
                                    .disabled(preference == .unity && !app.is3DAvailable)
                            }
                        }
                        Button {
                            showStandPreview = true
                        } label: {
                            LabeledContent("立绘预览", value: "⇢")
                        }
                        if app.staticStandInfo != nil {
                            Button {
                                showStaticStandPreview = true
                            } label: {
                                LabeledContent("静态立绘预览", value: "⇢")
                            }
                            .accessibilityIdentifier("settings.staticStandPreview")
                        }
                        #if DEBUG
                        if StoryTheaterView.hasBundledStories {
                            Button {
                                showStoryTheater = true
                            } label: {
                                LabeledContent("剧情剧场（MLTD 3D 立绘）", value: "⇢")
                            }
                            .accessibilityIdentifier("settings.storyTheater")
                        }
                        #endif
                    } header: {
                        Text("立绘")
                    } footer: {
                        Text("自动会优先用这个构建里可用的 3D；没有 Unity 产物或 3D 内容时回退到 2D。3D 需要 3D 包与 Unity 构建。用立绘包里她的默认衣装看一段待机动作。")
                    }
                    }

                    if visible(category, .look) {
standBundleSection
                    }

                    if visible(category, .look) {
barBundleSection
                    }

                    if visible(category, .content) {
Section("内容包") {
                        if !app.contentPackages.isEmpty {
                            ForEach(app.contentPackages, id: \.franchise) { package in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(package.franchise)
                                        Text("\(package.kind) · v\(package.info.formatVersion) · \(package.info.characterCount) 位角色 · \(package.info.episodeCount) 段剧情")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if package.franchise == app.bundleInfo?.franchise {
                                        Text("当前")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.tint)
                                    } else {
                                        Button("切换") {
                                            Task { await app.activateContentPackage(franchise: package.franchise) }
                                        }
                                        .buttonStyle(.borderless)
                                        .accessibilityIdentifier("settings.content.switch.\(package.franchise)")
                                    }
                                    Button("删除", role: .destructive) {
                                        packageToDelete = package.franchise
                                    }
                                    .buttonStyle(.borderless)
                                    .accessibilityIdentifier("settings.content.delete.\(package.franchise)")
                                    .anchoredConfirmation(
                                        "删除内容包？",
                                        message: "会删除 \(package.franchise) 的内容和该企划的立绘/3D 包；对话、记忆和好感度保留，重新导入后恢复。",
                                        isPresented: Binding(
                                            get: { packageToDelete == package.franchise },
                                            set: { shown in
                                                if !shown, packageToDelete == package.franchise {
                                                    packageToDelete = nil
                                                }
                                            }
                                        ),
                                        onConfirm: {
                                            let target = package.franchise
                                            packageToDelete = nil
                                            Task { await app.deleteContentPackage(franchise: target) }
                                        }
                                    )
                                }
                            }
                            Divider()
                        }
                        if let info = app.bundleInfo {
                            LabeledContent("剧情", value: "\(info.episodeCount)")
                            LabeledContent("段落", value: "\(info.passageCount)")
                            LabeledContent("角色", value: "\(info.characterCount)")
                            if info.placeCount > 0 {
                                LabeledContent("地点", value: "\(info.placeCount)")
                            }
                            if info.standOutfitCount > 0 {
                                LabeledContent("内容包内立绘（旧包）", value: "\(info.standOutfitCount) 套")
                            }
                            LabeledContent("向量模型", value: info.embeddingModel)
                            LabeledContent("向量维度", value: "\(info.embeddingDimensions)")
                            LabeledContent("内容 schema", value: "\(info.contentSchemaVersion)")
                            LabeledContent("内容族", value: info.contentSetID ?? "legacy（未绑定）")
                            if let staticStand = app.staticStandInfo {
                                LabeledContent("静态立绘", value: staticStand.contentSetID ?? "未绑定")
                            } else {
                                LabeledContent("静态立绘", value: "未安装")
                            }
                            LabeledContent("安装时间", value: info.installedAt)
                            NavigationLink("剧情目录") { StoryCatalogView() }
                                .accessibilityIdentifier("settings.storyCatalog")
                            NavigationLink("用语集") { TermCatalogView() }
                                .accessibilityIdentifier("settings.terms")
                        } else {
                            Text("还没有导入内容包")
                                .foregroundStyle(.secondary)
                        }
                    }
                    }

                    if visible(category, .content) {
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

                    if visible(category, .diagnostics) {
Section {
                        Toggle("调试模式", isOn: Binding(
                            get: { app.debugMode },
                            set: { app.setDebugMode($0) }
                        ))
                        .accessibilityIdentifier("settings.debugMode")
                    } header: {
                        Text("调试")
                    } footer: {
                        Text("开启后，角色对话页的「⋯」菜单会出现「调试」：可以删除这段对话的记忆、修改好感度、恢复已结束的对话或把历史对话设为当前。改动立即写入本机数据，不能撤销；平时请保持关闭。")
                    }
                    }
                
        }
        .background(Color(.systemGroupedBackground))
    }
    private func settingsStack(category: SettingsCategory?) -> some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                if isPadShell {
                    PadPageLargeTitle(category?.title ?? "设置", id: "pad.title.settings.detail") {
                        Button {
                            Task { await save() }
                        } label: {
                            Text("保存")
                                .fontWeight(.semibold)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .glassEffect(.regular.interactive(), in: .capsule)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("settings.save")
                    }
                }
                settingsForm(category: category)
                    .frame(maxWidth: .infinity)
            }
            .background(Color(.systemGroupedBackground))

                // Returning to the call brings the layer over every page; settings gets out of
                // its way (spec #46).
                .navigationTitle(category?.title ?? "设置")
                .toolbar(isPadShell ? .hidden : .visible, for: .navigationBar)
                .navigationDestination(isPresented: $showMemories) {
                    MemoryListView()
                }
                .navigationDestination(isPresented: $showTraces) {
                    TraceListView()
                }
                .navigationDestination(isPresented: $showStandPreview) {
                    StandPreviewView()
                }
                .navigationDestination(isPresented: $showStaticStandPreview) {
                    StaticStandPreviewView()
                }
                #if DEBUG
                .navigationDestination(isPresented: $showStoryTheater) {
                    StoryTheaterView()
                }
                #endif
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
                    if !isPadShell {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("保存") { Task { await save() } }
                                .fontWeight(.semibold)
                        }
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
    private var settingsSidebar: some View {
        List(selection: $selectedCategory) {
            ForEach(SettingsCategory.groups, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.categories) { categoryRow($0) }
                }
            }
        }
        .navigationTitle("设置")
    }

    /// The S2.1 shell already has its own rail; this is settings' own category column,
    /// without a second system sidebar toggle or a navigation title floating over it.
    private var padSettingsSidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text("设置")
                    .font(.title2.weight(.semibold))
                    .accessibilityIdentifier("pad.title.settings")
                Spacer()
            }
            .padding(.horizontal, ResponsiveLayout.pageTitleLeading)
            .padding(.top, ResponsiveLayout.pageTitleTop)
            .padding(.bottom, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(SettingsCategory.groups, id: \.title) { group in
                        categorySection(group.title) {
                            ForEach(group.categories) { padCategoryRow($0) }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 24)
            }
        }
        .background(Color(.secondarySystemBackground).ignoresSafeArea())
    }

    private func categorySection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
            content()
        }
    }

    private func padCategoryRow(_ category: SettingsCategory) -> some View {
        Button {
            selectedCategory = category
        } label: {
            Label(category.title(for: app.bundleInfo?.franchise), systemImage: category.symbol)
                .font(.subheadline.weight(selectedCategory == category ? .semibold : .regular))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(
                    selectedCategory == category ? Color.accentColor.opacity(0.16) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8)
                )
        }
        .buttonStyle(.plain)
    }

    private func categoryRow(_ category: SettingsCategory) -> some View {
        Label(category.title(for: app.bundleInfo?.franchise), systemImage: category.symbol)
            .tag(category)
    }

    private func visible(_ filter: SettingsCategory?, _ category: SettingsCategory) -> Bool {
        filter == nil || filter == category
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

    /// How many of the five API groups are filled in, for the entry row.
    private var apiSummary: String {
        let settings = app.chatSettings
        var configured = 0
        if settings.isConfigured { configured += 1 }
        if settings.hasBackgroundModel ? settings.backgroundConfig != nil : settings.isConfigured {
            configured += 1
        }
        if app.judgeProvider != nil { configured += 1 }
        if settings.retrievalEmbeddingConfig(for: app.contentEmbeddingSpace) != nil {
            configured += 1
        }
        if settings.recognitionIsConfigured,
           !settings.fishAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            configured += 1
        }
        if settings.imageIsConfigured { configured += 1 }
        let count = "已配置 \(configured) / 6"
        guard let name = app.activeChatProfile?.name, !name.isEmpty else { return count }
        return "\(name) · \(count)"
    }

    @ViewBuilder
    private var standBundleSection: some View {
        Section {
            if let info = app.staticStandInfo {
                LabeledContent("静态立绘", value: "\(info.characterCount) 角色 / \(info.expressionCount) 表情")
                LabeledContent("绑定", value: info.contentSetID ?? "未绑定")
            }
            if let info = app.standInfo {
                LabeledContent("Spine 立绘", value: "\(info.characterCount) 角色 / \(info.outfitCount) 套衣装")
                LabeledContent("格式", value: "v\(info.formatVersion)")
                LabeledContent("安装时间", value: info.installedAt)
            } else if app.staticStandInfo == nil {
                Text("当前企划还没有导入立绘包")
                    .foregroundStyle(.secondary)
            }
            Button(app.standInfo == nil ? "导入 Spine 立绘包" : "重新导入 Spine 立绘包") {
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
                .anchoredConfirmation(
                    "清理 Documents 里的内容包？",
                    message: "只删除 Documents 里的 .eidolonpkg 文件；已安装的内容和立绘不受影响。",
                    confirmTitle: "清理",
                    isPresented: $confirmingPackageCleanup,
                    onConfirm: { _ = app.removeDocumentPackages() }
                )
            }
        } header: {
            Text("立绘包")
        } footer: {
            Text("Spine 与静态立绘按内容企划分开存放；切换企划只读取当前企划的包。")
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
        historyTurns = settings.historyTurns
        atmosphericText = settings.atmosphericText
        adultMode = settings.adultMode
        callMinutes = settings.callMinutes
        callTurns = settings.callTurns
        phoneTexture = settings.phoneTexture
        reachOutHours = settings.reachOutHours
        reachOutByTier = settings.reachOutByTier
        tracingEnabled = settings.tracingEnabled
        traceRetention = settings.traceRetention
        if let profile = try? await app.core.producerProfile() {
            formOfAddress = profile.formOfAddress ?? ""
            gender = profile.gender?.rawValue ?? "default"
            profileTimezone = profile.timezone ?? ""
            birthdayOn = profile.birthdayMonth != nil && profile.birthdayDay != nil
            let zone = TimeZone(identifier: profile.timezone ?? "") ?? .current
            var year = Self.pickerYear(profile.birthdayYear, timeZone: zone)
            // February 29 cannot be shown in a non-leap year; keep the month and day by
            // opening on a leap year rather than letting the calendar roll to March 1.
            if profile.birthdayMonth == 2, profile.birthdayDay == 29,
                !Self.isLeapYear(year) {
                year = Self.pickerYear(nil, timeZone: zone)
            }
            if let month = profile.birthdayMonth, let day = profile.birthdayDay {
                if Birthday.valid(month: month, day: day) {
                    birthdayDate = Self.date(year: year, month: month, day: day, timeZone: zone)
                    birthdayError = nil
                } else {
                    birthdayDate = Self.date(year: year, month: 1, day: 1, timeZone: zone)
                    birthdayError = "原来的生日日期不合法，请重新选择"
                }
            } else {
                birthdayDate = Self.date(year: year, month: 1, day: 1, timeZone: zone)
                birthdayError = nil
            }
        }
    }

    /// The settings as they are on screen: the API page's values, with this page's
    /// behavior fields applied over them.
    private var draft: ChatSettings {
        var settings = app.chatSettings
        settings.historyTurns = historyTurns
        settings.atmosphericText = atmosphericText
        settings.adultMode = adultMode
        settings.callMinutes = callMinutes
        settings.callTurns = callTurns
        settings.phoneTexture = phoneTexture
        settings.reachOutHours = reachOutHours
        settings.reachOutByTier = reachOutByTier
        settings.tracingEnabled = tracingEnabled
        settings.traceRetention = traceRetention
        return settings
    }

    private func save() async {
        let settings = draft
        do {
            try app.saveChatSettings(settings)
            birthdayError = nil
            let zone = profileTimezone.trimmingCharacters(in: .whitespacesAndNewlines)
            if !zone.isEmpty, TimeZone(identifier: zone) == nil {
                saveError = "时区无法识别：\(zone)"
                return
            }
            var birthday: (year: Int, month: Int, day: Int)?
            if birthdayOn {
                let parts = Self.parts(of: birthdayDate, timeZone: birthdayTimeZone)
                guard Birthday.valid(month: parts.month, day: parts.day) else {
                    birthdayError = EidolonError.invalidProducerBirthday.localizedDescription
                    return
                }
                birthday = parts
            }
            let address = formOfAddress.trimmingCharacters(in: .whitespacesAndNewlines)
            try await app.saveProducerProfile(
                ProducerProfile(
                    formOfAddress: address.isEmpty ? nil : address,
                    gender: gender == "male" ? .male : gender == "female" ? .female : nil,
                    timezone: zone.isEmpty ? nil : zone,
                    birthdayMonth: birthday?.month,
                    birthdayDay: birthday?.day,
                    birthdayYear: birthday?.year
                )
            )
            savedNotice = true
        } catch {
            saveError = error.localizedDescription
        }
    }

    private var birthdayTimeZone: TimeZone {
        TimeZone(identifier: profileTimezone.trimmingCharacters(in: .whitespacesAndNewlines))
            ?? .current
    }

    /// Any birth year up to this one. The year is only there to pick the date; saving keeps
    /// the month and day, as the profile has no use for the year.
    private var birthdayRange: ClosedRange<Date> {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = birthdayTimeZone
        let thisYear = calendar.component(.year, from: Date())
        return Self.date(year: 1900, month: 1, day: 1, timeZone: birthdayTimeZone)
            ... Self.date(year: thisYear, month: 12, day: 31, timeZone: birthdayTimeZone)
    }

    private static func date(
        year: Int, month: Int, day: Int, timeZone: TimeZone
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(
            from: DateComponents(year: year, month: month, day: day, hour: 12)
        )!
    }

    private static func parts(
        of date: Date, timeZone: TimeZone
    ) -> (year: Int, month: Int, day: Int) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return (parts.year ?? 2000, parts.month ?? 1, parts.day ?? 1)
    }

    /// The year the picker opens on: the saved one, or the most recent leap year when none
    /// (or an impossible one) was saved, so February 29 can be picked. Once a year is saved
    /// it is kept; choosing it is not undone on reopen.
    private static func pickerYear(_ year: Int?, timeZone: TimeZone) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let thisYear = calendar.component(.year, from: Date())
        if let year, (1900...thisYear).contains(year) { return year }
        var fallback = thisYear
        while !isLeapYear(fallback) { fallback -= 1 }
        return fallback
    }

    private static func isLeapYear(_ year: Int) -> Bool {
        year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
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


/// A read-only browse view over the installed story rows, grouped by route and chapter.
/// It deliberately reads only the catalog columns, never the embeddings.
struct StoryCatalogView: View {
    @Environment(AppModel.self) private var app
    @State private var entries: [StoryCatalogEntry] = []
    @State private var failure: String?

    var body: some View {
        List {
            if let failure {
                ContentUnavailableView("读不到剧情目录", systemImage: "books.vertical", description: Text(failure))
            }
            ForEach(grouped, id: \.route) { group in
                Section(group.route) {
                    ForEach(group.entries) { entry in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.title).font(.subheadline.weight(.medium))
                            HStack(spacing: 8) {
                                Text(entry.chapter ?? "")
                                if !entry.cast.isEmpty {
                                    Text(entry.cast.joined(separator: "、"))
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("剧情目录")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            entries = await app.storyCatalog()
            if entries.isEmpty { failure = "当前内容包没有剧情目录。" }
        }
    }

    private var grouped: [(route: String, entries: [StoryCatalogEntry])] {
        Dictionary(grouping: entries.dropFirst(0), by: { $0.route ?? "共通" })
            .sorted { $0.key < $1.key }
            .map { ($0.key, $0.value) }
    }
}


/// The original TIPS.CSV terms, listed with their reading. The story text's `<dNNNN>`
/// references use the same identifiers, so this is the reference table the producer
/// needs while reading a chapter.
struct TermCatalogView: View {
    @Environment(AppModel.self) private var app
    @State private var terms: [ContentTerm] = []

    var body: some View {
        List {
            if terms.isEmpty {
                ContentUnavailableView("没有用语集", systemImage: "character.book.closed", description: Text("当前内容包没有 terms.json。"))
            }
            ForEach(terms) { term in
                VStack(alignment: .leading, spacing: 3) {
                    Text(term.term)
                    if !term.reading.isEmpty {
                        Text(term.reading).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .navigationTitle("用语集")
        .navigationBarTitleDisplayMode(.inline)
        .task { terms = await app.terms() }
    }
}
