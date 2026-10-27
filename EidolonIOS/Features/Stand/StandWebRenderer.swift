import EidolonCore
import os
import UIKit
import WebKit

/// The iOS stand: a transparent, non-interactive `WKWebView` running the local page
/// (ADR-0017). It only carries messages — Swift decides the pose and the camera, the page
/// plays them — so the interface layer never sees WebKit.
@MainActor
final class StandWebRenderer: NSObject, StandRenderer {
    let view: UIView

    var onLoaded: ((StandPose.Report) -> Void)?
    var onFailure: ((StandRenderFailure) -> Void)?

    private static let log = Logger(subsystem: "com.jacklin.eidolon", category: "stand")
    private static let messageName = "stand"

    private let contentRoot: URL
    private let framing: StandFraming
    private let webView: WKWebView
    private let proxy = MessageProxy()

    private var pose = StandPose.calm
    private var viewportSize = CGSize.zero
    private var bounds: StandBounds?
    private var ready = false
    private var failed = false
    private var queued: [String] = []

    /// - Parameters:
    ///   - contentRoot: the installed content bundle's directory; her outfits are read
    ///     from `stand/` under it and nowhere else.
    ///   - framing: how much of her to show at the view's size (spec「渲染」).
    init(contentRoot: URL, framing: StandFraming) {
        self.contentRoot = contentRoot
        self.framing = framing
        let pageRoot = Bundle.main.resourceURL ?? Bundle.main.bundleURL
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(
            StandSchemeHandler(pageRoot: pageRoot, contentRoot: contentRoot),
            forURLScheme: StandSchemeHandler.scheme
        )
        // Nothing about her is stored: every call starts from a fresh page.
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        // Transparent, still and untouchable: the subtitle card and the buttons above it
        // keep every touch.
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.pinchGestureRecognizer?.isEnabled = false
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsLinkPreview = false
        webView.isUserInteractionEnabled = false
        self.webView = webView
        self.view = webView

        super.init()

        webView.navigationDelegate = self
        webView.uiDelegate = self
        proxy.renderer = self
        webView.configuration.userContentController.add(proxy, name: Self.messageName)

        var components = URLComponents()
        components.scheme = StandSchemeHandler.scheme
        components.host = "app"
        components.path = "/stand.html"
        if let page = components.url {
            webView.load(URLRequest(url: page))
        } else {
            fail(.page("立绘页面地址拼不出来"))
        }
        sendPose()
    }

    // MARK: - StandRenderer

    func load(_ outfit: StandOutfit) {
        guard let relative = StandAssets.relativeDirectory(of: outfit.directory, under: contentRoot) else {
            fail(.outfit("衣装 \(outfit.id) 不在内容包里"))
            return
        }
        let path = relative.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? relative
        send(["type": "load", "url": "\(StandSchemeHandler.scheme)://content/\(path)", "id": outfit.id])
    }

    func direct(_ pose: StandPose) {
        self.pose = pose
        sendPose()
    }

    func setPaused(_ paused: Bool) {
        send(["type": "paused", "paused": paused])
    }

    func setViewportSize(_ size: CGSize) {
        guard size != viewportSize else { return }
        viewportSize = size
        sendCamera()
    }

    /// A picture of the page as it is drawn now: the outfit preview's thumbnails are made
    /// with it (spec「通话页」). nil when the page cannot draw.
    func snapshot() async -> UIImage? {
        guard !failed else { return nil }
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = true
        return await withCheckedContinuation { continuation in
            webView.takeSnapshot(with: configuration) { image, error in
                if let error {
                    Self.log.error(
                        "立绘截图失败：\(error.localizedDescription, privacy: .public)"
                    )
                }
                continuation.resume(returning: image)
            }
        }
    }

    // MARK: - Messages from the page

    fileprivate func received(_ body: Any) {
        guard !failed,
              JSONSerialization.isValidJSONObject(body),
              let data = try? JSONSerialization.data(withJSONObject: body),
              let message = try? JSONDecoder().decode(PlayerMessage.self, from: data)
        else { return }

        switch message.type {
        case "ready":
            ready = true
            flush()
        case "unavailable":
            fail(.runtime(message.reason ?? "Spine 运行时不可用"))
        case "loaded":
            guard let animations = message.animations, let bounds = message.bounds else {
                fail(.outfit("立绘加载完成的回报读不出"))
                return
            }
            self.bounds = bounds
            onLoaded?(StandPose.Report(animations: animations, bounds: bounds))
            sendCamera()
        case "failed":
            fail(.outfit(message.message ?? "立绘素材读不出"))
        case "context-lost":
            Self.log.info("立绘画布的 WebGL 上下文丢失，等运行时恢复")
        case "context-restored":
            Self.log.info("立绘画布的 WebGL 上下文已恢复")
        default:
            break
        }
    }

    // MARK: - Talking to the page

    private func sendPose() {
        guard let object = jsonObject(pose) else { return }
        send(["type": "pose", "pose": object])
    }

    private func sendCamera() {
        guard let bounds, viewportSize.width > 0, viewportSize.height > 0 else { return }
        let camera = framing.camera(
            bounds: bounds,
            aspect: Double(viewportSize.width / viewportSize.height)
        )
        guard let object = jsonObject(camera) else { return }
        send(["type": "camera", "camera": object])
    }

    private func send(_ command: [String: Any]) {
        guard !failed else { return }
        guard let data = try? JSONSerialization.data(
            withJSONObject: command,
            options: [.withoutEscapingSlashes]
        ), let json = String(data: data, encoding: .utf8) else { return }
        guard ready else {
            queued.append(json)
            return
        }
        evaluate(json)
    }

    private func flush() {
        let pending = queued
        queued.removeAll()
        for json in pending { evaluate(json) }
    }

    private func evaluate(_ json: String) {
        webView.evaluateJavaScript("standPlayer.receive(\(json));") { [weak self] _, error in
            guard let error else { return }
            Task { @MainActor in
                self?.fail(.page("立绘页面没有响应：\(error.localizedDescription)"))
            }
        }
    }

    private func jsonObject<T: Encodable>(_ value: T) -> Any? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private func fail(_ failure: StandRenderFailure) {
        guard !failed else { return }
        failed = true
        queued.removeAll()
        Self.log.error("立绘不可用：\(String(describing: failure), privacy: .public)")
        onFailure?(failure)
    }

    private struct PlayerMessage: Decodable {
        var type: String
        var reason: String?
        var message: String?
        var animations: [String: Double]?
        var bounds: StandBounds?
    }
}

// MARK: - WKNavigationDelegate

extension StandWebRenderer: WKNavigationDelegate {
    /// The only page she may navigate to is the one local page; links, redirects and
    /// anything that would reach the network are refused.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        let url = navigationAction.request.url
        let allowed = url?.scheme == StandSchemeHandler.scheme
            && url?.host == "app"
            && url?.path == "/stand.html"
        decisionHandler(allowed ? .allow : .cancel)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        fail(.page(error.localizedDescription))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        fail(.page(error.localizedDescription))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        fail(.page("立绘网页进程结束了"))
    }
}

// MARK: - WKUIDelegate

extension StandWebRenderer: WKUIDelegate {
    /// No popups: the page never opens another window.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        nil
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        completionHandler()
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(false)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (String?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// Keeps the content controller from retaining the renderer (the controller is retained
/// by the web view, which the renderer owns): the page talks to the renderer weakly.
@MainActor
private final class MessageProxy: NSObject, WKScriptMessageHandler {
    weak var renderer: StandWebRenderer?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        renderer?.received(message.body)
    }
}
