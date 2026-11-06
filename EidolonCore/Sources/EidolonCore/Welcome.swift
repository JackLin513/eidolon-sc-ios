import Foundation

/// 这一次启动要不要放欢迎页（spec #118）。
///
/// 没有内容包时永远先给——那一页的第 7 幕就是导入入口，第一印象不该是一个空壳；
/// 有内容包时只在没看过的时候给一次，之后靠设置里的「重新观看欢迎页」再放。
public enum WelcomeLaunch {
    public static func shouldPresent(seen: Bool, hasContentBundle: Bool) -> Bool {
        !seen || !hasContentBundle
    }
}

/// 欢迎页要用的几样东西（spec #118）。
public enum WelcomeAsset: String, Sendable, CaseIterable {
    /// 页面构建产物（`WelcomePage/index.html`）
    case page
    /// 名册（`Welcome/welcome.json`）
    case roster
    /// 名册里点名的招呼语音
    case greetings
}

/// 素材齐不齐的纯判断：缺任何一样就退回兜底画面，而不是让网页白屏。
public enum WelcomeAssetCheck {
    public static func missing(page: Bool, roster: Bool, greetings: Bool) -> [WelcomeAsset] {
        var missing: [WelcomeAsset] = []
        if !page { missing.append(.page) }
        if !roster { missing.append(.roster) }
        if !greetings { missing.append(.greetings) }
        return missing
    }
}
