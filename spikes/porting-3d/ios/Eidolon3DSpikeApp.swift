import SwiftUI

@main
struct Eidolon3DSpikeApp: App {
    var body: some Scene {
        WindowGroup {
            Model3DPreview()
                .preferredColorScheme(.dark)
        }
    }
}
