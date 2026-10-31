import EidolonCore
import Foundation
import Observation

/// The one call the app is in (spec #46, upstream ADR-0018): the session, what it has said,
/// whether the layer is folded away, and the one moment it started and ended. It belongs to
/// the app, not to the chat page, so changing pages neither hangs up nor loses any of it.
@MainActor
@Observable
final class CallController {
    /// What the shell draws: nothing, the open layer, or the folded layer with its bar.
    private(set) var layer: CallLayer = .absent
    /// Who the call is with; nil when there is none.
    private(set) var character: CharacterConfig?
    private(set) var session: CallSession?
    private(set) var state: CallState = .connecting
    /// The line she is saying now; older ones are in the conversation.
    private(set) var line: HerLine?
    /// The segment right before it in the same reply, kept faint above it while 只看文字
    /// is on (upstream `LineCard`).
    private(set) var previousLine: HerLine?
    private(set) var hearing: String?
    /// Whether this call's microphone is closed. It belongs to the one call only: a redial
    /// starts with the microphone open, as upstream's 麦克风静音 does (spec #43).
    private(set) var muted = false
    private(set) var failure: String?
    private(set) var startError: String?
    /// What the microphone is doing that she cannot tell the producer herself (spec #41).
    private(set) var micNotice: MicNotice?
    /// When the call connected, for the status line; nil until it does.
    private(set) var connectedAt: Date?
    /// When it ended, for how long it lasted.
    private(set) var endedAt: Date?
    /// What her stand shows; her events move it.
    private(set) var stand = CallStandDirector()

    /// Whether her replies are read as text rather than voiced. It stays on this phone
    /// between calls (spec #43), and is set on the call before it starts.
    private(set) var textOnly: Bool

    private weak var app: AppModel?
    private var events: Task<Void, Never>?
    /// The producer left to another character: the end is real, but its card is not shown.
    private var leaving = false

    private static let textOnlyKey = "call.textOnly"

    init() {
        textOnly = UserDefaults.standard.bool(forKey: Self.textOnlyKey)
    }

    func attach(_ app: AppModel) {
        self.app = app
    }

    /// The layer is on screen, open or folded.
    var isPresent: Bool { layer != .absent }

    var isCollapsed: Bool { layer == .collapsed }

    /// Dialing or connected; not ended, not absent.
    var isLive: Bool {
        if case .ended = state { return false }
        return session != nil
    }

    var isEnded: Bool {
        if case .ended = state { return true }
        return false
    }

    /// Whether the call under way is with this character.
    func isCalling(_ characterID: String) -> Bool {
        isLive && character?.id == characterID
    }

    /// The bar only while a call is under way and folded.
    var showsBar: Bool {
        layer.showsBar(live: isLive)
    }

    /// She hung up for a cooldown: there is no calling her until it ends, so no redial
    /// (upstream `endCard`).
    var canRedial: Bool {
        guard case let .ended(reason) = state else { return false }
        if case let .sheHungUp(until) = reason, until != nil { return false }
        return true
    }

    // MARK: - The call

    /// Dials her. The layer opens over the page that asked, and stays mounted after that.
    func start(_ character: CharacterConfig) async {
        guard !isLive else { return }
        self.character = character
        await dial()
    }

    /// A fresh call with the same character, after one ended.
    func redial() {
        guard canRedial, character != nil else { return }
        Task { await dial() }
    }

    private func dial() async {
        guard let app, let character else { return }
        events?.cancel()
        resetForDial()
        layer = .dialing
        do {
            let call = try await app.beginCall(for: character)
            session = call
            // The remembered 只看文字 is set before she starts, so the first reply already
            // follows it (spec #43).
            await call.setTextOnly(textOnly)
            let stream = call.events()
            await call.start()
            autoHangUpIfRequested(call)
            events = Task { @MainActor [weak self] in
                for await event in stream {
                    guard let self, self.session != nil else { break }
                    self.handle(event)
                }
            }
        } catch {
            startError = error.localizedDescription
        }
    }

    /// What belongs to one call, cleared before a redial so nothing of the last one shows.
    private func resetForDial() {
        session = nil
        resetCall()
    }

    /// Everything one call left, keeping the character the layer is drawn for.
    private func resetCall() {
        state = .connecting
        line = nil
        previousLine = nil
        hearing = nil
        muted = false
        failure = nil
        startError = nil
        micNotice = nil
        connectedAt = nil
        endedAt = nil
        stand = CallStandDirector()
        leaving = false
    }

    private func handle(_ event: CallEvent) {
        switch event {
        case let .state(next):
            state = next
            // The call is connected when the recognizer can hear, not when the microphone
            // opens (spec「接通」): listening is the first state that means that.
            if connectedAt == nil, case .listening = next {
                connectedAt = Date()
                layer = layer.connected()
            }
            if case .ended = next {
                if endedAt == nil { endedAt = Date() }
                if !leaving { layer = layer.ended() }
            }
        case let .hearing(text):
            hearing = text.isEmpty ? nil : text
        case .recognized:
            hearing = nil
            failure = nil
        case let .segment(reply, segment, ja, zh):
            // The segment before this one in the same reply stays faint above it while
            // 只看文字 is on (upstream `LineCard`). A new reply starts a fresh card.
            previousLine = line?.reply == reply ? line : nil
            line = HerLine(reply: reply, segment: segment, ja: ja, zh: zh)
        case let .failed(message):
            failure = message
        case let .micNotice(notice):
            micNotice = notice
        case .segmentStarted, .segmentStopped, .emotion:
            break
        }
        stand.apply(event)
    }

    // MARK: - Folding

    func collapse() {
        layer = layer.collapsing(live: isLive)
    }

    func expand() {
        layer = layer.expanding(live: isLive)
    }

    // MARK: - The keys

    func toggleMuted() {
        muted.toggle()
        let muted = muted
        Task { await session?.setMuted(muted) }
    }

    func toggleTextOnly() {
        textOnly.toggle()
        UserDefaults.standard.set(textOnly, forKey: "call.textOnly")
        let on = textOnly
        Task { await session?.setTextOnly(on) }
    }

    func hangUp() async {
        await session?.hangUp()
    }

    /// Leaving for another character: the layer goes at once and the session hangs up as
    /// the producer in the background, recording everything, so the page can be opened
    /// without waiting out the tone and the microphone teardown (spec #46).
    func hangUpAndLeave() {
        leaving = true
        let call = session
        clear()
        Task { await call?.hangUp() }
    }

    /// The end card's 返回, or a failed dial's 返回: the layer leaves the screen.
    func returnFromCall() {
        app?.callTones.silence()
        clear()
    }

    func recoverAudio() async {
        await session?.recoverAudio()
    }

    private func clear() {
        events?.cancel()
        events = nil
        session = nil
        character = nil
        layer = .absent
        resetCall()
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
}

/// Which reply and which segment of it this is, so the call's card can tell a continued
/// line from the start of a new one.
struct HerLine {
    let reply: Int
    let segment: Int
    let ja: String
    let zh: String
}
