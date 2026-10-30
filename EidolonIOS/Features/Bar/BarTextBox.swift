import EidolonCore
import Combine
import SwiftUI
import UIKit

/// The bar's copy (upstream `copy.bar`): what the screen's words say, as the original has them.
enum BarCopy {
    static let tv = "换台"
    static let leave = "离开"
    static let portrait = "请横过来"
    static let next = "继续"
    static let producer = "制作人"
    static let skip = "跳过"
    static let retry = "再试一次"
    static let visitGone = "这次光顾已经结束了"
    /// The visit was left in the background for more than 30 minutes (ADR-0021), so it is over.
    static let awayGone = "离开太久了，这一趟已经结束。"

    enum Screen {
        static let full = "全屏"
        static let window = "窗口"
    }

    enum Settings {
        static let name = "设置"
        static let close = "关上设置"
        static let music = "背景音乐"
        static let sfx = "音效"
        static func quieter(_ what: String) -> String { "\(what)调小" }
        static func louder(_ what: String) -> String { "\(what)调大" }
        static func volume(_ what: String, _ percent: Int) -> String { "\(what)音量，\(percent)%" }
        static let scanlines = "扫描线"
    }

    enum Jukebox {
        static let name = "点唱机"
        static let title = "请选择一首曲子"
        static let add = "点击左侧的曲名来添加曲目。"
        static let howToFine = "悬停在曲名上试听，右键点击右侧曲目移除，点两首曲目可替换顺序。"
        static let howToCoarse = "长按左侧曲名试听，长按右侧曲目移除，点两首曲目可替换顺序。"
        static func slot(_ n: Int, _ title: String?) -> String {
            title == nil ? "第 \(n) 首，空" : "第 \(n) 首，\(title ?? "")"
        }
        static let prevPage = "上一页"
        static let nextPage = "下一页"
        static let ready = "Ready!"
        enum Player {
            static let previous = "上一首"
            static let pause = "暂停"
            static let play = "播放"
            static let next = "下一首"
            static let shuffle = "随机"
            static let loop = "单曲循环"
        }
    }

    enum Door {
        static let enter = "点一下进门"
        static let tutorial = "教程"
        static let failed = "没能进门，再点一下试试"
    }

    enum Counter {
        static let ice = "加冰"
        static let aged = "陈化"
        static let reset = "重做"
        static let mix = "调制"
        static let stop = "停止"
        static let serve = "上酒"
        /// 摇酒器 itself, for a screen reader (and for the UI test that drops into it).
        static let shaker = "摇酒器"
        static func parts(_ name: String, _ n: Int) -> String { "\(name)，\(n) 份" }
    }

    enum Book {
        enum Tabs {
            static let name = "按名称"
            static let flavor = "按口味"
            static let kind = "按种类"
            static let bottle = "瓶装饮品"
        }
        enum Search {
            static let name = "按名称搜索"
            static let flavor = "按口味搜索"
            static let kind = "按种类搜索"
            static let bottle = "瓶装饮品"
        }
        static let flavors: [String: String] = ["sweet": "甜味", "bitter": "苦味", "sour": "酸味", "spicy": "辛辣", "bubbly": "发泡"]
        static let kinds: [String: String] = ["girly": "女性化", "manly": "男性化", "classic": "经典", "classy": "时尚", "promo": "宣传"]
        static func category(_ name: String) -> String { "\(name)饮品" }
        static let prev = "上一页"
        static let next = "下一页"
        static func bottle(_ name: String) -> String { "\(name)，拖进摇酒器" }
    }

    enum End {
        static let heart = "♥ "
        static let affinityUp = "好感度上升"
        static func left(_ name: String?) -> String { "\(name ?? "她")走了" }
        static let again = "再营业"
    }

    /// 「这一小时的光顾次数用完了，HH:MM 以后再来」.
    static func overLimit(_ time: String) -> String { "这一小时的光顾次数用完了，\(time) 以后再来" }

    static func tabName(_ tab: BarRecipeBook.Tab) -> String {
        switch tab {
        case .name: Book.Tabs.name
        case .flavor: Book.Tabs.flavor
        case .kind: Book.Tabs.kind
        case .bottle: Book.Tabs.bottle
        }
    }
}

