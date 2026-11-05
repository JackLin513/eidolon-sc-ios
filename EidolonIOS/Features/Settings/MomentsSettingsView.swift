import EidolonCore
import SwiftUI

/// 设置 → 朋友圈 (spec #98): whether she posts, how often, how many replies a day, which map
/// opens a place, and whether a background run may notify.
struct MomentsSettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var settings = MomentsSettings.default
    @State private var saveError: String?

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
        .onAppear { settings = app.momentsSettings }
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
}
