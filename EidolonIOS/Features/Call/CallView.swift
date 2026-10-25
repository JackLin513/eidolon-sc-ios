import EidolonCore
import SwiftUI

/// The call screen: her likeness behind, what she is doing, the subtitles of what was
/// said, and the way to hang up. It only shows what `CallSession` reports (ADR-0015).
struct CallView: View {
    let character: CharacterConfig

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var session: CallSession?
    @State private var state: CallState = .connecting
    @State private var lines: [CallLine] = []
    @State private var hearing: String?
    @State private var failure: String?
    @State private var startError: String?
    @State private var started = false

    var body: some View {
        ZStack {
            background
            VStack(spacing: 24) {
                header
                Spacer(minLength: 0)
                if let startError {
                    startFailure(startError)
                } else {
                    subtitles
                }
                Spacer(minLength: 0)
                footer
            }
            .padding(.top, 32)
            .padding(.bottom, 28)
        }
        .task { await start() }
        .interactiveDismissDisabled(session != nil && !isEnded)
    }

    private var isEnded: Bool {
        if case .ended = state { return true }
        return false
    }

    // MARK: - Start

    private func start() async {
        guard !started else { return }
        started = true
        do {
            let call = try await app.beginCall(for: character)
            session = call
            let events = call.events()
            await call.start()
            autoHangUpIfRequested(call)
            for await event in events {
                handle(event)
            }
        } catch {
            startError = error.localizedDescription
        }
    }

    /// Development aid: `SIMCTL_CHILD_EIDOLON_CALL_HANGUP_MS` ends the call by itself,
    /// so the record it leaves can be seen without tapping.
    private func autoHangUpIfRequested(_ call: CallSession) {
        #if DEBUG
        guard let text = ProcessInfo.processInfo.environment["EIDOLON_CALL_HANGUP_MS"],
              let milliseconds = Int(text), milliseconds >= 0
        else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(milliseconds))
            await call.hangUp()
        }
        #endif
    }

    private func handle(_ event: CallEvent) {
        switch event {
        case let .state(next):
            state = next
        case let .hearing(text):
            hearing = text.isEmpty ? nil : text
        case let .recognized(text):
            hearing = nil
            failure = nil
            lines.append(CallLine(speaker: .producer, ja: text, zh: ""))
        case let .segment(_, ja, zh):
            lines.append(CallLine(speaker: .her, ja: ja, zh: zh))
        case let .failed(message):
            failure = message
        }
        trimLines()
    }

    /// The call keeps the last few lines on screen; older ones are in the conversation.
    private func trimLines() {
        if lines.count > 8 { lines.removeFirst(lines.count - 8) }
    }

    // MARK: - Pieces

    private var background: some View {
        GeometryReader { geometry in
            Group {
                if let image = app.avatar(for: character.id) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                        .blur(radius: 18)
                    Color.black.opacity(0.55)
                } else {
                    Color(hex: character.color ?? "#333333")
                        .overlay(Color.black.opacity(0.35))
                }
            }
        }
        .ignoresSafeArea()
    }

    private var header: some View {
        VStack(spacing: 8) {
            Text(character.name)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
            HStack(spacing: 8) {
                Circle()
                    .fill(stateTint)
                    .frame(width: 8, height: 8)
                Text(stateText)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.85))
            }
            if let failure {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .padding(.horizontal, 24)
            }
        }
    }

    private var stateText: String {
        switch state {
        case .connecting: "正在接通…"
        case .listening: "在听"
        case .thinking: "在想"
        case .speaking: "在说"
        case .reconnecting: "重连中…"
        case let .ended(reason):
            // The full reason is in the footer; the header stays one line.
            if case .failed = reason { "通话中断了" } else { reasonText(reason) }
        }
    }

    private var stateTint: Color {
        switch state {
        case .listening: .green
        case .thinking: .yellow
        case .speaking: .blue
        case .reconnecting: .orange
        case .connecting: .gray
        case .ended: .red
        }
    }

    private func reasonText(_ reason: CallEnd) -> String {
        switch reason {
        case .hungUpByProducer: "通话已结束"
        case .timeLimit: "通话到了时限，已结束"
        case let .failed(message): "通话中断了：\(message)"
        }
    }

    private var subtitles: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 14) {
                    ForEach(lines) { line in
                        subtitle(line)
                            .id(line.id)
                    }
                    if let hearing {
                        HStack {
                            Spacer(minLength: 30)
                            Text(hearing)
                                .font(.callout)
                                .italic()
                                .foregroundStyle(.white.opacity(0.55))
                        }
                        .id("hearing")
                    }
                }
                .padding(.horizontal, 24)
                .frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: lines.count) {
                proxy.scrollTo(lines.last?.id, anchor: .bottom)
            }
            .onChange(of: hearing) {
                proxy.scrollTo("hearing", anchor: .bottom)
            }
        }
    }

    @ViewBuilder
    private func subtitle(_ line: CallLine) -> some View {
        switch line.speaker {
        case .her:
            VStack(spacing: 4) {
                Text(line.ja)
                    .font(.title3)
                    .foregroundStyle(.white)
                if !line.zh.isEmpty {
                    Text(line.zh)
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.65))
                }
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
        case .producer:
            HStack {
                Spacer(minLength: 30)
                Text(line.ja)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.trailing)
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 12) {
            if isEnded, case let .ended(reason) = state {
                Text(reasonText(reason))
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.7))
                Button("返回") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .tint(.white.opacity(0.25))
            } else {
                Button {
                    Task {
                        await session?.hangUp()
                        dismiss()
                    }
                } label: {
                    Image(systemName: "phone.down.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(.white)
                        .frame(width: 64, height: 64)
                        .background(Color.red, in: Circle())
                }
                .disabled(session == nil)
            }
        }
    }

    private func startFailure(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "phone.down")
                .font(.system(size: 30))
                .foregroundStyle(.white.opacity(0.7))
            Text(message)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("返回") { dismiss() }
                .buttonStyle(.bordered)
                .tint(.white)
        }
    }
}

private struct CallLine: Identifiable {
    enum Speaker {
        case her
        case producer
    }

    let id = UUID()
    let speaker: Speaker
    let ja: String
    let zh: String
}
