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

/// The hairline that separates two pad columns. It is deliberately thinner than a
/// `Divider` so the draggable blue line can sit on top of it without looking doubled.
struct PadBoundaryLine: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.30))
            .frame(width: 0.5)
            .frame(maxHeight: .infinity)
            .allowsHitTesting(false)
    }
}
