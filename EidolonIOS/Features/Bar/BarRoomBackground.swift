import EidolonCore
import Combine
import SwiftUI

/// 吧台背景, the screen's bottom layer (upstream `BarRoom.tsx`): the room's picture, the fan
/// turning on the ceiling and the TV. A tap on the TV turns to the next channel, ten of them,
/// the tenth off; 「ChN」 lights in green over it as it changes.
struct BarRoomBackground: View {
    static let room = (x: 11.0, y: 18.0, width: 424.0, height: 257.0)
    static let tv = (x: 11.0 + 228, y: 18.0 + 26, width: 99.0, height: 41.0)
    static let fan = (x: 11.0 + 170, y: 18.0 + 31)
    /// The TV's ten channels (bg_tv), each a name and its number of frames; the tenth is off.
    static let channels: [(name: String, frames: Int)] = [
        ("burrito", 3), ("wk", 7), ("dollar", 2), ("news", 6), ("yiik", 3),
        ("toku", 3), ("mwj", 4), ("hassy", 1), ("ramen", 3), ("", 0),
    ]
    static let frameInterval: TimeInterval = 0.22
    static let channelShownFor: TimeInterval = 0.667

    @State private var channel = Int.random(in: 0..<(BarRoomBackground.channels.count - 1))
    @State private var frame = 0
    @State private var shownAt: Date? = Date()
    private let timer = Timer.publish(every: BarRoomBackground.frameInterval, on: .main, in: .common).autoconnect()

    var body: some View {
        let current = Self.channels[min(channel, Self.channels.count - 1)]
        let isOff = current.frames == 0
        let isChannelShown = shownAt.map { Date().timeIntervalSince($0) < Self.channelShownFor } ?? false
        ZStack(alignment: .topLeading) {
            BarSprite(name: "barground", x: Self.room.x, y: Self.room.y, width: Self.room.width, height: Self.room.height)
            if isOff {
                Rectangle()
                    .fill(BarInk.black)
                    .frame(width: Self.tv.width, height: Self.tv.height)
                    .offset(x: Self.tv.x, y: Self.tv.y)
            } else {
                BarSprite(
                    name: "ch_\(current.name)_\(frame % max(current.frames, 1))",
                    x: Self.tv.x, y: Self.tv.y, width: Self.tv.width, height: Self.tv.height
                )
            }
            if isChannelShown, !isOff {
                BarPixelText(
                    "Ch\(channel + 1)", x: Self.tv.x + 5, y: Self.tv.y + 2,
                    color: UIColor(BarInk.channel), mono: true
                )
            }
            BarHitArea(
                x: Self.tv.x, y: Self.tv.y, width: Self.tv.width, height: Self.tv.height,
                label: BarCopy.tv
            ) {
                channel = (channel + 1) % Self.channels.count
                shownAt = Date()
            }
            BarSprite(name: "fan", x: Self.fan.x, y: Self.fan.y, width: 24, height: 24)
                .rotationEffect(.degrees(Double(frame) * 30), anchor: .center)
        }
        .onReceive(timer) { _ in frame = (frame + 1) % 10_080 }
    }
}
