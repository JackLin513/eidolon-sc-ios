import EidolonCore
import SwiftUI

/// The folded call, as a floating capsule (S2.3): her avatar, a green state dot and the
/// call time. It rests in a safe-area corner, can be dragged anywhere inside the safe area,
/// snaps to the nearest corner on release, and never spans a page title like the old
/// 40pt `CallBar` strip.
struct CallCapsule: View {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var sizeClass

    @Binding var corner: CallCapsuleCorner
    @State private var translation: CGSize = .zero
    @State private var dragging = false

    private static let capsuleSize = CGSize(width: 148, height: 44)

    var body: some View {
        GeometryReader { proxy in
            if app.call.showsBar, let character = app.call.character {
                let insets = proxy.safeAreaInsets
                let container = proxy.size
                let resting = ResponsiveLayout.callCapsuleCenter(
                    corner: corner,
                    size: Self.capsuleSize,
                    container: container,
                    safeInsets: insets,
                    extraBottom: bottomClearance
                )
                let dragged = CGPoint(
                    x: resting.x + translation.width,
                    y: resting.y + translation.height
                )
                let center = dragging
                    ? ResponsiveLayout.clampedCallCapsuleCenter(
                        dragged,
                        size: Self.capsuleSize,
                        container: container,
                        safeInsets: insets,
                        margin: ResponsiveLayout.callCapsuleMargin,
                        extraBottom: max(0, bottomClearance)
                    )
                    : resting
                content(character)
                    .position(center)
                    .gesture(dragGesture(container: container, safeInsets: insets, resting: resting))
                    .onTapGesture { expand() }
                    .contextMenu {
                        Button("展开通话", systemImage: "phone.fill") { expand() }
                        Button("挂断", systemImage: "phone.down.fill", role: .destructive) {
                            Task { await app.call.hangUp() }
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel("通话中，\(character.name)")
                    .accessibilityHint("轻点展开，拖动可移动，长按可挂断")
                    .accessibilityIdentifier("call.capsule")
                    .animation(
                        reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.84),
                        value: corner
                    )
            }
        }
        .allowsHitTesting(app.call.showsBar)
    }

    /// Keep the resting capsule above a bottom composer or tab bar.
    private var bottomClearance: CGFloat {
        switch app.selectedTab {
        case .conversation: ResponsiveLayout.callCapsuleConversationClearance
        default: sizeClass == .compact ? ResponsiveLayout.callCapsuleCompactClearance : 0
        }
    }

    private func content(_ character: CharacterConfig) -> some View {
        HStack(spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                avatar(character)
                    .frame(width: 36, height: 36)
                    .clipShape(Circle())
                statusDot
                    .frame(width: 9, height: 9)
                    .overlay(Circle().stroke(.white, lineWidth: 1.5))
                    .offset(x: 2, y: 1)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(character.name)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                time
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .frame(width: Self.capsuleSize.width, height: Self.capsuleSize.height)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        .contentShape(Capsule())
    }

    @ViewBuilder
    private func avatar(_ character: CharacterConfig) -> some View {
        if let image = app.avatar(for: character.id) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            Circle()
                .fill(Color(hex: character.color ?? "#8A8A8A"))
                .overlay {
                    Text(String(character.name.prefix(1)))
                        .font(.headline)
                        .foregroundStyle(.white)
                }
        }
    }

    @ViewBuilder
    private var statusDot: some View {
        if app.call.connectedAt == nil, !reduceMotion {
            TimelineView(.periodic(from: .now, by: 0.8)) { context in
                let tick = Int(context.date.timeIntervalSinceReferenceDate / 0.8) % 2
                Circle()
                    .fill(.green)
                    .opacity(tick == 0 ? 0.35 : 1)
            }
        } else {
            Circle().fill(.green)
        }
    }

    @ViewBuilder
    private var time: some View {
        if let connectedAt = app.call.connectedAt {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let elapsed = max(0, Int(context.date.timeIntervalSince(connectedAt).rounded(.down)))
                Text(CallClock.clock(elapsed))
            }
        } else {
            Text("正在呼叫…")
        }
    }

    private func dragGesture(
        container: CGSize,
        safeInsets: EdgeInsets,
        resting: CGPoint
    ) -> some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .onChanged { value in
                dragging = true
                translation = value.translation
            }
            .onEnded { value in
                let target = CGPoint(
                    x: resting.x + value.translation.width,
                    y: resting.y + value.translation.height
                )
                corner = ResponsiveLayout.callCapsuleCorner(
                    for: target,
                    size: Self.capsuleSize,
                    container: container,
                    safeInsets: safeInsets,
                    margin: ResponsiveLayout.callCapsuleMargin,
                    extraBottom: max(0, bottomClearance)
                )
                translation = .zero
                dragging = false
            }
    }

    private func expand() {
        // Match the old CallBar: bring the conversation tab forward and expand over
        // whatever it was showing. Do not push her chat, or the end card's return would
        // land in a newly-opened chat instead of the page the producer was on.
        app.selectedTab = .conversation
        app.call.expand()
    }
}
