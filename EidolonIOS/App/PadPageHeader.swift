import SwiftUI

/// A fixed-anchor page title for the pad shell. System large titles move with the
/// navigation bar; this keeps moments, play and the settings detail on the same
/// leading/top anchor on every iPad size.
struct PadPageLargeTitle<Trailing: View>: View {
    let title: String
    let accessibilityID: String
    let trailing: Trailing

    init(_ title: String, id: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.accessibilityID = id
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.largeTitle.weight(.bold))
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier(accessibilityID)
            Spacer(minLength: 0)
            trailing
        }
        .padding(.leading, ResponsiveLayout.pageTitleLeading)
        .padding(.trailing, ResponsiveLayout.pageTitleLeading)
        .padding(.top, ResponsiveLayout.pageTitleTop)
        .padding(.bottom, 8)
    }
}

extension PadPageLargeTitle where Trailing == EmptyView {
    init(_ title: String, id: String) {
        self.init(title, id: id) { EmptyView() }
    }
}
