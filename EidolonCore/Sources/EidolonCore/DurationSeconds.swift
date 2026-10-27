import Foundation

extension Duration {
    /// The length in seconds, fractions and all. `components` splits a `Duration` into
    /// whole seconds and attoseconds, which every clock, limit and keepalive here needs
    /// as one number.
    var inSeconds: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
