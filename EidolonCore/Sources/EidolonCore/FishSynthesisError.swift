import Foundation

/// What Fish Audio answered, or failed to, for one segment of a call (upstream
/// `call.FishTTS`).
public enum FishSynthesisError: LocalizedError {
    case missingKey
    case noResponse
    case empty
    case status(Int, String)

    public var errorDescription: String? {
        switch self {
        case .missingKey:
            "还没有填 Fish Audio 的密钥"
        case .noResponse:
            "Fish Audio 没有回应"
        case .empty:
            "Fish Audio 没有说话"
        case let .status(code, detail):
            "Fish Audio 出错（\(code)）：\(detail)"
        }
    }

    /// Whether Fish Audio itself cannot speak for this call, rather than this one segment
    /// being lost (ADR-0011, #35 no. 37).
    ///
    /// A missing or refused key, no credit, and an empty answer are the service: no
    /// segment will work, so retrying another one only leaves the producer talking into
    /// silence. 400, 404 and 422 are about the request — a voice or model it does not
    /// serve, text it refuses — and end the call only while it has never made a segment;
    /// once one has been made, the next such answer is that segment lost and the reply
    /// goes on. A timeout, a dropped connection or a 5xx is only this segment lost too.
    public func serviceFailure(hasSynthesized: Bool) -> VoiceServiceFailure? {
        switch self {
        case .missingKey:
            return VoiceServiceFailure(service: "Fish Audio", detail: "还没有填密钥")
        case .empty:
            return VoiceServiceFailure(service: "Fish Audio", detail: "返回的音频是空的")
        case let .status(code, detail):
            if Self.alwaysFails.contains(code)
                || (Self.failsUntilVoiced.contains(code) && !hasSynthesized) {
                return VoiceServiceFailure(service: "Fish Audio", detail: "\(code) \(detail)")
            }
            return nil
        case .noResponse:
            return nil
        }
    }

    /// The statuses that mean the service cannot speak for this call at all: no key or a
    /// refused one, no credit. Retrying another segment will not help.
    static let alwaysFails: Set<Int> = [401, 402, 403]
    /// The statuses that may be about this request: a voice or model it does not serve,
    /// text it refuses. They end a call that has not voiced anything yet, and are a lost
    /// segment after it has.
    static let failsUntilVoiced: Set<Int> = [400, 404, 422]
}
