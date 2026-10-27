import Foundation

/// The keepalive Soniox's live transcription needs. While her own voice plays the microphone
/// is closed, so no audio is sent; a connection that sees no traffic for long enough is
/// closed by the service, and the producer's next words are lost in the reconnect. Pipecat
/// checks every 5 seconds and sends a protocol keepalive once 1 second has passed without
/// audio (pipecat `soniox/stt.py` sets `keepalive_timeout=1`, `keepalive_interval=5`).
public enum SonioxKeepalive {
    /// How often the connection is checked.
    public static let interval: Duration = .seconds(5)
    /// How long without audio makes a keepalive due.
    public static let idle: Duration = .seconds(1)
    /// What is sent: Soniox's own keepalive message, not silence.
    public static let message = #"{"type": "keepalive"}"#

    /// Whether the connection should be kept alive now: it has gone `idle` without audio.
    public static func isDue(now: Date, lastAudio: Date) -> Bool {
        now.timeIntervalSince(lastAudio) >= idle.inSeconds
    }
}
