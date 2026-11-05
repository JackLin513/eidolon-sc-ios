import EidolonCore
import SwiftUI

/// The editor for one saved chat model (spec #116). The API page owns the list, the
/// switching and the deletion; this sheet only edits a profile's fields. A blank key
/// keeps the stored one.
struct ChatModelProfileEditor: View {
    let profile: ChatModelProfile
    let existingNames: [String]
    let onSave: (ChatModelProfile, String) -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var apiProtocol: ChatProtocol
    @State private var baseURL: String
    @State private var model: String
    @State private var apiKey = ""
    @State private var maxTokens: Int?
    @State private var extraBody: String
    @State private var error: String?

    init(
        profile: ChatModelProfile,
        existingNames: [String],
        onSave: @escaping (ChatModelProfile, String) -> String?
    ) {
        self.profile = profile
        self.existingNames = existingNames
        self.onSave = onSave
        _name = State(initialValue: profile.name)
        _apiProtocol = State(initialValue: profile.apiProtocol)
        _baseURL = State(initialValue: profile.baseURL)
        _model = State(initialValue: profile.model)
        _maxTokens = State(initialValue: profile.maxTokens)
        _extraBody = State(initialValue: profile.extraBody)
    }

    var body: some View {
        NavigationStack {
            Form {
                if let error {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("api.profile.error")
                    }
                }

                Section {
                    TextField("名称", text: $name)
                        .accessibilityIdentifier("api.profile.name")
                    SettingsHint("列表里显示的名字；不能为空，也不能和别的配置重名。")
                }

                Section {
                    Picker("接口协议", selection: $apiProtocol) {
                        ForEach(ChatProtocol.allCases) { value in
                            Text(value.title).tag(value)
                        }
                    }
                    .accessibilityIdentifier("api.profile.protocol")
                    TextField("接口地址", text: $baseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .accessibilityIdentifier("api.profile.baseURL")
                    SettingsHint("DeepSeek 用 https://api.deepseek.com/v1；本地 llama.cpp 通常写到 /v1。")
                    TextField("模型名", text: $model)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("api.profile.model")
                    SettingsHint("服务上的模型标识；本地模型填 llama.cpp 实际暴露的名字。")
                    SecureField("密钥（留空保留已存密钥）", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("api.profile.key")
                    SettingsHint("只存钥匙串，每套配置各存各的；留空不会覆盖已有密钥。")
                } header: {
                    Text("对话模型")
                }

                Section {
                    TextField("max tokens（可空）", value: $maxTokens, format: .number)
                        .keyboardType(.numberPad)
                        .accessibilityIdentifier("api.profile.maxTokens")
                    SettingsHint("单次回复最多多少 token；留空用服务默认，不限制。")
                    TextField("额外参数（JSON 对象，可空）", text: $extraBody, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.footnote.monospaced())
                        .accessibilityIdentifier("api.profile.extraBody")
                    SettingsHint("深合并进请求，不能改 model/stream/messages/tools。例：{\"enable_thinking\": false}")
                } header: {
                    Text("请求")
                }

            }
            .navigationTitle(profile.name.isEmpty ? "新配置" : profile.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                        .accessibilityIdentifier("api.profile.cancel")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") { save() }
                        .fontWeight(.semibold)
                        .accessibilityIdentifier("api.profile.save")
                }
            }
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            error = "名称不能为空。"
            return
        }
        guard !existingNames.contains(trimmedName) else {
            error = "已经有同名配置了，换一个名字。"
            return
        }
        var updated = profile
        updated.name = trimmedName
        updated.apiProtocol = apiProtocol
        updated.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.maxTokens = maxTokens
        updated.extraBody = extraBody.trimmingCharacters(in: .whitespacesAndNewlines)
        if let message = onSave(updated, apiKey) {
            error = message
            return
        }
        dismiss()
    }
}
