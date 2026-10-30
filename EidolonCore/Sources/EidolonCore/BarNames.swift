import Foundation

/// Names of drinks as her lines are checked for them (upstream `folded`, `names_in` and
/// `names_rightly`): whatever their case, width or spacing.
public enum BarNames {
    /// `text` as names in it are compared, whatever its case, width or spacing: without
    /// spaces or middle dots (ピアノ マン, ピアノ・マン and ピアノマン alike).
    ///
    /// Upstream normalises to NFKC and case-folds; the bar's content is Japanese and
    /// English, where the width-insensitive comparison below is what NFKC does to the
    /// characters it can hold (full-width Latin and digits, half-width kana).
    public static func folded(_ text: String) -> String {
        let wide = text.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? text
        return wide.unicodeScalars
            .filter { !CharacterSet.whitespacesAndNewlines.contains($0) && $0 != "・" && $0 != "·" }
            .map { String($0) }
            .joined()
            .lowercased()
    }

    /// The English names of the drinks of `catalog` that `text` names, in English or in
    /// Japanese, whatever its case, width or spacing.
    public static func names(in text: String, catalog: DrinkCatalog) -> [String] {
        let compared = folded(text)
        return catalog.drinks.compactMap { drink in
            let english = folded(drink.name)
            let japanese = folded(drink.nameJa)
            // A half-width kana name folded to its full-width form is how NFKC leaves it,
            // so both forms are compared.
            let alsoFull = drink.nameJa.applyingTransform(.fullwidthToHalfwidth, reverse: true) ?? drink.nameJa
            let japaneseFull = foldedFullWidth(alsoFull)
            if !english.isEmpty, compared.contains(english) { return drink.name }
            if !japanese.isEmpty, compared.contains(japanese) { return drink.name }
            if !japaneseFull.isEmpty, compared.contains(japaneseFull) { return drink.name }
            return nil
        }
    }

    /// Whether `lines`, her order, name drinks as they should: the drink she means, in
    /// Chinese by its English name or in Japanese by its Japanese one, where she orders by
    /// name; else none of the catalog's in either.
    public static func rightly(
        _ order: BarOrder, _ lines: [BarLine], catalog: DrinkCatalog
    ) -> Bool {
        if order.phrasing.names {
            let target = order.target
            let english = folded(target.name)
            let japanese = folded(target.nameJa)
            return lines.contains { line in
                (!english.isEmpty && folded(line.zh).contains(english))
                    || (!japanese.isEmpty && folded(line.ja).contains(japanese))
            }
        }
        return !lines.contains { line in
            !names(in: line.ja, catalog: catalog).isEmpty
                || !names(in: line.zh, catalog: catalog).isEmpty
        }
    }

    /// The comparison form of a half-width-normalised name, taken back to full width so a
    /// half-width name in the content still matches a full-width one in a line.
    private static func foldedFullWidth(_ text: String) -> String {
        let scaled = text.applyingTransform(.fullwidthToHalfwidth, reverse: true) ?? text
        return folded(scaled)
    }
}
