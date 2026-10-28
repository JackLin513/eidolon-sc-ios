import SwiftUI

@main
struct Eidolon3DSpikeApp: App {
    var body: some Scene {
        WindowGroup {
            Model3DPreview(modelURL: Self.startingModelURL)
                .preferredColorScheme(.dark)
        }
    }

    private static var startingModelURL: URL? {
        Model3DResourceLocator.locate(
            environment: ProcessInfo.processInfo.environment,
            documents: URL.documentsDirectory,
            resourceRoot: Bundle.main.resourceURL
        )
    }
}
