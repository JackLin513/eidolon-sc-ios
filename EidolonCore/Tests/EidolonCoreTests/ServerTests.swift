import XCTest
@testable import EidolonCore

/// 私有服务的客户端（spec #120）：只测请求长什么样、错误怎么分辨。
final class ServerTests: XCTestCase {
    private let base = URL(string: "https://server.example")!

    private func reply(_ status: Int, _ json: String) -> @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse) {
        { request in
            (
                Data(json.utf8),
                HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            )
        }
    }

    func testLoginPutsTheCredentialsInTheBody() async throws {
        let transport = StubHTTPTransport(
            reply(200, #"{"username":"jack","token":"t0ken","role":"admin","expires_at":"2027-05-06T00:00:00+00:00"}"#)
        )
        let client = ServerClient(baseURL: base, transport: transport)
        let session = try await client.login(username: "jack", password: "hunter22")

        XCTAssertEqual(session.username, "jack")
        XCTAssertEqual(session.token, "t0ken")
        XCTAssertTrue(session.isAdmin)

        let seen = await transport.seen
        let request = try XCTUnwrap(seen.first)
        XCTAssertEqual(request.url?.path, "/v1/login")
        XCTAssertEqual(request.httpMethod, "POST")
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(json["username"], "jack")
        XCTAssertEqual(json["password"], "hunter22")
    }

    func testThePackageListCarriesTheToken() async throws {
        let transport = StubHTTPTransport(
            reply(200, #"{"packages":[{"id":3,"kind":"stand","version":"2026-11-06","filename":"a.eidolonpkg","size":586857765,"sha256":"ab","created_at":"2026-11-06T00:00:00+00:00","current":1}]}"#)
        )
        let client = ServerClient(baseURL: base, token: "t0ken", transport: transport)
        let packages = try await client.packages()

        XCTAssertEqual(packages.first?.kindName, "立绘")
        XCTAssertEqual(packages.first?.size, 586_857_765)
        let seen = await transport.seen
        let request = try XCTUnwrap(seen.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer t0ken")
    }

    func testAnExpiredTokenAsksForANewLogin() async throws {
        let transport = StubHTTPTransport(reply(401, #"{"detail":"登录已过期，请重新登录"}"#))
        let client = ServerClient(baseURL: base, token: "old", transport: transport)
        await XCTAssertThrowsErrorAsync(try await client.packages()) { error in
            XCTAssertEqual(error as? ServerError, .notLoggedIn)
        }
    }

    func testAUsedInviteSaysWhatTheServerSaid() async throws {
        let transport = StubHTTPTransport(reply(409, #"{"detail":"邀请码已经被用过了"}"#))
        let client = ServerClient(baseURL: base, transport: transport)
        await XCTAssertThrowsErrorAsync(
            try await client.register(invite: "ABCD", username: "jack", password: "hunter22")
        ) { error in
            XCTAssertEqual(error as? ServerError, .refused("邀请码已经被用过了"))
        }
    }

    func testTooManyAttemptsIsToldApartFromAWrongPassword() async throws {
        let transport = StubHTTPTransport(reply(429, #"{"detail":"试错的次数太多了，过一会儿再试"}"#))
        let client = ServerClient(baseURL: base, transport: transport)
        await XCTAssertThrowsErrorAsync(try await client.login(username: "jack", password: "x")) { error in
            XCTAssertEqual(error as? ServerError, .tooManyAttempts)
        }
    }

    func testADownloadCarriesTheRangeAndTheToken() {
        let client = ServerClient(baseURL: base, token: "t0ken")
        let request = client.authorizedRequest(for: client.downloadURL(packageID: 7), range: "bytes=1024-")
        XCTAssertEqual(request.url?.path, "/v1/packages/7/download")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "bytes=1024-")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer t0ken")
    }

    func testARefusedRangeIsNotSilentlyTreatedAsTheWholeFile() async throws {
        let transport = StubHTTPTransport(reply(416, #"{"detail":"Range 超出文件"}"#))
        let client = ServerClient(baseURL: base, token: "t0ken", transport: transport)
        await XCTAssertThrowsErrorAsync(try await client.packages()) { error in
            XCTAssertEqual(error as? ServerError, .message("Range 超出文件"))
        }
    }

    // MARK: - 管理（spec #122）

    private func reply(
        _ status: Int, _ json: String, reason: String?
    ) -> @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse) {
        { request in
            (
                Data(json.utf8),
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: status,
                    httpVersion: nil,
                    headerFields: reason.map { ["X-Eidolon-Reason": $0] }
                )!
            )
        }
    }

    func testASettingAPasswordCarriesTheTokenAndTheNewPassword() async throws {
        let transport = StubHTTPTransport(reply(200, #"{"ok":true}"#))
        let client = ServerClient(baseURL: base, token: "t0ken", transport: transport)
        try await client.setPassword("brand-new-one", userID: 4)

        let seen = await transport.seen
        let request = try XCTUnwrap(seen.first)
        XCTAssertEqual(request.url?.path, "/v1/admin/users/4/password")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer t0ken")
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(json["password"], "brand-new-one")
    }

    func testDisablingAndDeletingGoToTheirOwnPaths() async throws {
        let transport = StubHTTPTransport(reply(200, #"{"ok":true}"#))
        let client = ServerClient(baseURL: base, token: "t0ken", transport: transport)
        try await client.setDisabled(true, userID: 4)
        try await client.setDisabled(false, userID: 4)
        try await client.deleteUser(id: 4)
        try await client.rescanPackages()

        let paths = await transport.seen.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" }
        XCTAssertEqual(paths, [
            "POST /v1/admin/users/4/disable",
            "POST /v1/admin/users/4/enable",
            "DELETE /v1/admin/users/4",
            "POST /v1/admin/packages/rescan",
        ])
    }

    func testAnInviteComesBackWithItsState() async throws {
        let transport = StubHTTPTransport(reply(200, #"""
        {"id":9,"code":"ABCDEFGHJK","created_at":"2026-11-06T00:00:00+00:00",
         "expires_at":"2026-11-13T00:00:00+00:00","used_at":null,"used_by":null,"state":"open"}
        """#))
        let client = ServerClient(baseURL: base, token: "t0ken", transport: transport)
        let invite = try await client.createInvite()

        XCTAssertEqual(invite.code, "ABCDEFGHJK")
        XCTAssertEqual(invite.stateName, "没用过")
        let seen = await transport.seen
        let request = try XCTUnwrap(seen.first)
        XCTAssertEqual(request.url?.path, "/v1/admin/invites")
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Int])
        XCTAssertEqual(json["days"], 7)
    }

    func testAnAdminPathRefusedIsNotADisabledAccount() async throws {
        let transport = StubHTTPTransport(
            reply(403, #"{"detail":"这个账号没有管理权限"}"#, reason: "forbidden")
        )
        let client = ServerClient(baseURL: base, token: "t0ken", transport: transport)
        await XCTAssertThrowsErrorAsync(try await client.users()) { error in
            XCTAssertEqual(error as? ServerError, .noPermission)
        }
    }

    func testADisabledAccountStillReadsAsDisabled() async throws {
        let transport = StubHTTPTransport(
            reply(403, #"{"detail":"这个账号已经停用了"}"#, reason: "disabled")
        )
        let client = ServerClient(baseURL: base, token: "t0ken", transport: transport)
        await XCTAssertThrowsErrorAsync(try await client.users()) { error in
            XCTAssertEqual(error as? ServerError, .accountDisabled)
        }
    }

    func testTheAdminEntryOnlyShowsForAnAdmin() {
        XCTAssertFalse(ServerAdmin.showsEntry(for: nil))
        XCTAssertFalse(ServerAdmin.showsEntry(
            for: ServerSession(username: "alice", token: "t", role: "user", expiresAt: "")
        ))
        XCTAssertTrue(ServerAdmin.showsEntry(
            for: ServerSession(username: "jack", token: "t", role: "admin", expiresAt: "")
        ))
    }
}

/// 仓库里还没有 async 的断言辅助，这里补一个最小的。
func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ handler: (any Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("应当抛错但没抛", file: file, line: line)
    } catch {
        handler(error)
    }
}
