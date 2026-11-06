import CryptoKit
import Foundation

/// 内容包的下载（spec #120）：边下边写文件，断了就从已经下到的位置接着下，
/// 下完对一遍 sha256 才交给导入。
public enum PackageDownload {
    /// 从已经下到的位置接着要。
    public static func rangeHeader(from offset: Int) -> String { "bytes=\(offset)-" }

    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 512 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

public enum PackageDownloadError: Error, Sendable, Equatable {
    case checksumMismatch
    case incomplete
    case failed(String)

    public var text: String {
        switch self {
        case .checksumMismatch: return "下载的文件和服务器上的对不上，请重来一次"
        case .incomplete: return "下载没有完成，可以接着下"
        case let .failed(reason): return reason
        }
    }
}

/// 一个包的下载。放在 Core 里是因为它只认「地址 + 令牌 + 落盘位置」，不知道界面是什么样；
/// 界面只订阅进度。
public actor PackageDownloader {
    private let session: URLSession
    private let attempts: Int

    public init(session: URLSession = .shared, attempts: Int = 3) {
        self.session = session
        self.attempts = attempts
    }

    /// - Parameters:
    ///   - target: 落盘的位置（已经存在时按续传处理）。
    ///   - progress: 已下字节数。
    public func download(
        _ client: ServerClient,
        package: ServerPackage,
        to target: URL,
        progress: @Sendable (Int) -> Void = { _ in }
    ) async throws -> URL {
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        if !FileManager.default.fileExists(atPath: target.path) {
            FileManager.default.createFile(atPath: target.path, contents: nil)
        }

        // 本地那份比服务器上的还大（换过包、或者上一次写坏了）：丢掉重下，
        // 否则续传会一直要一个越界的 Range。
        if Self.size(of: target) > package.size {
            try? FileManager.default.removeItem(at: target)
            FileManager.default.createFile(atPath: target.path, contents: nil)
        }
        var offset = Self.size(of: target)
        var lastError: Error?
        for _ in 0..<attempts {
            if package.size > 0, offset >= package.size { break }
            do {
                offset = try await fetch(
                    client, package: package, into: target, from: offset, progress: progress
                )
            } catch {
                lastError = error
                offset = Self.size(of: target)
            }
        }

        guard Self.size(of: target) == package.size else {
            throw lastError.map { PackageDownloadError.failed($0.localizedDescription) }
                ?? PackageDownloadError.incomplete
        }
        guard try PackageDownload.sha256(of: target) == package.sha256.lowercased() else {
            try? FileManager.default.removeItem(at: target)
            throw PackageDownloadError.checksumMismatch
        }
        return target
    }

    private static func size(of url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    }

    private func fetch(
        _ client: ServerClient,
        package: ServerPackage,
        into target: URL,
        from offset: Int,
        progress: @Sendable (Int) -> Void
    ) async throws -> Int {
        let request = client.authorizedRequest(
            for: client.downloadURL(packageID: package.id),
            range: offset > 0 ? PackageDownload.rangeHeader(from: offset) : nil
        )
        let (stream, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PackageDownloadError.failed("服务器没有回应")
        }
        if http.statusCode == 416 {
            // 服务端说 Range 越界：本地那份和服务器上的对不上，丢掉以后重下。
            try? FileManager.default.removeItem(at: target)
            FileManager.default.createFile(atPath: target.path, contents: nil)
            throw PackageDownloadError.incomplete
        }
        guard http.statusCode == 200 || http.statusCode == 206 else {
            throw PackageDownloadError.failed("服务器拒绝了这次下载（\(http.statusCode)）")
        }
        // 服务端不认续传时会把整个文件再发一次，那就从头写。
        let restart = http.statusCode == 200 && offset > 0

        let handle = try FileHandle(forWritingTo: target)
        defer { try? handle.close() }
        var written = offset
        if restart {
            try handle.truncate(atOffset: 0)
            written = 0
        }
        try handle.seekToEnd()

        var buffer = Data()
        buffer.reserveCapacity(256 * 1024)
        // 进度按 MB 报：几百 MB 的文件不该每 256 KB 就往界面回一次。
        var reported = offset
        for try await byte in stream {
            buffer.append(byte)
            if buffer.count >= 256 * 1024 {
                try handle.write(contentsOf: buffer)
                written += buffer.count
                buffer.removeAll(keepingCapacity: true)
                if written - reported >= 1_048_576 {
                    reported = written
                    progress(written)
                }
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            written += buffer.count
        }
        progress(written)
        return written
    }
}
