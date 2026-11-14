import SwiftUI

/// A destructive confirmation that points at the control that asked for it.
///
/// `confirmationDialog` anchors to the view it is attached to. When it is attached to a
/// whole `List` or `Form`, iOS puts the sheet at the edge of that container instead of at
/// the row that was tapped. Keeping the presenter on the row/button makes the arrow and
/// the card land next to the deletion.
extension View {
    func anchoredConfirmation(
        _ title: String,
        message: String? = nil,
        confirmTitle: String = "删除",
        arrowEdge: Edge = .top,
        isPresented: Binding<Bool>,
        onConfirm: @escaping () -> Void
    ) -> some View {
        popover(
            isPresented: isPresented,
            attachmentAnchor: .rect(.bounds),
            arrowEdge: arrowEdge
        ) {
            AnchoredConfirmationCard(
                title: title,
                message: message,
                confirmTitle: confirmTitle,
                onConfirm: onConfirm
            )
            .presentationCompactAdaptation(.popover)
        }
    }
}

private struct AnchoredConfirmationCard: View {
    let title: String
    let message: String?
    let confirmTitle: String
    let onConfirm: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            if let message, !message.isEmpty {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button("取消", role: .cancel) { dismiss() }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                Button(confirmTitle, role: .destructive) {
                    dismiss()
                    onConfirm()
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .frame(maxWidth: .infinity)
            }
        }
        .padding(16)
        .frame(width: 280)
    }
}
