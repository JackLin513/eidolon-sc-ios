import EidolonCore

/// A change of her affinity just recorded, shown for a moment; `key` tells one from the
/// next so a second change restarts the moment (spec #38, upstream `AffinityCue`).
struct AffinityCue: Hashable {
    var change: AffinityChange
    var key: Int
}
