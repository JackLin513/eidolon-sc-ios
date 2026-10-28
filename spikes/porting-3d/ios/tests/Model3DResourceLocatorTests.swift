import Foundation
import XCTest
@testable import Eidolon3DSpike

final class Model3DResourceLocatorTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "Model3DResourceLocatorTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testEnvironmentPathWinsWhenTheFileExists() throws {
        let model = root.appending(path: "picked.usdz")
        try Data().write(to: model)
        let resolved = Model3DResourceLocator.locate(
            environment: ["EIDOLON_3D_MODEL": model.path],
            documents: root,
            resourceRoot: nil
        )
        XCTAssertEqual(resolved, model)
    }

    func testFindsTheModelNestedInsideTheResourceDirectory() throws {
        let resources = root.appending(path: "App.app")
        let nested = resources.appending(path: "Resources/mirai.usdz")
        try FileManager.default.createDirectory(
            at: nested.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: nested)

        let resolved = Model3DResourceLocator.locate(
            environment: [:],
            documents: root.appending(path: "Documents"),
            resourceRoot: resources
        )
        XCTAssertEqual(resolved, nested)
    }

    func testFindsAnOutfitSpecificResource() throws {
        let resources = root.appending(path: "App.app")
        let nested = resources.appending(path: "mirai-ss003.usdz")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try Data().write(to: nested)

        let resolved = Model3DResourceLocator.locate(
            environment: [:],
            documents: root,
            resourceRoot: resources,
            fileName: "mirai-ss003.usdz"
        )
        XCTAssertEqual(resolved, nested)
    }

    func testFallsBackToDocumentsAndThenNil() throws {
        let documents = root.appending(path: "Documents")
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        let model = documents.appending(path: "mirai.usdz")
        try Data().write(to: model)
        XCTAssertEqual(
            Model3DResourceLocator.locate(environment: [:], documents: documents, resourceRoot: nil),
            model
        )
        XCTAssertNil(
            Model3DResourceLocator.locate(
                environment: [:],
                documents: documents.appending(path: "missing"),
                resourceRoot: nil
            )
        )
    }
}
