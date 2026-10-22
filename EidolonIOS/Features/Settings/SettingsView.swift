import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var baseURL = Backend.url.absoluteString

    var body: some View {
        NavigationStack {
            Form {
                Section("后端") {
                    TextField("http://127.0.0.1:8000", text: $baseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)

                    Button("保存并重新连接") {
                        if app.setBaseURL(baseURL) {
                            dismiss()
                        }
                    }

                    Text("模拟器里的 127.0.0.1 就是这台 Mac。真机要改成 Mac 的局域网地址，并让后端的 Origin 校验允许它。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("账号") {
                    if let account = app.account {
                        LabeledContent("名字", value: account.name)
                        LabeledContent("ID") {
                            Text(account.id)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                    }

                    Button("刷新角色列表") {
                        Task { await app.refresh() }
                    }

                    Button("退出登录", role: .destructive) {
                        Task {
                            await app.signOut()
                            dismiss()
                        }
                    }
                }

                Section("这一版") {
                    Text("已实现：开发登录、同意条款、角色列表、流式文字对话。")
                    Text("还没做：语音通话、立绘、礼物、统计、自带密钥、照片、数据包。")
                        .foregroundStyle(.secondary)
                }

                if let error = app.errorMessage {
                    Section("错误") {
                        Text(error)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("设置")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
