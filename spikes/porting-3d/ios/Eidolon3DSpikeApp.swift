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
        if let raw = ProcessInfo.processInfo.environment["EIDOLON_3D_MODEL"] {
            let url = raw.hasPrefix("/") ? URL(fileURLWithPath: raw) : URL.documentsDirectory.appending(path: raw)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        if let bundled = Bundle.main.url(forResource: "mirai", withExtension: "usdz") {
            return bundled
        }
        let fallback = URL.documentsDirectory.appending(path: "mirai.usdz")
        return FileManager.default.fileExists(atPath: fallback.path) ? fallback : nil
    }
}
