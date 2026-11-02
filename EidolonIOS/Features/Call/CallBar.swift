import EidolonCore
import SwiftUI

/// The folded call's bar (spec #46, upstream `CallBar`): one 40pt strip, dark as the call
/// layer, that says the call is still going and takes any tap back to it. It has no
/// hang-up: ending the call is the layer's to do.
struct CallBar: View {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Her conversation already has her name in the navigation bar, so its bar leaves it
    /// out; every other page says whose call this is.
    var showsName = true
    /// Whether a tap also brings the conversation tab forward. The bar room and the
    /// outfit picker are already over the call, so they only expand it (spec #64).
    var returnsToConversation = true

    /// How long the dialling dot takes to blink once.
    private static let blink = 0.8

    var body: some View {
        if app.call.showsBar, let character = app.call.character {
            Button {
                if returnsToConversation { app.selectedTab = .conversation }
                app.call.expand()
            } label: {
                HStack(spacing: 8) {
                    dot
                    if showsName {
                        Text(character.name)
                            .fontWeight(.semibold)
                    }
                    status
                    Spacer(minLength: 8)
                    Text("回到通话")
                        .foregroundStyle(.white.opacity(0.7))
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .font(.footnote)
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .background(Color(hex: "#111111"))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("回到通话")
            .accessibilityHint(returnsToConversation ? "展开通话并回到对话" : "展开通话")
        }
    }

    /// White while the call is up; a slow blink until it connects.
    private var dot: some View {
        TimelineView(.periodic(from: .now, by: Self.blink)) { context in
            Circle()
                .fill(.white)
                .frame(width: 8, height: 8)
                .opacity(opacity(at: context.date))
        }
    }

    private func opacity(at now: Date) -> Double {
        guard app.call.connectedAt == nil, !reduceMotion else { return 1 }
        let tick = Int(now.timeIntervalSinceReferenceDate / Self.blink) % 2
        return tick == 0 ? 0.35 : 1
    }

    @ViewBuilder
    private var status: some View {
        if let connectedAt = app.call.connectedAt {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let elapsed = max(0, Int(context.date.timeIntervalSince(connectedAt).rounded(.down)))
                Text("通话中 " + CallClock.clock(elapsed))
                    .monospacedDigit()
            }
        } else {
            Text("正在呼叫…")
        }
    }
}
