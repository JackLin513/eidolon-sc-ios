import SwiftUI

struct LoginView: View {
    @Environment(AppModel.self) private var app
    @State private var name = "producer"

    var body: some View {
        VStack(spacing: 18) {
            Spacer()

            Image(systemName: "sparkles")
                .font(.system(size: 44))
                .foregroundStyle(.tint)

            VStack(spacing: 6) {
                Text("Eidolon")
                    .font(.largeTitle.bold())
                Text("283 事务所 · iOS 实验客户端")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            TextField("你的名字", text: $name)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(.top, 10)

            Button {
                Task { await app.signIn(name: name) }
            } label: {
                if app.isBusy {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Text("开发登录")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(app.isBusy)

            if let error = app.errorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            Text("开发登录需要后端以 EIDOLON_DEV_LOGIN=1 启动。\n当前后端：\(Backend.url.absoluteString)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)

            Spacer()
        }
        .padding(24)
    }
}
