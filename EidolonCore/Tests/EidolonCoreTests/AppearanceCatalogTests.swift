import Foundation
import Testing
@testable import EidolonCore

@Suite("Appearance catalog")
struct AppearanceCatalogTests {
    @Test("static bases expose independent outfit and pose options")
    func staticAxes() {
        let bases = [
            StaticStandManifest.Base(id: "A.A", outfit: "A", pose: "A", expressions: ["calm": "a"]),
            StaticStandManifest.Base(id: "A.B", outfit: "A", pose: "B", expressions: ["calm": "b"]),
            StaticStandManifest.Base(id: "B.A", outfit: "B", pose: "A", expressions: ["calm": "c"]),
        ]
        let catalog = AppearanceCatalog(characterID: "sakura", bases: bases)
        #expect(catalog.dimension("outfit")?.options.map(\.id) == ["A", "B"])
        #expect(catalog.dimension("pose")?.options.map(\.id) == ["A", "B"])
        #expect(catalog.base(outfit: "B", pose: "A", in: bases)?.id == "B.A")
    }

    @Test("appearance selection keeps a stable storage key")
    func storageKey() {
        let selection = AppearanceSelection(characterID: "sakura", values: ["pose": "B", "outfit": "A"], emotion: .shy)
        #expect(selection.storageKey == "outfit=A&pose=B")
    }
}
