import EidolonCore
import Foundation

/// 欢迎页在用 App bundle 里的哪几个东西（spec #118），以及它们齐不齐。
/// 页面和素材都是以目录形式整块进包的（project.yml 里的 folder reference），路径和 scheme 对得上。
enum WelcomeBundle {
    static var root: URL { Bundle.main.resourceURL ?? Bundle.main.bundleURL }
    static var pageRoot: URL { root.appending(path: "WelcomePage", directoryHint: .isDirectory) }
    static var mediaRoot: URL { root.appending(path: "Welcome", directoryHint: .isDirectory) }

    /// 页面的地址。低电量模式直接要静态档——页面自己认 `?tier=`，不画 8 屏的滚动动画。
    static var pageURL: URL? {
        guard FileManager.default.fileExists(atPath: pageRoot.appending(path: "index.html").path),
              var components = URLComponents(
                  string: "\(WelcomeSchemeHandler.scheme)://\(WelcomeSchemeHandler.pageHost)/index.html"
              )
        else { return nil }
        if ProcessInfo.processInfo.isLowPowerModeEnabled {
            components.queryItems = [URLQueryItem(name: "tier", value: "static")]
        }
        return components.url
    }

    /// 缺哪几样素材。缺东西时欢迎页直接走兜底画面，不让网页白屏。
    static var missingAssets: [WelcomeAsset] {
        let manager = FileManager.default
        let page = manager.fileExists(atPath: pageRoot.appending(path: "index.html").path)
        let roster = manager.fileExists(atPath: mediaRoot.appending(path: "welcome.json").path)
        let greetings = (try? manager.contentsOfDirectory(
            atPath: mediaRoot.appending(path: "greetings").path
        ))?.contains { $0.hasSuffix(".mp3") } ?? false
        return WelcomeAssetCheck.missing(page: page, roster: roster, greetings: greetings)
    }
}

/// 设置里「重新观看欢迎页」用的一条通知：RootView 收到就把整页再放一次。
enum WelcomeNotifications {
    static let replay = Notification.Name("welcome.replay")
}
