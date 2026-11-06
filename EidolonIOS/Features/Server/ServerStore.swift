import EidolonCore
import Foundation
import Observation

/// App 这一侧的服务器状态（spec #120）：登录、包列表、公告、下载。
/// 它只做「记住谁登录了、现在有什么、下到哪了」，真正的请求在 `ServerClient`，
/// 真正把包装进去的还是 `AppModel` 原有的三个导入入口。
@MainActor
@Observable
final class ServerStore {
    static let baseURLKey = "server.baseURL"
    static let usernameKey = "server.username"
    static let roleKey = "server.role"
    static let announcementCursorKey = "server.announcementCursor"
    static let tokenAccount = "server.token"

    var baseURLText: String {
        didSet { UserDefaults.standard.set(baseURLText, forKey: Self.baseURLKey) }
    }

    private(set) var session: ServerSession?
    private(set) var packages: [ServerPackage] = []
    private(set) var announcements: [ServerAnnouncement] = []
    /// 公告的已读游标（判断在 Core 的 `AnnouncementCursor` 里）。
    private(set) var cursor = AnnouncementCursor()
    private(set) var isWorking = false
    private(set) var downloading: [Int: Int] = [:]
    var errorMessage: String?

    private let downloader = PackageDownloader()

    init() {
        baseURLText = UserDefaults.standard.string(forKey: Self.baseURLKey) ?? ""
        if let username = UserDefaults.standard.string(forKey: Self.usernameKey),
           let token = Keychain.string(account: Self.tokenAccount) {
            session = ServerSession(
                username: username,
                token: token,
                role: UserDefaults.standard.string(forKey: Self.roleKey) ?? "user",
                expiresAt: ""
            )
        }
        cursor = AnnouncementCursor(
            latestSeen: UserDefaults.standard.integer(forKey: Self.announcementCursorKey)
        )
    }

    var isSignedIn: Bool { session != nil }

    /// 服务器上这份和手机上装着的那份是不是同一份（比内容指纹，不比文件名）。
    func isInstalled(_ package: ServerPackage) -> Bool {
        InstalledPackages.isInstalled(package.sha256, kind: package.kind)
    }

    /// 有没看过的新公告——那个红点就靠它。
    var hasUnreadAnnouncements: Bool {
        !cursor.unread(in: announcements).isEmpty
    }

    var latestAnnouncement: Int { cursor.latestSeen }

    private var baseURL: URL? {
        let text = baseURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let url = URL(string: text) else { return nil }
        return url
    }

    /// 管理页（spec #122）直接拿它发请求：那些动作和「谁登录了」无关，失败也只影响管理页自己。
    var adminClient: ServerClient? { client() }

    /// 管理接口说「没有权限」时，把本地记下的角色改回普通——服务端才是唯一的判断者。
    func forgetAdminRole() {
        session?.role = "user"
        UserDefaults.standard.set("user", forKey: Self.roleKey)
    }

    private func client(token: String? = nil) -> ServerClient? {
        guard let baseURL else { return nil }
        return ServerClient(baseURL: baseURL, token: token ?? session?.token)
    }

    // MARK: - 登录

    func signIn(username: String, password: String) async {
        guard let client = client(token: "") else {
            errorMessage = "先填服务器的地址"
            return
        }
        await perform {
            let session = try await client.login(username: username, password: password)
            self.remember(session)
            await self.refresh()
        }
    }

    func register(invite: String, username: String, password: String) async {
        guard let client = client(token: "") else {
            errorMessage = "先填服务器的地址"
            return
        }
        await perform {
            try await client.register(invite: invite, username: username, password: password)
            let session = try await client.login(username: username, password: password)
            self.remember(session)
            await self.refresh()
        }
    }

    func signOut() {
        Keychain.remove(account: Self.tokenAccount)
        UserDefaults.standard.removeObject(forKey: Self.usernameKey)
        UserDefaults.standard.removeObject(forKey: Self.roleKey)
        session = nil
        packages = []
        announcements = []
        // 已读游标留着：退出再登录，之前看过的公告不该又变成新的。
    }

    private func remember(_ session: ServerSession) {
        self.session = session
        try? Keychain.set(session.token, account: Self.tokenAccount)
        UserDefaults.standard.set(session.username, forKey: Self.usernameKey)
        UserDefaults.standard.set(session.role, forKey: Self.roleKey)
    }

    // MARK: - 包与公告

    func refresh() async {
        // 没登录时不去问服务器：那只会换来一个「登录已过期」，登录页一打开就一片红。
        guard isSignedIn, let client = client() else { return }
        await perform {
            self.packages = try await client.packages()
        }
        // 已读游标不动：它只在真的点「已读」时才往前推。
        await refreshAnnouncements()
    }

    /// 只拉公告：对话页首的铃铛（spec #122 的公告位置改动）每次回到这一页都拉一次。
    /// 拉不到就保持上一次的——公告不是要紧的事，不报错。
    func refreshAnnouncements() async {
        guard isSignedIn, let client = client() else { return }
        if let latest = try? await client.announcements(since: 0) {
            announcements = latest.items
        }
    }

    func markAnnouncementsSeen() {
        let next = cursor.havingSeen(announcements)
        guard next != cursor else { return }
        cursor = next
        UserDefaults.standard.set(next.latestSeen, forKey: Self.announcementCursorKey)
    }

    /// 下完交给 `AppModel` 原来那三个导入入口之一。
    func download(_ package: ServerPackage, into app: AppModel) async {
        guard let client = client() else { return }
        errorMessage = nil
        downloading[package.id] = 0
        defer { downloading[package.id] = nil }
        do {
            let target = Self.downloadDirectory.appending(path: package.filename)
            let file = try await downloader.download(client, package: package, to: target) { written in
                Task { @MainActor in
                    // 下载已经结束以后才到的进度不要写回去，否则进度会永远停在半路。
                    guard self.downloading[package.id] != nil else { return }
                    self.downloading[package.id] = written
                }
            }
            switch package.kind {
            case "stand": await app.importStandBundle(from: file)
            case "bar": await app.importBarBundle(from: file)
            default: await app.importBundle(from: file)
            }
            InstalledPackages.remember(version: package.version, for: package.kind)
            // 导入已经把它解到内容目录里了，这份几百 MB 的原文件不用再留着。
            try? FileManager.default.removeItem(at: file)
        } catch {
            errorMessage = (error as? PackageDownloadError)?.text ?? error.localizedDescription
        }
    }

    static var downloadDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "Eidolon/downloads", directoryHint: .isDirectory)
    }

    // MARK: -

    private func perform(_ work: @MainActor () async throws -> Void) async {
        isWorking = true
        errorMessage = nil
        do {
            try await work()
        } catch let error as ServerError {
            errorMessage = error.text
            if error == .notLoggedIn { signOut() }
        } catch {
            errorMessage = error.localizedDescription
        }
        isWorking = false
    }
}

extension Int {
    /// 几百 MB 的文件按 MB 显示就够。
    var megabytes: String { "\(self / 1_048_576) MB" }
}
