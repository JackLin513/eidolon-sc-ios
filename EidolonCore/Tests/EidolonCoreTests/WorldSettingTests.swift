import Foundation
import XCTest
@testable import EidolonCore

/// The world setting as retrieval searches it: the setlists upstream keeps in the live
/// days, and who she is in a unit with.
final class WorldSettingTests: XCTestCase {
    private func world() throws -> WorldSetting {
        let json = """
            {
              "as_of": "2026-10-23",
              "office": {"name": "283プロ", "staff": []},
              "units": [
                {"name": "ユニットA", "members": ["甲", "乙"]},
                {"name": "ユニットB", "members": ["丙"]}
              ],
              "idols": [
                {"name": "甲", "reading": "こう", "unit": "ユニットA"},
                {"name": "乙", "reading": "おつ", "unit": "ユニットA"},
                {"name": "丙", "reading": "へい", "unit": "ユニットB"}
              ],
              "releases": [],
              "songs": [],
              "lives": [
                {
                  "name": "合同ライブ",
                  "days": [
                    {
                      "date": "2026-10-20",
                      "venue": "東京ドーム",
                      "performers": ["甲", "乙", "丙"],
                      "absent": [],
                      "setlist": [
                        {"title": "全体曲", "singers": ["甲", "乙", "丙"], "dancers": [], "brand": null},
                        {"title": "カバー", "singers": ["甲"], "dancers": [], "brand": "シンデレラガールズ"},
                        {"title": "ダンス", "singers": [], "dancers": ["甲", "乙"], "brand": null},
                        {"title": "謎", "singers": [], "dancers": [], "brand": null}
                      ]
                    }
                  ]
                }
              ]
            }
            """
        return try WorldSetting(json: Data(json.utf8))
    }

    func testUnitMatesAreTheOthersInHerUnit() throws {
        let world = try world()
        XCTAssertEqual(world.unitMates(of: "甲"), ["乙"])
        XCTAssertEqual(world.unitMates(of: "丙"), [])
        XCTAssertEqual(world.unitMates(of: "知らない人"), [])
    }

    /// Upstream `World.entries` writes each live day's setlist: 曲目单, then each item with
    /// the brand it covers and who sang or danced to it.
    func testTheSetlistIsSearchedAsWorkFacts() throws {
        let entry = try XCTUnwrap(try world().entries().first { $0.kind == "live" })
        XCTAssertTrue(entry.text.contains("曲目单（标着别的品牌的是翻唱，不是闪耀色彩的歌）："))
        XCTAssertTrue(entry.text.contains("1. 全体曲：全体出演偶像演唱"))
        XCTAssertTrue(entry.text.contains("2. カバー（シンデレラガールズ的歌）：甲演唱"))
        XCTAssertTrue(entry.text.contains("3. ダンス：ユニットA伴舞，没有演唱"))
        XCTAssertTrue(entry.text.contains("4. 謎：资料里没能确定是谁演唱"))
    }

    /// A live day without a setlist (one still to come, or one of two shows) keeps the
    /// entry it had.
    func testALiveDayWithoutASetlistHasNoSetlistSection() throws {
        let json = """
            {
              "as_of": "2026-10-23",
              "office": {"name": "283プロ", "staff": []},
              "units": [],
              "idols": [{"name": "甲", "reading": "こう"}],
              "releases": [],
              "songs": [],
              "lives": [{"name": "これからのライブ", "days": [
                {"date": "2027-01-01", "venue": "会場", "performers": ["甲"]}
              ]}]
            }
            """
        let entry = try XCTUnwrap(try WorldSetting(json: Data(json.utf8)).entries().first)
        XCTAssertFalse(entry.text.contains("曲目单"))
    }
}
