import SwiftUI
import UIKit
import EidolonCore

/// 管理页（spec #122）：账号、邀请码、公告、重新扫描包目录。
/// 界面只负责发起和展示；能不能做由服务端裁决，这里的每个失败都只影响这一页。
struct AdminView: View {
    @Environment(AppModel.self) private var app
    @State private var users: [ServerUser] = []
    @State private var invites: [ServerInvite] = []
    @State private var announcements: [ServerAnnouncement] = []
    @State private var isWorking = false
    @State private var error: String?
    @State private var notice: String?
    @State private var inviteDays = 7

    @State private var resetting = false
    @State private var resetPassword = ""
    @State private var resetTarget: ServerUser?
    @State private var userToDelete: ServerUser?
    @State private var draftTitle = ""
    @State private var draftBody = ""

    private var server: ServerStore { app.server }
    private var client: ServerClient? { server.adminClient }

    var body: some View {
        Form {
            usersSection
            invitesSection
            announcementsSection
            packagesSection

            if let error {
                Section {
                    Text(error).foregroundStyle(.red).font(.footnote)
                }
            }
            if let notice {
                Section {
                    Text(notice).foregroundStyle(.secondary).font(.footnote)
                }
            }
        }
        .navigationTitle("管理")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await reload() }
        .task { await reload() }
        .alert("给 \(resetTarget?.username ?? "") 设一个新密码", isPresented: $resetting) {
            SecureField("新密码", text: $resetPassword)
            Button("取消", role: .cancel) { resetPassword = "" }
            Button("设好") {
                guard let target = resetTarget else { return }
                let password = resetPassword
                resetPassword = ""
                Task { await run { try await self.client?.setPassword(password, userID: target.id) } }
            }
        } message: {
            Text("至少 8 位。这个账号已经登录的地方会立刻退出。")
        }
        .confirmationDialog(
            "删除 \(userToDelete?.username ?? "")？",
            isPresented: Binding(get: { userToDelete != nil }, set: { if !$0 { userToDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                guard let target = userToDelete else { return }
                userToDelete = nil
                Task { await run { try await self.client?.deleteUser(id: target.id) } }
            }
            Button("取消", role: .cancel) { userToDelete = nil }
        } message: {
            Text("它的令牌会一起作废，删了就找不回来。")
        }
    }

    // MARK: - 账号

    private var usersSection: some View {
        Section {
            ForEach(users) { user in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(user.username)
                        Text(subtitle(user)).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if user.isAdmin {
                        Text("管理员").font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.tint, in: Capsule())
                            .foregroundStyle(.white)
                    }
                    Menu {
                        Button(user.isDisabled ? "启用" : "停用") {
                            Task {
                                await run { try await self.client?.setDisabled(!user.isDisabled, userID: user.id) }
                            }
                        }
                        Button("设新密码") {
                            resetTarget = user
                            resetting = true
                        }
                        Button("删除", role: .destructive) { userToDelete = user }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityIdentifier("admin.user.\(user.username)")
                }
            }
        } header: {
            HStack {
                Text("账号")
                Spacer()
                if isWorking { ProgressView() }
            }
        } footer: {
            Text("停用会立刻让它已经登录的地方失效；角色只能在服务器上用命令改。")
        }
    }

    private func subtitle(_ user: ServerUser) -> String {
        var parts = [user.isDisabled ? "已停用" : "正常"]
        parts.append("注册 \(String(user.createdAt.prefix(10)))")
        if let last = user.lastLoginAt {
            parts.append("最后登录 \(String(last.prefix(10)))")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - 邀请码

    private var invitesSection: some View {
        Section {
            Stepper("有效期 \(inviteDays) 天", value: $inviteDays, in: 1...90)
            Button("生成一个新的邀请码") {
                let days = inviteDays
                Task {
                    await run {
                        if let invite = try await self.client?.createInvite(days: days) {
                            UIPasteboard.general.string = invite.code
                            self.notice = "已复制 \(invite.code)，发给朋友就能注册"
                        }
                    }
                }
            }
            ForEach(invites) { invite in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(invite.code).font(.system(.body, design: .monospaced))
                        Spacer()
                        Text(invite.stateName).font(.caption2).foregroundStyle(.secondary)
                    }
                    Text(expires(invite)).font(.caption2).foregroundStyle(.tertiary)
                }
                .swipeActions {
                    if invite.state == "open" {
                        Button("作废", role: .destructive) {
                            Task { await run { try await self.client?.revokeInvite(id: invite.id) } }
                        }
                    }
                }
                .onTapGesture { UIPasteboard.general.string = invite.code }
            }
        } header: {
            Text("邀请码")
        } footer: {
            Text("生成后自动复制；一行一个码，点一下也能再复制。")
        }
    }

    private func expires(_ invite: ServerInvite) -> String {
        guard let expires = invite.expiresAt else { return "长期有效" }
        return "到 \(String(expires.prefix(10)))"
    }

    // MARK: - 公告

    private var announcementsSection: some View {
        Section {
            TextField("标题", text: $draftTitle)
            TextField("正文", text: $draftBody, axis: .vertical).lineLimit(3...8)
            Button("发布") {
                let title = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                let body = draftBody.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty, !body.isEmpty else { return }
                Task {
                    await run { try await self.client?.publishAnnouncement(title: title, body: body) }
                    if error == nil {
                        draftTitle = ""
                        draftBody = ""
                        notice = "公告发出去了"
                    }
                }
            }
            .disabled(draftTitle.isEmpty || draftBody.isEmpty)

            ForEach(announcements) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).font(.headline)
                    Text(String(item.publishedAt.prefix(10))).font(.caption2).foregroundStyle(.tertiary)
                }
                .swipeActions {
                    Button("删除", role: .destructive) {
                        Task { await run { try await self.client?.deleteAnnouncement(id: item.id) } }
                    }
                }
            }
        } header: {
            Text("公告")
        } footer: {
            Text("发出去以后，朋友那边的对话页首会出现一个小圆点。")
        }
    }

    // MARK: - 包目录

    private var packagesSection: some View {
        Section {
            Button("重新扫描包目录") {
                Task {
                    await run { try await self.client?.rescanPackages() }
                    if error == nil { notice = "扫完了；新放进去的包已经能下载" }
                }
            }
        } header: {
            Text("内容包")
        } footer: {
            Text("把 .eidolonpkg 放进服务器的包目录以后点这一下，省掉那条命令。")
        }
    }

    // MARK: -

    private func reload() async {
        guard let client else { return }
        isWorking = true
        error = nil
        do {
            users = try await client.users()
            invites = try await client.invites()
            announcements = try await client.announcements(since: 0).items
        } catch {
            take(error)
        }
        isWorking = false
    }

    private func run(_ work: @escaping @MainActor () async throws -> Void) async {
        isWorking = true
        error = nil
        notice = nil
        do {
            try await work()
            await reload()
        } catch {
            take(error)
        }
        isWorking = false
    }

    /// 管理动作失败只写在这一页上。登录没了就退出登录；403 说明服务端不认这个角色，
    /// 本地跟着改回普通，「管理」这一项就没了。409（比如不能停用自己）照原样说。
    private func take(_ error: Error) {
        let failure = error as? ServerError
        switch failure {
        case .notLoggedIn, .accountDisabled:
            server.signOut()
        case .noPermission:
            server.forgetAdminRole()
            self.error = failure?.text
        default:
            self.error = failure?.text ?? error.localizedDescription
        }
    }
}
