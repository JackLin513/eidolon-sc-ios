import EidolonCore
import SwiftUI

/// Her heart in the call's five tiers, as upstream draws them.
struct AffinityHeartIcon: View {
    let heart: AffinityHeart
    let color: Color

    var body: some View {
        Group {
            switch heart {
            case .off:
                Image(systemName: "heart.slash")
            case .crack:
                Image(systemName: "bolt.heart")
            case .outline:
                Image(systemName: "heart")
            case .half:
                // The lower half filled, as upstream overlays it.
                Image(systemName: "heart")
                    .overlay {
                        Image(systemName: "heart.fill")
                            .mask {
                                VStack(spacing: 0) {
                                    Color.clear
                                    Color.black
                                }
                            }
                    }
            case .filled:
                Image(systemName: "heart.fill")
            }
        }
        .foregroundStyle(color)
    }
}

/// The up or down arrow the badge, the transcript capsule and the call's status line share.
struct AffinityArrow: View {
    let up: Bool

    var body: some View {
        Image(systemName: up ? "arrow.up" : "arrow.down")
            .font(.system(size: 10, weight: .bold))
    }
}

/// The badge under her name: her heart and the tier, or an hourglass and when the cooldown
/// ends. Tapping it opens what the tier means (spec #38).
struct AffinityBadgeView: View {
    let badge: AffinityBadge
    let color: Color
    let cue: AffinityCue?
    @Binding var showsDetails: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var scale: CGFloat = 1

    var body: some View {
        Button {
            showsDetails = true
        } label: {
            HStack(spacing: 3) {
                mark
                Text(badge.text)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(badge.label)
        .popover(isPresented: $showsDetails) {
            AffinityDetailsView(badge: badge)
                .presentationCompactAdaptation(.popover)
        }
        .onChange(of: cue?.key) { _, key in
            guard key != nil, !reduceMotion else { return }
            withAnimation(.spring(response: 0.22, dampingFraction: 0.45)) { scale = 1.18 }
            Task {
                try? await Task.sleep(for: .milliseconds(220))
                withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) { scale = 1 }
            }
        }
    }

    private var mark: some View {
        kindMark
            .overlay(alignment: .topTrailing) {
                if let cue {
                    AffinityArrow(up: cue.change.up)
                        .foregroundStyle(cue.change.up ? Color.white : Color(.systemBackground))
                        .frame(width: 12, height: 12)
                        .background(Circle().fill(cue.change.up ? color : Color.primary))
                        .offset(x: 5, y: -4)
                        .accessibilityHidden(true)
                }
            }
    }

    @ViewBuilder
    private var kindMark: some View {
        switch badge.kind {
        case let .tier(_, heart):
            AffinityHeartIcon(heart: heart, color: color)
                .font(.system(size: 13))
                .scaleEffect(scale)
        case .cooldown:
            Image(systemName: "hourglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }
}

/// The card the badge opens: what this relation is, the five tiers with this one marked,
/// and the rule (spec #38). No gift link: gifts are not in this version.
struct AffinityDetailsView: View {
    let badge: AffinityBadge

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(badge.title)
                    .font(.subheadline.weight(.semibold))
                Text(badge.note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 4) {
                ForEach(AffinityTier.allCases, id: \.self) { tier in
                    let current = isCurrent(tier)
                    Text(tier.title)
                        .font(.caption2)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(
                            current ? Color.primary : Color.secondary.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                        )
                        .foregroundStyle(current ? Color(.systemBackground) : Color.secondary)
                        .accessibilityAddTraits(current ? .isSelected : [])
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(AffinityCopy.tiersLabel)
            Text(AffinityCopy.rule)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 320)
    }

    private func isCurrent(_ tier: AffinityTier) -> Bool {
        if case let .tier(current, _) = badge.kind { return current == tier }
        return false
    }
}

/// The arrow and sentence a change is shown with, on the badge, in the transcript and on
/// the call's status line.
struct AffinityCueLabel: View {
    let change: AffinityChange
    let name: String

    var body: some View {
        HStack(spacing: 4) {
            AffinityArrow(up: change.up)
            Text(change.text(name: name))
                .lineLimit(1)
        }
    }
}

/// The line the transcript puts under the reply that changed her affinity.
struct AffinityCueCapsule: View {
    let change: AffinityChange
    let name: String

    var body: some View {
        AffinityCueLabel(change: change, name: name)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(Color(.secondarySystemBackground), in: Capsule())
            .frame(maxWidth: .infinity, alignment: .center)
    }
}
