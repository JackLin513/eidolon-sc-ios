import Foundation

/// 服务器上的一个包（spec #120）：种类、版本、大小和校验值都由服务端登记时算好。
public struct ServerPackage: Codable, Sendable, Hashable, Identifiable {
    public var id: Int
    public var kind: String
    public var version: String
    public var filename: String
    public var size: Int
    public var sha256: String
    public var createdAt: String
    /// 1 表示这是这一类里当前的那一份。
    public var current: Int

    public init(
        id: Int,
        kind: String,
        version: String,
        filename: String,
        size: Int,
        sha256: String,
        createdAt: String,
        current: Int = 1
    ) {
        self.id = id
        self.kind = kind
        self.version = version
        self.filename = filename
        self.size = size
        self.sha256 = sha256
        self.createdAt = createdAt
        self.current = current
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, version, filename, size, sha256, current
        case createdAt = "created_at"
    }

    /// 「剧情」「立绘」「酒吧」这三类在界面上的说法；认不出的种类原样显示。
    public var kindName: String {
        switch kind {
        case "content": return "剧情"
        case "stand": return "立绘"
        case "bar": return "酒吧"
        default: return kind
        }
    }
}

public struct ServerAnnouncement: Codable, Sendable, Hashable, Identifiable {
    public var id: Int
    public var title: String
    public var body: String
    public var publishedAt: String

    public init(id: Int, title: String, body: String, publishedAt: String) {
        self.id = id
        self.title = title
        self.body = body
        self.publishedAt = publishedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, title, body
        case publishedAt = "published_at"
    }
}

/// 登录以后拿到的东西：令牌和它是谁。令牌本身存钥匙串，这里只带在请求里。
public struct ServerSession: Codable, Sendable, Hashable {
    public var username: String
    public var token: String
    public var role: String
    public var expiresAt: String

    public init(username: String, token: String, role: String, expiresAt: String) {
        self.username = username
        self.token = token
        self.role = role
        self.expiresAt = expiresAt
    }

    enum CodingKeys: String, CodingKey {
        case username, token, role
        case expiresAt = "expires_at"
    }

    /// 管理界面（#122）只给管理账号看。界面上藏不藏只是体验，服务端每个接口自己校验。
    public var isAdmin: Bool { role == "admin" }
}

/// 管理页里的一个账号（spec #122）。角色只能由服务器上的命令授予，这里只读。
public struct ServerUser: Codable, Sendable, Hashable, Identifiable {
    public var id: Int
    public var username: String
    public var role: String
    public var createdAt: String
    public var lastLoginAt: String?
    public var disabledAt: String?

    public init(
        id: Int,
        username: String,
        role: String,
        createdAt: String,
        lastLoginAt: String? = nil,
        disabledAt: String? = nil
    ) {
        self.id = id
        self.username = username
        self.role = role
        self.createdAt = createdAt
        self.lastLoginAt = lastLoginAt
        self.disabledAt = disabledAt
    }

    enum CodingKeys: String, CodingKey {
        case id, username, role
        case createdAt = "created_at"
        case lastLoginAt = "last_login_at"
        case disabledAt = "disabled_at"
    }

    public var isAdmin: Bool { role == "admin" }
    public var isDisabled: Bool { disabledAt != nil }
}

/// 一个邀请码（spec #122）：状态由服务端算好，界面照着说。
public struct ServerInvite: Codable, Sendable, Hashable, Identifiable {
    public var id: Int
    public var code: String
    public var createdAt: String
    public var expiresAt: String?
    public var usedAt: String?
    public var usedBy: String?
    public var state: String

    public init(
        id: Int,
        code: String,
        createdAt: String,
        expiresAt: String? = nil,
        usedAt: String? = nil,
        usedBy: String? = nil,
        state: String
    ) {
        self.id = id
        self.code = code
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.usedAt = usedAt
        self.usedBy = usedBy
        self.state = state
    }

    enum CodingKeys: String, CodingKey {
        case id, code, state
        case createdAt = "created_at"
        case expiresAt = "expires_at"
        case usedAt = "used_at"
        case usedBy = "used_by"
    }

    public var stateName: String {
        switch state {
        case "open": return "没用过"
        case "used": return usedBy.map { "已被 \($0) 用掉" } ?? "已用掉"
        case "expired": return "过期了"
        default: return state
        }
    }
}

/// 「管理」这一项该不该出现（spec #122）：登录了、而且服务端说这个账号是管理员。
/// 只是体验——每个管理接口都由服务端自己校验角色。
public enum ServerAdmin {
    public static func showsEntry(for session: ServerSession?) -> Bool {
        session?.isAdmin == true
    }
}

/// 服务端的失败。分成几类是因为界面上说法不一样，别的都不需要知道。
public enum ServerError: Error, Sendable, Equatable {
    /// 没有令牌，或者令牌过期了——要重新登录。
    case notLoggedIn
    case wrongCredentials
    case accountDisabled
    /// 这条接口不归普通账号用——角色的判断在服务端，界面跟着把「管理」收起来。
    case noPermission
    case refused(String)
    case tooManyAttempts
    case message(String)

    public var text: String {
        switch self {
        case .notLoggedIn: return "登录已过期，请重新登录"
        case .wrongCredentials: return "用户名或密码不对"
        case .accountDisabled: return "这个账号已经停用了"
        case .noPermission: return "这个账号没有管理权限"
        case let .refused(reason): return reason
        case .tooManyAttempts: return "试错的次数太多了，过一会儿再试"
        case let .message(text): return text
        }
    }
}

