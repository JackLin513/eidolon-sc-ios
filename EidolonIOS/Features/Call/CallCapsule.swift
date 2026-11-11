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
    /// Docked to a screen side and folded down to her avatar only (Q4-A/Q6-A).
    @State private var half = false
    @State private var dragStartedDocked = false
    /// Free vertical position while docked to a left/right edge.
    @State private var sideY: CGFloat?

    private static let capsuleSize = CGSize(width: 148, height: 44)
    private static let halfSize = CGSize(width: 44, height: 44)

    var body: some View {
        GeometryReader { proxy in
            if app.call.showsBar, let character = app.call.character {
                let insets = proxy.safeAreaInsets
                let container = proxy.size
                let size = half ? Self.halfSize : Self.capsuleSize
                let resting: CGPoint = {
                    if corner.isSide, let sideY {
                        return ResponsiveLayout.callCapsuleSideCenter(
                            side: corner,
                            y: sideY,
                            size: size,
                            container: container,
                            safeInsets: insets,
                            extraBottom: bottomClearance
                        )
                    }
                    return ResponsiveLayout.callCapsuleCenter(
                        corner: corner,
                        size: size,
                        container: container,
                        safeInsets: insets,
                        extraBottom: bottomClearance
                    )
                }()
                let dragged = CGPoint(
                    x: resting.x + translation.width,
                    y: resting.y + translation.height
                )
                let center = dragging
                    ? ResponsiveLayout.clampedCallCapsuleCenter(
                        dragged,
                        size: size,
                        container: container,
                        safeInsets: insets,
                        margin: ResponsiveLayout.callCapsuleMargin,
                        extraBottom: max(0, bottomClearance)
                    )
                    : resting
                content(character)
                    .position(center)
                    .gesture(dragGesture(container: container, safeInsets: insets, resting: resting))
                    .onTapGesture {
                        if half {
                            half = false
                        } else {
                            expand()
                        }
                    }
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

    @ViewBuilder
    private func content(_ character: CharacterConfig) -> some View {
        if half {
            halfContent(character)
        } else {
            fullContent(character)
        }
    }

    private func halfContent(_ character: CharacterConfig) -> some View {
        ZStack(alignment: .bottomTrailing) {
            avatar(character)
                .frame(width: 44, height: 44)
                .clipShape(Circle())
            statusDot
                .frame(width: 10, height: 10)
                .overlay(Circle().stroke(.white, lineWidth: 1.5))
                .offset(x: 2, y: 1)
        }
        .frame(width: Self.halfSize.width, height: Self.halfSize.height)
        .background(.regularMaterial, in: Circle())
        .overlay(Circle().strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        .contentShape(Circle())
        .accessibilityLabel("通话 \(character.name)，轻点恢复")
    }

    private func fullContent(_ character: CharacterConfig) -> some View {
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
                if !dragging {
                    dragStartedDocked = corner.isSide
                }
                dragging = true
                translation = value.translation
            }
            .onEnded { value in
                let target = CGPoint(
                    x: resting.x + value.translation.width,
                    y: resting.y + value.translation.height
                )
                let size = half ? Self.halfSize : Self.capsuleSize
                let edgeInset = ResponsiveLayout.callCapsuleMargin + 96
                let nearLeading = target.x <= safeInsets.leading + edgeInset
                let nearTrailing = target.x >= container.width - safeInsets.trailing - edgeInset
                let next: CallCapsuleCorner
                if nearLeading {
                    next = .leading
                    sideY = ResponsiveLayout.callCapsuleSideCenter(
                        side: .leading,
                        y: target.y,
                        size: size,
                        container: container,
                        safeInsets: safeInsets,
                        extraBottom: max(0, bottomClearance)
                    ).y
                } else if nearTrailing {
                    next = .trailing
                    sideY = ResponsiveLayout.callCapsuleSideCenter(
                        side: .trailing,
                        y: target.y,
                        size: size,
                        container: container,
                        safeInsets: safeInsets,
                        extraBottom: max(0, bottomClearance)
                    ).y
                } else {
                    next = ResponsiveLayout.callCapsuleCornerOnly(
                        for: target,
                        size: size,
                        container: container,
                        safeInsets: safeInsets,
                        margin: ResponsiveLayout.callCapsuleMargin,
                        extraBottom: max(0, bottomClearance)
                    )
                    sideY = nil
                }
                let outward = (next == .leading && value.translation.width < -18)
                    || (next == .trailing && value.translation.width > 18)
                let inward = (corner == .leading && value.translation.width > 18)
                    || (corner == .trailing && value.translation.width < -18)
                if half, inward {
                    half = false
                } else if !half, dragStartedDocked, outward {
                    half = true
                } else if half, !next.isSide {
                    half = false
                }
                corner = next
                translation = .zero
                dragging = false
                dragStartedDocked = false
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

private extension CallCapsuleCorner {
    var isSide: Bool { self == .leading || self == .trailing }
}
