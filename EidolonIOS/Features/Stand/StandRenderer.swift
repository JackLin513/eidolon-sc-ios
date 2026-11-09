import SwiftUI
import UIKit

/// Hosts whichever renderer a view was given; the interface never sees WebKit or Unity.
struct StandHostView: UIViewRepresentable {
    let renderer: any CharacterRenderer

    func makeUIView(context: Context) -> UIView {
        renderer.view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
