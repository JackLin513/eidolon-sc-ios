import SwiftUI
import EidolonCore

/// 设置最上面那一项（spec #120，位置按上游的用法调整）：登录页和登录以后的样子。
/// 没登录时它就是登录 / 注册；登录以后显示是谁、内容包、退出登录，管理员多一项「管理」。
/// 不登录、没有网、服务器关机都不影响 App 的其它部分。
struct AccountView: View {
    @Environment(AppModel.self) private var app
    @State private var username = ""
    @State private var password = ""
    @State private var invite = ""
    @State private var mode: Mode = .signIn

    private var server: ServerStore { app.server }

    private enum Mode: String, CaseIterable {
        case signIn = "登录"
        case register = "注册"
    }

    var body: some View {
        Form {
            if server.isSignedIn {
                accountSection
                packagesSection
            } else {
                addressSection
                signInSection
            }

            if let error = server.errorMessage {
                Section {
                    Text(error).foregroundStyle(.red).font(.footnote)
                }
            }
        }
        .navigationTitle(server.isSignedIn ? "账号" : "登录")
        .navigationBarTitleDisplayMode(.inline)
        .task { await server.refresh() }
    }

    private var addressSection: some View {
        Section {
            TextField("服务器地址", text: Bindable(server).baseURLText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
        } header: {
            Text("地址")
        } footer: {
            Text("它只解决「包从哪来」和「公告在哪看」——不登录、没有网，App 照旧能用。")
        }
    }

    private var accountSection: some View {
        Section {
            if let session = server.session {
                LabeledContent("账号", value: session.username)
                LabeledContent("身份", value: session.isAdmin ? "管理员" : "普通账号")
            }
            if ServerAdmin.showsEntry(for: server.session) {
                NavigationLink {
                    AdminView()
                } label: {
                    LabeledContent("管理", value: "账号、邀请码、公告")
                }
                .accessibilityIdentifier("account.admin")
            }
            Button("退出登录", role: .destructive) { server.signOut() }
        } header: {
            Text("已登录")
        } footer: {
            Text("令牌存在钥匙串里，180 天内不用重新登录；手机上东西都还在本机。")
        }
    }

    private var signInSection: some View {
        Section {
            Picker("方式", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            if mode == .register {
                TextField("邀请码", text: $invite)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
            }
            TextField("用户名", text: $username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField("密码", text: $password)

            Button {
                Task {
                    if mode == .signIn {
                        await server.signIn(username: username, password: password)
                    } else {
                        await server.register(invite: invite, username: username, password: password)
                    }
                    password = ""
                }
            } label: {
                if server.isWorking {
                    ProgressView()
                } else {
                    Text(mode.rawValue)
                }
            }
            .disabled(username.isEmpty || password.isEmpty
                      || (mode == .register && invite.isEmpty) || server.isWorking)
        } header: {
            Text("账号")
        } footer: {
            Text("注册要邀请码；密码至少 8 位。")
        }
    }

    private var packagesSection: some View {
        Section {
            if server.packages.isEmpty {
                Text("服务器上还没有包").foregroundStyle(.secondary)
            }
            ForEach(server.packages) { package in
                row(package)
            }
        } header: {
            HStack {
                Text("内容包")
                Spacer()
                if server.isWorking { ProgressView() }
            }
        } footer: {
            Text("下载支持断点续传；下完会校验，然后走和「导入内容包」同一条路。")
        }
    }

    private func row(_ package: ServerPackage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(package.kindName).font(.headline)
                Text(package.version).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let written = server.downloading[package.id] {
                    Text("\(written.megabytes) / \(package.size.megabytes)")
                        .font(.caption2).foregroundStyle(.secondary)
                } else if server.isInstalled(package) {
                    HStack(spacing: 10) {
                        Text("已安装").font(.caption2).foregroundStyle(.secondary)
                        Button("重新下载") {
                            Task { await server.download(package, into: app) }
                        }
                        .font(.caption2)
                    }
                } else {
                    Button("下载并导入") {
                        Task { await server.download(package, into: app) }
                    }
                    .font(.caption)
                }
            }
            if let written = server.downloading[package.id] {
                ProgressView(value: Double(written), total: Double(max(package.size, 1)))
            }
        }
    }
}
