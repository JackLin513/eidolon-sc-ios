import EidolonCore
import SwiftUI
import UIKit

/// Each drink of the catalog (by id) and its picture (`drink_<name>`); the glitched bottle for
/// one not known (upstream `drinkSprites.ts`).
enum BarDrinkSprites {
    static let sprites: [String: String] = [
        "sugar-rush": "srush",
        "sparkle-star": "sstar",
        "blue-fairy": "bfairy",
        "fluffy-dream": "fdream",
        "sunshine-cloud": "scloud",
        "moonblast": "moblast",
        "gut-punch": "gpunch",
        "piledriver": "pdriver",
        "suplex": "splex",
        "marsblast": "mablast",
        "crevice-spike": "cspike",
        "beer": "beer",
        "bleeding-jane": "bjane",
        "frothy-water": "beer",
        "bad-touch": "btouch",
        "brandtini": "btini",
        "cobalt-velvet": "cvelvet",
        "fringe-weaver": "fweaver",
        "mercury-blast": "meblast",
        "grizzly-temple": "gtemple",
        "bloom-light": "blight",
        "zen-star": "zstar",
        "piano-man": "pman",
        "piano-woman": "pwman",
        "absinthe": "abs",
        "rum": "rum",
        "mulan-tea": "tea",
        "a-fedora": "fed",
    ]

    static func name(_ id: String) -> String {
        guard let name = sprites[id] else { return "drink_glitch" }
        return "drink_\(name)"
    }
}

/// 配方书 (upstream `BarRecipeBook.tsx`, the prototype's `RecipeBook`): over the guest's window
/// while mixing, a white frame in the CALICOMP window with four tabs across its top and a page
/// under them — the cover, a tab's categories, a category's drinks, or a drink's card — and the
/// two arrows with 「n/24」 under it. The bottled drinks' pictures drag into the shaker.
struct BarRecipeBookView: View {
    /// Where the book goes over the guest's window, and its 420×252 window.
    static let book = (x: 18.0, y: 20.0, width: 420.0, height: 252.0)
    /// The white frame in it, and the black page inside that (its own coordinates from here).
    static let paper = (x: 4.0, y: 9.0, width: 324.0, height: 234.0)
    static let page = (x: 9.0, y: 25.0, width: 315.0, height: 214.0)
    /// Each tab's left edge and width along the frame's top.
    static let tabBoxes: [BarRecipeBook.Tab: (x: Double, width: Double)] = [
        .name: (9, 62), .flavor: (79, 62), .kind: (139, 62), .bottle: (211, 72),
    ]
    /// The page-turning arrows and 「n/24」 under the card.
    static let arrow = (y: 209.0, width: 23.0, height: 24.0, prev: 22.0, next: 290.0)
    static let pageNumber = (x: 142.0, y: 214.0, width: 60.0)
    static let title = (x: 18.0, y: 20.0)
    static let list = (x: 39.0, y: 58.0, step: 30.0, width: 200.0, letterColumn: 92.0, lettersPerColumn: 4)
    static let drinkList = (y: 52.0, step: 26.0)
    static let bottle = (x: 39.0, y: 56.0, width: 35.0, height: 53.0)
    static let note = (x: 90.0, y: 75.0)

    let drinks: [Drink]
    let isCounterOpen: Bool
    let drag: BarDrag
    /// Plays a sound by its name.
    let play: (String) -> Void
    /// Turns a page: -1 before, 1 after.
    let onPage: (Int) -> Void

    @State private var book = BarRecipeBook.State.cover

    var body: some View {
        ZStack(alignment: .topLeading) {
            BarSprite(name: "recipe_bg", x: 0, y: 0, width: Self.book.width, height: Self.book.height)
            Rectangle()
                .fill(BarInk.paper)
                .frame(width: Self.paper.width, height: Self.paper.height)
                .offset(x: Self.paper.x, y: Self.paper.y)
            tabs
            pageBody
            arrows
        }
        .frame(width: Self.book.width, height: Self.book.height, alignment: .topLeading)
        .clipped()
        .offset(x: Self.book.x, y: Self.book.y)
        .onAppear { play("boot_up") }
    }

