import EidolonCore
import Foundation
import WebKit

/// Serves the stand's local page and her outfit files to its `WKWebView` (ADR-0017).
///
/// A custom scheme instead of `file://`, because `fetch` and XHR under `file://` are
/// blocked by CORS. The page, the player and the runtime come from the app bundle,
/// everything else from the installed content bundle's `stand/` tree, and nothing else:
///
///     eidolon-stand://app/stand.html
///     eidolon-stand://app/stand-player.js
///     eidolon-stand://app/spine-webgl.js
///     eidolon-stand://content/stand/idols/stand/1030010010/data.json
///
/// The page and her files are different hosts of this scheme, so every response carries
/// CORS headers. Paths that leave the content bundle (parent traversal, or a symlink out
/// of it) are refused.
final class StandSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "eidolon-stand"

    private static let pageHost = "app"
    private static let contentHost = "content"
    /// What the page may load from the app bundle: no more than these three files.
    private static let pageFiles: [String: String] = [
        "/stand.html": "text/html; charset=utf-8",
        "/stand-player.js": "text/javascript; charset=utf-8",
        "/spine-webgl.js": "text/javascript; charset=utf-8",
    ]

    private let pageRoot: URL
    private let contentRoot: URL

    init(pageRoot: URL, contentRoot: URL) {
        self.pageRoot = pageRoot
        self.contentRoot = contentRoot
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            respond(url: nil, status: 400, contentType: "text/plain; charset=utf-8", data: Data(), to: urlSchemeTask)
            return
        }
        let (status, contentType, data) = read(url)
        respond(url: url, status: status, contentType: contentType, data: data, to: urlSchemeTask)
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        // Every request is answered inside `start`; there is nothing to cancel.
    }

    private func read(_ url: URL) -> (Int, String, Data) {
        switch url.host {
        case Self.pageHost:
            guard let contentType = Self.pageFiles[url.path] else { return notFound() }
            let file = pageRoot.appendingPathComponent(String(url.path.dropFirst()))
            guard let data = try? Data(contentsOf: file) else { return notFound() }
            return (200, contentType, data)
        case Self.contentHost:
            guard url.path.hasPrefix("/stand/"),
                  let file = StandAssets.file(at: url.path, under: contentRoot),
                  let data = try? Data(contentsOf: file)
            else { return notFound() }
            return (200, Self.contentType(for: file.pathExtension), data)
        default:
            return notFound()
        }
    }

    private func notFound() -> (Int, String, Data) {
        (404, "text/plain; charset=utf-8", Data())
    }

    private static func contentType(for pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "json": "application/json; charset=utf-8"
        case "png": "image/png"
        case "atlas": "text/plain; charset=utf-8"
        default: "application/octet-stream"
        }
    }

    private func respond(
        url: URL?,
        status: Int,
        contentType: String,
        data: Data,
        to task: any WKURLSchemeTask
    ) {
        let headers = [
            "Content-Type": contentType,
            "Content-Length": String(data.count),
            "Access-Control-Allow-Origin": "*",
            "Cache-Control": "no-store",
        ]
        guard let url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: status,
                  httpVersion: "HTTP/1.1",
                  headerFields: headers
              )
        else {
            task.didFailWithError(URLError(.badURL))
            return
        }
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }
}
