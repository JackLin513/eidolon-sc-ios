import Foundation

/// The iPad settings sidebar. The compact phone keeps the one long form; regular width
/// shows one category at a time, which is the system Settings shape and keeps the list
/// from turning into a 700pt-wide ribbon.
enum SettingsCategory: String, CaseIterable, Identifiable {
    case server
    case api
    case moments
    case stats
    case conversation
    case producer
    case memories
    case look
    case content
    case diagnostics

    var id: String { rawValue }

    var title: String {
        switch self {
        case .server: "服务器"
        case .api: "API 与模型"
        case .moments: "朋友圈"
        case .stats: "统计"
        case .conversation: "对话与通话"
        case .producer: "制作人"
        case .memories: "记忆"
        case .look: "立绘与素材"
        case .content: "内容包"
        case .diagnostics: "诊断"
        }
    }

    var symbol: String {
        switch self {
        case .server: "server.rack"
        case .api: "key.horizontal"
        case .moments: "person.2"
        case .stats: "chart.bar"
        case .conversation: "bubble.left.and.bubble.right"
        case .producer: "person.text.rectangle"
        case .memories: "brain"
        case .look: "sparkles"
        case .content: "shippingbox"
        case .diagnostics: "stethoscope"
        }
    }
}