    // MARK: - Tabs

    private var tabs: some View {
        ZStack(alignment: .topLeading) {
            ForEach(BarRecipeBook.Tab.allCases, id: \.self) { tab in
                let box = Self.tabBoxes[tab] ?? (0, 0)
                let isActive = book.tab == tab
                if isActive {
                    Rectangle()
                        .fill(BarInk.black)
                        .frame(width: box.width, height: 16)
                        .offset(x: box.x, y: Self.paper.y)
                }
                BarPixelText(
                    BarCopy.tabName(tab), x: box.x + 3, y: Self.paper.y + 1,
                    color: isActive ? UIColor(BarInk.text) : UIColor(BarInk.black)
                )
                BarHitArea(
                    x: box.x, y: Self.paper.y, width: box.width, height: 16, label: BarCopy.tabName(tab)
                ) {
                    act(.tab(tab), book.tab == tab ? nil : "jukeselect")
                }
            }
        }
    }

    // MARK: - The page

    @ViewBuilder private var pageBody: some View {
        ZStack(alignment: .topLeading) {
            // 一页是黑的（上游 `background: BAR_INK.black`）：白框只是它外面的一圈边，
            // 字是上面那层灰。早先没铺这层黑，白底压着浅灰字，几乎看不清。
            Rectangle().fill(BarInk.black)
            content
        }
        .frame(width: Self.page.width, height: Self.page.height, alignment: .topLeading)
        .clipped()
        .offset(x: Self.page.x, y: Self.page.y)
    }

