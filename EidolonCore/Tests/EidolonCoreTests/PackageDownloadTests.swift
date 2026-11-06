import XCTest
@testable import EidolonCore

/// 下载的纯逻辑（spec #120）：续传要的 Range、下完的校验。
final class PackageDownloadTests: XCTestCase {
    func testResumingAsksForWhatIsStillMissing() {
        XCTAssertEqual(PackageDownload.rangeHeader(from: 1024), "bytes=1024-")
    }

    func testTheChecksumCoversTheWholeFile() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try Data("eidolon".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(
            try PackageDownload.sha256(of: url),
            "6f130cfc098f8676886efcfca70b510597913fb9e1adfa6b686a9d1efa92f010"
        )
    }

    func testADifferentFileHasADifferentChecksum() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try Data("ei dolon".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNotEqual(
            try PackageDownload.sha256(of: url),
            "6f130cfc098f8676886efcfca70b510597913fb9e1adfa6b686a9d1efa92f010"
        )
    }
}
