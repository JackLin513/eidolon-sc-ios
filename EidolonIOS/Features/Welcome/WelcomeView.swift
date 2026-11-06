import SwiftUI
import WebKit

/// 欢迎页（spec #118）：整页是随 App 打包的上游落地面（时间线、光、棱镜、来电都是它的），
/// 原生只剩右上角的「跳过」和页面回调过来的 finish。页面起不来时是黑底、App 名和「进入」。
struct WelcomeView: View {
    var onFinish: () -> Void

    @State private var failed = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            if WelcomeBundle.missingAssets.isEmpty, !failed, let url = WelcomeBundle.pageURL {
                WelcomeWebView(url: url, onFinish: onFinish) { failed = true }
                    .ignoresSafeArea()
            } else {
                fallback
            }

            skip
        }
        .statusBarHidden()
    }

    /// 网页卡住也能走：这一页永远有出路。
    private var skip: some View {
        Button("跳过", action: onFinish)
            .font(.footnote)
            .foregroundStyle(.white.opacity(0.82))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.black.opacity(0.35), in: Capsule())
            .padding(.top, 8)
            .padding(.trailing, 16)
            .accessibilityIdentifier("welcome.skip")
    }

    /// 兜底：不为此再维护一套原生画面（spec #118）。
    private var fallback: some View {
        VStack(spacing: 28) {
            Spacer()
            Text("Eidolon")
                .font(.system(size: 26, weight: .semibold, design: .serif))
                .tracking(10)
                .foregroundStyle(.white.opacity(0.9))
            Button("进入", action: onFinish)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.82))
                .padding(.horizontal, 22)
                .padding(.vertical, 10)
                .overlay(Capsule().stroke(.white.opacity(0.3)))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("welcome.fallback")
    }
}

/// 承载网页，并守住它的两条规矩：不导航、不开新窗口；只看 `eidolon-welcome` 这一种地址。
private struct WelcomeWebView: UIViewRepresentable {
    let url: URL
    let onFinish: () -> Void
    let onFailure: () -> Void

    /// 把 `console.*`、未捕获的异常和未处理的 Promise 拒绝都转给 App。
    private static let consoleBridge = """
    (function () {
      function send(level, parts) {
        try {
          window.webkit.messageHandlers.log.postMessage(level + " " + parts.map(String).join(" "));
        } catch (error) {}
      }
      ["log", "warn", "error"].forEach(function (level) {
        var original = console[level];
        console[level] = function () {
          send(level, Array.prototype.slice.call(arguments));
          original.apply(console, arguments);
        };
      });
      window.addEventListener("error", function (event) { send("error", [event.message]); });
      window.addEventListener("unhandledrejection", function (event) {
        send("error", ["unhandled " + String(event.reason)]);
      });
    })();
    """

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish, onFailure: onFailure)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(
            WelcomeSchemeHandler(pageRoot: WelcomeBundle.pageRoot, mediaRoot: WelcomeBundle.mediaRoot),
            forURLScheme: WelcomeSchemeHandler.scheme
        )
        configuration.userContentController.add(context.coordinator, name: "welcome")
        // 网页的 console 接到 stdout：`devicectl device process launch --console` 能直接看到，
        // 不再只能靠页面上的绿字。
        configuration.userContentController.add(context.coordinator, name: "log")
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: Self.consoleBridge,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.allowsInlineMediaPlayback = true
        // 这一页是本地打包的，声音由页面自己在上一个手势之后接着播（接听后的开场白、
        // 点偶像的招呼）。默认策略会把它们当成「没有手势的自动播放」挡成 NotAllowedError，
        // 这里对这个 scheme 的页面全部放开。
        configuration.mediaTypesRequiringUserActionForPlayback = []

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "welcome")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "log")
        webView.stopLoading()
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
        private let onFinish: () -> Void
        private let onFailure: () -> Void

        init(onFinish: @escaping () -> Void, onFailure: @escaping () -> Void) {
            self.onFinish = onFinish
            self.onFailure = onFailure
        }

        func userContentController(
            _ controller: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            if message.name == "log" {
                print("[welcome] \(message.body)")
                return
            }
            guard message.name == "welcome",
                  let body = message.body as? [String: Any],
                  body["action"] as? String == "finish"
            else { return }
            onFinish()
        }

        /// 这一页不导航去别处，也不开新窗口（spec #118）。
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            navigationAction.request.url?.scheme == WelcomeSchemeHandler.scheme ? .allow : .cancel
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            nil
        }

        /// 页面起不来（资源丢了、WebContent 崩了）：交给兜底画面。
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
            onFailure()
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
            onFailure()
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            onFailure()
        }
    }
}