/// The text box under the guest's window (upstream `BarTextBox.tsx`): a page of a line, her
/// name in her colour and the producer's in his, the body white and her Chinese subtitle grey;
/// the arrow hopping at its lower right once it is typed out. A memo takes its place while
/// mixing; a failure takes it with 「再试一次」.
struct BarTextBox: View {
    @Environment(\.barImages) private var images
    let text: BarTextPage?
    /// Whose line the page is, for the name's colour.
    let speaker: BarLine.Speaker
    let herColor: Color
    let isArrowShown: Bool
    let memo: String?
    let failure: (message: String, isRetrying: Bool, retry: () -> Void)?
    let onTap: () -> Void

    /// Where the box is, and where the text starts in it.
    static let box = (x: 17.0, y: 276.0, width: 412.0, height: 65.0)
    static let inset = (x: 6.0, y: 3.0)
    static let arrowFrames = 4
    static let maxRows = 4
    static let retry = (
        x: box.x + box.width - 6 - BarButton.width, y: box.y + box.height - 5 - BarButton.height
    )
    static let failureWidth = Double(BarText.width) - BarButton.width - 8
    /// What the box draws in: the text's 400 and the 6 it may hang into at either end. Anything
    /// past that is cut off rather than drawn outside the box.
    static let textWidth = Double(BarText.width + BarText.hang)

    @State private var frame = 0
    private let timer = Timer.publish(every: 0.111, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let failure {
                BarPixelText(
                    fitted(failure.message, width: Self.failureWidth),
                    x: Self.box.x + Self.inset.x, y: Self.box.y + Self.inset.y,
                    width: Self.failureWidth + Double(BarText.hang)
                )
                if !failure.isRetrying {
                    BarButton(x: Self.retry.x, y: Self.retry.y, label: BarCopy.retry, action: failure.retry)
                }
            } else if let memo {
                BarPixelText(
                    fitted(memo, width: Double(BarText.width)),
                    x: Self.box.x + Self.inset.x, y: Self.box.y + Self.inset.y,
                    width: Self.textWidth
                )
            } else if let text {
                BarPixelText(
                    runs: runs(of: text), x: Self.box.x + Self.inset.x, y: Self.box.y + Self.inset.y,
                    width: Self.textWidth
                )
                if isArrowShown {
                    BarSprite(
                        name: "arrow_\(frame % Self.arrowFrames)",
                        x: Self.box.x + Self.box.width - 16, y: Self.box.y + Self.box.height - 13,
                        width: 8, height: 8
                    )
                }
            }
            BarHitArea(
                x: Self.box.x, y: Self.box.y, width: Self.box.width, height: Self.box.height,
                label: BarCopy.next, action: onTap
            )
        }
        .onReceive(timer) { _ in
            if isArrowShown { frame = (frame + 1) % Self.arrowFrames }
        }
    }

    /// The page's rows as runs: the name and colon where a row opens the line, then the text
    /// in its colour; a row break between.
    private func runs(of page: BarTextPage) -> [BarFont.Run] {
        var runs: [BarFont.Run] = []
        for (index, row) in page.rows.enumerated() {
            if index > 0 { runs.append(BarFont.Run(text: "\n", color: BarInk.uiText)) }
            if let name = row.name {
                runs.append(BarFont.Run(
                    text: name, color: speaker == .her ? UIColor(herColor) : BarInk.uiProducer
                ))
            }
            runs.append(BarFont.Run(text: row.text, color: row.subtitle ? BarInk.uiSub : BarInk.uiText))
        }
        return runs
    }

    /// `text` in rows `width` wide, cut short with 「…」 past the box's rows.
    private func fitted(_ text: String, width: Double) -> String {
        var rows = BarText.wrapText(
            text, width: Int(width), measure: { Int(images.face.width($0)) }, hang: BarText.hang
        )
        if rows.count > Self.maxRows {
            let last = rows[Self.maxRows - 1]
            rows = Array(rows.prefix(Self.maxRows - 1)) + [last.isEmpty ? "" : "\(last.dropLast())…"]
        }
        return rows.joined(separator: "\n")
    }
}
