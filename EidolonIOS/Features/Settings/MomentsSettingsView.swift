import EidolonCore
import SwiftUI

/// 设置 → 朋友圈 (spec #98): whether she posts, how often, how many replies a day, which map
/// opens a place, and whether a background run may notify.
struct MomentsSettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var settings = MomentsSettings.default
    @State private var saveError: String?
    @State private var debugCharacterID = ""
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
                    Picker("调试用角色", selection: $debugCharacterID) {
                        ForEach(app.characters, id: \.id) { character in
                            Text(character.nameZh ?? character.name).tag(character.id)
                        }
                    }
                    Button {
                        generateDebugMoment()
                    } label: {
                        HStack {
                            Text("立即生成一条朋友圈")
                            if debugGenerating { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(
                        debugGenerating || !settings.enabled || debugCharacterID.isEmpty
                    )
                    .accessibilityIdentifier("moments.debug.generate")
                    if let debugResult {
                        Text(debugResult)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("调试：立即发一条")
                } footer: {
                    Text("跳过当天的计划、每日上限和好感度门槛，用选中的角色马上生成一条；"
                        + "成功后切到朋友圈。图片和文字都走正常流程，会花掉正常的一次调用。")
                }

                Section {
                    Toggle("朋友圈也允许 R 配图", isOn: $settings.debugAdultImages)
                } header: {
                    Text("调试")
                } footer: {
                    Text("只有成人模式也开着、且画面里出现的所有角色都明确 18 岁以上时才生效；普通朋友圈始终全年龄。")
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
            if debugCharacterID.isEmpty {
                debugCharacterID = app.characters.first?.id ?? ""
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

    private func generateDebugMoment() {
        guard !debugCharacterID.isEmpty, !debugGenerating else { return }
        debugGenerating = true
        debugResult = nil
        Task {
            let made = await app.debugGenerateMoment(characterID: debugCharacterID)
            debugGenerating = false
            if made {
                debugResult = "已生成一条，正切到朋友圈。"
                app.selectedTab = .moments
            } else {
                debugResult = "没生成出来；去「用量与花费」看这次调用的错误。"
            }
        }
    }
}
