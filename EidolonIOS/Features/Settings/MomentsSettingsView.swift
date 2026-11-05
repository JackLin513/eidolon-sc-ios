import EidolonCore
import SwiftUI

/// 设置 → 朋友圈 (spec #98): whether she posts, how often, how many replies a day, which map
/// opens a place, and whether a background run may notify.
struct MomentsSettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var settings = MomentsSettings.default
    @State private var saveError: String?
    @State private var debugCharacterIDs: Set<String> = []
    @State private var debugImageMode: DebugMomentImageMode = .auto
    @State private var debugComposition: MomentComposition?
    @State private var debugForceAdult = false
    @State private var debugGenerating = false
    @State private var debugResult: String?

    var body: some View {
        Form {
            Section {
                Toggle("开启朋友圈", isOn: $settings.enabled)
                    .accessibilityIdentifier("moments.settings.enabled")
            } footer: {
                Text("关闭时不排计划、不生成、不花钱；已经发过的动态保留，照常过期。")
            }

            Section("节奏") {
                Stepper(value: $settings.dailyPosts, in: 1...10) {
                    LabeledContent("每天最多动态", value: "\(settings.dailyPosts) 条")
                }
                Stepper(value: $settings.dailyReplies, in: 0...50) {
                    LabeledContent("每天最多回复", value: "\(settings.dailyReplies) 条")
                }
            }

            Section {
                Picker("地图服务", selection: $settings.mapProvider) {
                    ForEach(MomentMapProvider.allCases) { provider in
                        Text(provider.title).tag(provider)
                    }
                }
                Toggle("新动态发通知", isOn: $settings.notifications)
            } header: {
                Text("显示")
            } footer: {
                Text("通知只由后台生成成功时发出；她发了新动态时，导航上也会有一个点。")
            }

            if app.debugMode {
                Section {
                    DisclosureGroup(
                        "生成角色（已选 \(debugCharacterIDs.count)）"
                    ) {
                        ForEach(app.characters, id: \.id) { character in
                            Toggle(
                                character.nameZh ?? character.name,
                                isOn: selectedBinding(character.id)
                            )
                        }
                        HStack {
                            Button("全选") {
                                debugCharacterIDs = Set(app.characters.map(\.id))
                            }
                            Spacer()
                            Button("全不选") { debugCharacterIDs.removeAll() }
                        }
                        .font(.footnote)
                    }

                    Picker("配图", selection: $debugImageMode) {
                        ForEach(DebugMomentImageMode.allCases, id: \.self) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    if debugImageMode == .forced {
                        Picker("构图", selection: $debugComposition) {
                            Text("自动").tag(Optional<MomentComposition>.none)
                            ForEach(MomentComposition.allCases, id: \.self) { composition in
                                Text(composition.title).tag(Optional(composition))
                            }
                        }
                        Text("合照会自动拉一位圈子成员一起入镜；风景、食物、物品画面里没有人。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Toggle("强制 R 配图", isOn: $debugForceAdult)
                        .disabled(!settings.enabled)

                    Button {
                        generateDebugMoments()
                    } label: {
                        HStack {
                            Text("立即生成选了 \(debugCharacterIDs.count) 位的朋友圈")
                            if debugGenerating { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(
                        debugGenerating || !settings.enabled
                            || debugCharacterIDs.isEmpty
                    )
                    .accessibilityIdentifier("moments.debug.generate")
                    if let debugResult {
                        Text(debugResult)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("调试：立即生成")
                } footer: {
                    Text("跳过当天的计划、每日上限和好感度门槛，给选中的每位各生成一条；"
                        + "成功后切到朋友圈。图片和文字都走正常流程，会花掉正常调用。"
                        + "强制 R 仍要求成人模式开着、且画面里所有角色都明确 18 岁以上；"
                        + "无人的风景/食物/物品始终全年龄。")
                }

                Section {
                    Toggle("朋友圈也允许 R 配图", isOn: $settings.debugAdultImages)
                } header: {
                    Text("调试")
                } footer: {
                    Text("这是普通朋友圈生成时的开关；上面的「强制 R 配图」只对调试按钮这一次生效。")
                }
            }

            if let saveError {
                Section {
                    Text(saveError).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("朋友圈")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            settings = app.momentsSettings
            if debugCharacterIDs.isEmpty, let first = app.characters.first {
                debugCharacterIDs = [first.id]
            }
        }
        .onChange(of: settings) { _, value in
            Task {
                do {
                    try await app.saveMomentsSettings(value)
                    saveError = nil
                } catch {
                    saveError = error.localizedDescription
                }
            }
        }
    }

    private func selectedBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { debugCharacterIDs.contains(id) },
            set: { on in
                if on { debugCharacterIDs.insert(id) } else { debugCharacterIDs.remove(id) }
            }
        )
    }

    private func generateDebugMoments() {
        guard !debugCharacterIDs.isEmpty, !debugGenerating else { return }
        debugGenerating = true
        debugResult = nil
        let ids = app.characters.map(\.id).filter { debugCharacterIDs.contains($0) }
        let mode = debugImageMode
        Task {
            let made = await app.debugGenerateMoments(
                characterIDs: ids,
                allowImage: mode != .none,
                forceImage: mode == .forced,
                composition: mode == .forced ? debugComposition : nil,
                forceAdult: debugForceAdult
            )
            debugGenerating = false
            if made > 0 {
                debugResult = "生成了 \(made) 条，正切到朋友圈。"
                app.selectedTab = .moments
            } else {
                debugResult = "没生成出来；去「用量与花费」看这次调用的错误。"
            }
        }
    }
}

private enum DebugMomentImageMode: String, CaseIterable, Hashable {
    case auto
    case none
    case forced

    var title: String {
        switch self {
        case .auto: "自动（约三分之二）"
        case .none: "不配图"
        case .forced: "必带图"
        }
    }
}
