import SwiftUI

/// The moments tab (spec #94): the place for what she posts. Its content arrives with the
/// image work in the next branch; until then the tab says so instead of hiding.
struct MomentsView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label("朋友圈即将开放", systemImage: "person.2")
            } description: {
                Text("她的动态和照片以后会出现在这里。")
            }
            .navigationTitle("朋友圈")
            .accessibilityIdentifier("moments.placeholder")
        }
        .overlay(alignment: .top) {
            CallBar()
        }
    }
}