    @ViewBuilder private var content: some View {
        let open = drinks.first { $0.id == book.drink }
        if let open, !open.isBottled, let page = open.page {
            BarSprite(name: "recipe_\(page)", x: 0, y: 0, width: Self.page.width, height: Self.page.height)
        } else if let open, open.isBottled {
            let isDragged = drag.item == .bottle(open.id)
            BarPixelText(open.name, x: Self.title.x, y: Self.title.y)
            if !isDragged {
                BarSprite(
                    name: BarDrinkSprites.name(open.id), x: Self.bottle.x, y: Self.bottle.y,
                    width: Self.bottle.width, height: Self.bottle.height
                )
            }
            Color.clear
                .frame(width: Self.bottle.width, height: Self.bottle.height)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .named(BarDrag.space))
                        .onChanged { value in
                            guard isCounterOpen else { return }
                            drag.begin(.bottle(open.id), at: value.location)
                        }
                        .onEnded { value in
                            guard isCounterOpen else { return }
                            drag.end(at: value.location) { _ in }
                        }
                )
                .allowsHitTesting(isCounterOpen)
                .accessibilityElement()
                .accessibilityLabel(BarCopy.Book.bottle(open.name))
                .offset(x: Self.bottle.x, y: Self.bottle.y)
            BarPixelText(
                open.description, x: Self.note.x, y: Self.note.y, color: UIColor(BarInk.bookGrey)
            )
        } else if book.tab == nil {
            BarSprite(name: "recipe_intro", x: 0, y: 0, width: Self.page.width, height: Self.page.height)
        } else if let tab = book.tab, tab == .bottle {
            BarPixelText(BarCopy.Book.Search.bottle, x: Self.title.x, y: Self.title.y)
            ForEach(Array(BarRecipeBook.drinksIn(.bottle, nil, drinks).enumerated()), id: \.element.id) { index, drink in
                item(drink.id, drink.name, x: Self.list.x, y: Self.list.y + Double(index) * Self.list.step) {
                    act(.drink(drink.id), "jukechange")
                }
            }
        } else if let tab = book.tab, book.category == nil {
            BarPixelText(searchTitle(tab), x: Self.title.x, y: Self.title.y)
            ForEach(Array(BarRecipeBook.categories(tab, drinks).enumerated()), id: \.element) { index, key in
                let isNameTab = tab == .name
                let x = isNameTab
                    ? Self.list.x + Double(index / Self.list.lettersPerColumn) * Self.list.letterColumn
                    : Self.list.x
                let y = Self.list.y + Double(isNameTab ? index % Self.list.lettersPerColumn : index) * Self.list.step
                item(
                    key, categoryName(tab, key), x: x, y: y,
                    width: isNameTab ? Self.list.letterColumn : Self.list.width
                ) {
                    act(.category(key), "jukepick")
                }
            }
        } else if let tab = book.tab, let category = book.category {
            BarPixelText(categoryName(tab, category), x: Self.title.x, y: Self.title.y)
            ForEach(Array(BarRecipeBook.drinksIn(tab, category, drinks).enumerated()), id: \.element.id) { index, drink in
                item(
                    drink.id, drink.name, x: Self.list.x,
                    y: Self.drinkList.y + Double(index) * Self.drinkList.step
                ) {
                    act(.drink(drink.id), "jukechange")
                }
            }
        }
    }

    /// One grey item of a list; `width` is how much of the row takes the tap.
    private func item(
        _ id: String, _ text: String, x: Double, y: Double, width: Double? = nil,
        _ action: @escaping () -> Void
    ) -> some View {
        ZStack(alignment: .topLeading) {
            BarPixelText(text, x: x, y: y, color: UIColor(BarInk.bookGrey))
            BarHitArea(
                x: x - 4, y: y - 3, width: width ?? Self.list.width, height: 22, label: text, action: action
            )
        }
    }

    private var arrows: some View {
        ZStack(alignment: .topLeading) {
            if let page = BarRecipeBook.pageOf(book, drinks) {
                arrow(step: -1, at: Self.arrow.prev, isEnd: page.n == 1, label: BarCopy.Book.prev)
                arrow(step: 1, at: Self.arrow.next, isEnd: page.n == page.of, label: BarCopy.Book.next)
                BarPixelText(
                    "\(page.n)/\(page.of)", x: Self.pageNumber.x, y: Self.pageNumber.y,
                    width: Self.pageNumber.width, align: .center
                )
            }
        }
    }

    private func arrow(step: Int, at x: Double, isEnd: Bool, label: String) -> some View {
        ZStack(alignment: .topLeading) {
            BarSprite(
                name: "arrow", x: 0, y: 0, width: Self.arrow.width, height: Self.arrow.height,
                opacity: isEnd ? 0.3 : 1, flipped: step < 0
            )
            BarHitArea(
                x: 0, y: 0, width: Self.arrow.width, height: Self.arrow.height, label: label
            ) {
                let next = BarRecipeBook.apply(book, .page(step), drinks)
                guard next != book else {
                    play("jukechange")
                    return
                }
                play("jukepick")
                book = next
                onPage(step)
            }
        }
        .offset(x: x, y: Self.arrow.y)
    }

    // MARK: - Acting

    /// Does `action` with the sound `onDone`, or `onRefused` if it changes nothing.
    private func act(_ action: BarRecipeBook.Action, _ onDone: String?, _ onRefused: String? = nil) {
        let next = BarRecipeBook.apply(book, action, drinks)
        guard next != book else {
            if let onRefused { play(onRefused) }
            return
        }
        if let onDone { play(onDone) }
        book = next
    }

    private func searchTitle(_ tab: BarRecipeBook.Tab) -> String {
        switch tab {
        case .name: BarCopy.Book.Search.name
        case .flavor: BarCopy.Book.Search.flavor
        case .kind: BarCopy.Book.Search.kind
        case .bottle: BarCopy.Book.Search.bottle
        }
    }

    /// What a category is called: an initial as it is, a flavor or kind by its name.
    private func categoryName(_ tab: BarRecipeBook.Tab, _ key: String) -> String {
        switch tab {
        case .flavor: return BarCopy.Book.category(BarCopy.Book.flavors[key] ?? key)
        case .kind: return BarCopy.Book.category(BarCopy.Book.kinds[key] ?? key)
        default: return key
        }
    }
}
