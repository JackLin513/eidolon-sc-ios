import Foundation
import WebKit

/// 把随 App 打包的歡迎頁和它的素材交给 `WKWebView`（spec #118，沿用 ADR-0017 的做法）。
///
/// 页面里 `fetch` 和相对路径在 `file://` 下会被 CORS 挡住，所以走自定义 scheme，两个 host：
///
///     eidolon-welcome://app/index.html           → WelcomePage/
///     eidolon-welcome://app/assets/…              → WelcomePage/assets/…
///     eidolon-welcome://media/welcome.json         → Welcome/welcome.json
///     eidolon-welcome://media/greetings/….mp3      → Welcome/greetings/…
///
/// 只在这个 scheme 里取东西，不联网；越出两个目录的路径（`..`、软链）一律 404。
final class WelcomeSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "eidolon-welcome"
    static let pageHost = "app"
    static let mediaHost = "media"

    private let pageRoot: URL
    private let mediaRoot: URL

    init(pageRoot: URL, mediaRoot: URL) {
        self.pageRoot = pageRoot
        self.mediaRoot = mediaRoot
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
        // 每个请求都在 `start` 里当场答完，没有要取消的东西。
    }

    private func read(_ url: URL) -> (Int, String, Data) {
        let root: URL
        switch url.host {
        case Self.pageHost: root = pageRoot
        case Self.mediaHost: root = mediaRoot
        default: return notFound()
        }
        let relative = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
        guard !relative.isEmpty, !relative.contains("..") else { return notFound() }
        let file = root.appending(path: relative).standardizedFileURL
        guard file.path.hasPrefix(root.standardizedFileURL.path + "/"),
              let data = try? Data(contentsOf: file)
        else { return notFound() }
        return (200, Self.contentType(for: file.pathExtension), data)
    }

    private func notFound() -> (Int, String, Data) {
        (404, "text/plain; charset=utf-8", Data())
    }

    private static func contentType(for pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "html": "text/html; charset=utf-8"
        case "js", "mjs": "text/javascript; charset=utf-8"
        case "css": "text/css; charset=utf-8"
        case "json": "application/json; charset=utf-8"
        case "svg": "image/svg+xml"
        case "png": "image/png"
        case "webp": "image/webp"
        case "jpg", "jpeg": "image/jpeg"
        case "woff2": "font/woff2"
        case "mp3": "audio/mpeg"
        case "ogg": "audio/ogg"
        case "m4a": "audio/mp4"
        case "gltf": "model/gltf+json"
        case "bin": "application/octet-stream"
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
