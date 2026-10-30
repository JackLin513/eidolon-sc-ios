import Foundation

/// How a bar-configuration entry went wrong, in upstream's words.
private func bad(_ message: String) -> EidolonError {
    .invalidContent(message)
}

/// Whether `text` is a configuration identifier: lower-case letters, digits, `-` and `_`.
func isShortIdentifier(_ text: String) -> Bool {
    !text.isEmpty && text.allSatisfy { ch in
        ch.isASCII && (ch.isLowercase || ch.isNumber || ch == "-" || ch == "_")
    }
}

private func isOneLine(_ value: JSONValue?) -> Bool {
    guard let text = value?.stringValue else { return false }
    return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && !text.contains("\r") && !text.contains("\n")
}

extension DrinkCatalog {
    /// The drinks in `characters/drinks.json`, in file order. Throws unless every entry is
    /// well formed and no mixture could be either of two drinks (upstream `load_drink_catalog`
    /// and `DrinkCatalog.__init__`).
    public init(json: JSONValue) throws {
        guard let entries = json.objectValue?["drinks"]?.arrayValue else {
            throw bad("饮品目录里的 drinks 应当是 [[drinks]] 段")
        }
        var seen = Set<String>()
        var drinks: [Drink] = []
        for entry in entries {
            let drink = try Drink(json: entry)
            guard seen.insert(drink.id).inserted else {
                throw bad("饮品标识 \(drink.id) 重复")
            }
            drinks.append(drink)
        }
        try self.init(drinks: drinks)
    }
}

extension Drink {
    private static let common = [
        "id", "name", "name_ja", "short_name", "flavor", "kind", "method", "karmotrine",
        "description",
    ]
    private static let ingredients = ["adelhyde", "bronson_extract", "powdered_delta", "flanergide"]
    private static let mixedOnly = ingredients + ["ice", "aged", "big", "page"]
    private static let mixedRequired = ingredients + ["ice", "aged", "page"]

    /// One `[[drinks]]` entry of `drinks.json`.
    public init(json value: JSONValue) throws {
        guard let entry = value.objectValue else {
            throw bad("饮品目录里的 \(value) 应当是一个 [[drinks]] 段")
        }
        let label = entry["id"]?.stringValue ?? "（没有标识）"
        let bottled = entry["method"]?.stringValue == "bottle"
        let required = bottled ? Self.common : Self.common + Self.mixedRequired
        let missing = required.filter { entry[$0] == nil }
        guard missing.isEmpty else {
            throw bad("饮品 \(label) 缺少 \(missing.joined(separator: "、"))")
        }
        guard let id = entry["id"]?.stringValue, isShortIdentifier(id) else {
            throw bad("饮品标识 \(entry["id"].map { "\($0)" } ?? "（没有标识）") 只能用小写字母、数字、- 和 _")
        }
        for field in ["name", "name_ja", "short_name", "description"] where !isOneLine(entry[field]) {
            throw bad("饮品 \(id) 的 \(field) 应当是一行文字")
        }
        guard let flavor = Flavor(rawValue: entry["flavor"]?.stringValue ?? "") else {
            throw bad("饮品 \(id) 的口味 \(entry["flavor"].map { "\($0)" } ?? "（缺）") 不在 "
                + Flavor.allCases.map(\.rawValue).joined(separator: "、") + " 之中")
        }
        guard let kind = DrinkKind(rawValue: entry["kind"]?.stringValue ?? "") else {
            throw bad("饮品 \(id) 的种类 \(entry["kind"].map { "\($0)" } ?? "（缺）") 不在 "
                + DrinkKind.allCases.map(\.rawValue).joined(separator: "、") + " 之中")
        }
        let name = entry["name"]!.stringValue!
        let nameJa = entry["name_ja"]!.stringValue!
        let shortName = entry["short_name"]!.stringValue!
        let description = entry["description"]!.stringValue!

        if bottled {
            let mixedOnly = Self.mixedOnly.filter { entry[$0] != nil }
            guard mixedOnly.isEmpty else {
                throw bad("饮品 \(id) 是瓶装，不能有 \(mixedOnly.joined(separator: "、"))")
            }
            let karmotrine = try Self.count(entry["karmotrine"], "饮品 \(id) 是瓶装，它的 karmotrine")
            self.init(
                id: id, name: name, nameJa: nameJa, shortName: shortName, flavor: flavor,
                kind: kind, description: description, bottledKarmotrine: karmotrine
            )
            return
        }
        guard let method = Method(rawValue: entry["method"]?.stringValue ?? "") else {
            throw bad("饮品 \(id) 的调法（瓶装是 bottle）\(entry["method"].map { "\($0)" } ?? "（缺）")"
                + " 不在 mix、blend 之中")
        }
        let numbers = try Self.ingredients.map { field in
            try Self.count(entry[field], "饮品 \(id) 的 \(field)")
        }
        let karmotrine: Int?
        if entry["karmotrine"]?.stringValue == "optional" {
            karmotrine = nil
        } else {
            karmotrine = try Self.count(
                entry["karmotrine"], "饮品 \(id) 的 karmotrine（可选的写 \"optional\"）"
            )
        }
        var flags: [String: Bool] = [:]
        for field in ["ice", "aged", "big"] {
            switch entry[field] ?? .bool(false) {
            case .bool(let on): flags[field] = on
            case .null: flags[field] = false
            default: throw bad("饮品 \(id) 的 \(field) 应当是 true 或 false")
            }
        }
        let big = flags["big"] ?? false
        let total = numbers.reduce(0, +) + (karmotrine ?? 0)
        guard total <= DrinkCatalog.maxParts else {
            throw bad("饮品 \(id) 的材料合计 \(total) 份，摇酒壶最多装 \(DrinkCatalog.maxParts) 份")
        }
        guard total > 0 else { throw bad("饮品 \(id) 的配方一份材料都没有") }
        guard big || total * 2 <= DrinkCatalog.maxParts else {
            throw bad("饮品 \(id) 翻倍成大杯是 \(total * 2) 份，超过摇酒壶的 \(DrinkCatalog.maxParts) 份；"
                + "本身就是大杯的写 big = true")
        }
        let page = try Self.page(id, entry["page"])
        self.init(
            id: id, name: name, nameJa: nameJa, shortName: shortName, flavor: flavor, kind: kind,
            description: description,
            recipe: Recipe(
                adelhyde: numbers[0], bronsonExtract: numbers[1], powderedDelta: numbers[2],
                flanergide: numbers[3], karmotrine: karmotrine,
                ice: flags["ice"] ?? false, aged: flags["aged"] ?? false,
                method: method, big: big
            ),
            page: page
        )
    }

    private static func count(_ value: JSONValue?, _ label: String) throws -> Int {
        guard let number = value?.intValue, (0...DrinkCatalog.maxParts).contains(number) else {
            throw bad("\(label) 应当是 0 到 \(DrinkCatalog.maxParts) 的整数，而不是 \(value.map { "\($0)" } ?? "（缺）")")
        }
        return number
    }

    private static func page(_ id: String, _ value: JSONValue?) throws -> Int {
        guard let number = value?.intValue, number >= 1 else {
            throw bad("饮品 \(id) 的 page 应当是配方卡的编号，从 1 起，而不是 \(value.map { "\($0)" } ?? "（缺）")")
        }
        return number
    }
}