/// 那个私有服务的客户端（spec #120）：只做请求与解析，不碰文件、不碰界面。
public struct ServerClient: Sendable {
    public var baseURL: URL
    public var token: String?
    private let transport: any HTTPTransport

    public init(
        baseURL: URL,
        token: String? = nil,
        transport: any HTTPTransport = URLSessionHTTPTransport()
    ) {
        self.baseURL = baseURL
        self.token = token
        self.transport = transport
    }

    public func register(invite: String, username: String, password: String) async throws {
        let body: [String: String] = ["invite": invite, "username": username, "password": password]
        _ = try await send(
            path: "/v1/register", method: "POST", body: try encoded(body), authorized: false
        )
    }

    public func login(username: String, password: String) async throws -> ServerSession {
        let body: [String: String] = ["username": username, "password": password]
        let data = try await send(
            path: "/v1/login", method: "POST", body: try encoded(body), authorized: false
        )
        return try decoder.decode(ServerSession.self, from: data)
    }

    public func packages() async throws -> [ServerPackage] {
        let data = try await send(path: "/v1/packages", method: "GET")
        struct Response: Decodable { var packages: [ServerPackage] }
        return try decoder.decode(Response.self, from: data).packages
    }

    public func announcements(since: Int) async throws -> (items: [ServerAnnouncement], latest: Int) {
        let data = try await send(path: "/v1/announcements?since=\(since)", method: "GET")
        struct Response: Decodable {
            var announcements: [ServerAnnouncement]
            var latest: Int
        }
        let response = try decoder.decode(Response.self, from: data)
        return (response.announcements, response.latest)
    }

    // MARK: - 管理（spec #122）

    public func users() async throws -> [ServerUser] {
        let data = try await send(path: "/v1/admin/users", method: "GET")
        struct Response: Decodable { var users: [ServerUser] }
        return try decoder.decode(Response.self, from: data).users
    }

    public func setDisabled(_ disabled: Bool, userID: Int) async throws {
        let path = "/v1/admin/users/\(userID)/\(disabled ? "disable" : "enable")"
        _ = try await send(path: path, method: "POST")
    }

    public func setPassword(_ password: String, userID: Int) async throws {
        _ = try await send(
            path: "/v1/admin/users/\(userID)/password",
            method: "POST",
            body: try encoded(["password": password])
        )
    }

    public func deleteUser(id: Int) async throws {
        _ = try await send(path: "/v1/admin/users/\(id)", method: "DELETE")
    }

    public func invites() async throws -> [ServerInvite] {
        let data = try await send(path: "/v1/admin/invites", method: "GET")
        struct Response: Decodable { var invites: [ServerInvite] }
        return try decoder.decode(Response.self, from: data).invites
    }

    public func createInvite(days: Int = 7) async throws -> ServerInvite {
        let data = try await send(
            path: "/v1/admin/invites", method: "POST", body: try encoded(["days": days])
        )
        return try decoder.decode(ServerInvite.self, from: data)
    }

    public func revokeInvite(id: Int) async throws {
        _ = try await send(path: "/v1/admin/invites/\(id)", method: "DELETE")
    }

    public func publishAnnouncement(title: String, body: String) async throws {
        _ = try await send(
            path: "/v1/admin/announcements",
            method: "POST",
            body: try encoded(["title": title, "body": body])
        )
    }

    public func deleteAnnouncement(id: Int) async throws {
        _ = try await send(path: "/v1/admin/announcements/\(id)", method: "DELETE")
    }

    /// 登记包目录里新放进去的包——省掉服务器上那条命令。
    public func rescanPackages() async throws {
        _ = try await send(path: "/v1/admin/packages/rescan", method: "POST")
    }

    /// 下载地址。真正下载由 `PackageDownloader` 做：它要断点续传，不能把几百 MB 读进内存。
    public func downloadURL(packageID: Int) -> URL {
        baseURL.appending(path: "/v1/packages/\(packageID)/download")
    }

    public func authorizedRequest(for url: URL, range: String? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let range {
            request.setValue(range, forHTTPHeaderField: "Range")
        }
        return request
    }

    private var decoder: JSONDecoder { JSONDecoder() }

    private func encoded(_ value: some Encodable) throws -> Data {
        try JSONEncoder().encode(value)
    }

    private func send(
        path: String,
        method: String,
        body: Data? = nil,
        authorized: Bool = true
    ) async throws -> Data {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        if authorized {
            guard let token else { throw ServerError.notLoggedIn }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch {
            throw ServerError.message(error.localizedDescription)
        }
        try Self.check(response, data: data)
        return data
    }

    private static func check(_ response: HTTPURLResponse, data: Data) throws {
        switch response.statusCode {
        case 200..<300:
            return
        case 401:
            throw ServerError.notLoggedIn
        case 403:
            // 403 有两种：账号停用了，或者这条管理接口不是给普通账号的。
            if response.value(forHTTPHeaderField: "X-Eidolon-Reason") == "disabled" {
                throw ServerError.accountDisabled
            }
            throw ServerError.noPermission
        case 409:
            throw ServerError.refused(detail(of: data))
        case 429:
            throw ServerError.tooManyAttempts
        default:
            throw ServerError.message(detail(of: data))
        }
    }

    private static func detail(of data: Data) -> String {
        struct Failure: Decodable { var detail: String }
        if let failure = try? JSONDecoder().decode(Failure.self, from: data), !failure.detail.isEmpty {
            return failure.detail
        }
        return "服务器出了点问题"
    }
}
