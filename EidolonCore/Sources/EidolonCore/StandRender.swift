import Foundation

/// How much of her the stand shows (spec「渲染」). The call screen picks by width:
/// phones held upright show her down to the knees, wider screens down to the waist;
/// the outfit preview later uses `full`.
public enum StandFraming: String, Sendable, Hashable, CaseIterable {
    /// Down to her knees.
    case knees
    /// Down to her waist.
    case waist
    /// All of her, with a little room all around.
    case full

    /// Phones held upright are compact; anything wider (iPad, landscape) is regular.
    public init(compactWidth: Bool) {
        self = compactWidth ? .knees : .waist
    }

    /// The height of the framing, as a share of her body; `full` fits all of her instead.
    private var heightShare: Double {
        switch self {
        case .knees: 0.85
        case .waist: 0.66
        case .full: 1
        }
    }

    /// The framing is never narrower than this share of her body's width, so a tall
    /// phone screen does not end up showing only her face.
    private static let minimumWidthShare = 0.7
    /// Room above her head (on every side for `full`), as a share of her body's height.
    private static let headroom = 0.03

    /// Where the camera goes so `bounds` (her range in the skeleton's own coordinates)
    /// fills a view that is `aspect` (width / height) wide. The upstream `aim`.
    public func camera(bounds: StandBounds, aspect: Double) -> StandCamera {
        let aspect = aspect > 0 ? aspect : 1
        if self == .full {
            // All of her: fit her whole body and width, centred, with room all around.
            let height = max(bounds.height, bounds.width / aspect)
                * (1 + 2 * Self.headroom)
            return StandCamera(
                x: bounds.x + bounds.width / 2,
                y: bounds.y + bounds.height / 2,
                viewportWidth: height * aspect,
                viewportHeight: height
            )
        }
        let height = max(
            bounds.height * heightShare,
            bounds.width * Self.minimumWidthShare / aspect
        )
        let top = bounds.y + bounds.height * (1 + Self.headroom)
        return StandCamera(
            x: bounds.x + bounds.width / 2,
            y: top - height / 2,
            viewportWidth: height * aspect,
            viewportHeight: height
        )
    }
}

/// The range her skeleton takes up at rest, in its own coordinates (what
/// `skeleton.getBounds` gives the player). Also what tells the camera where her head is.
public struct StandBounds: Codable, Sendable, Hashable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// Where the player's camera sits for the current framing: this is all the player
/// needs to know about framing.
public struct StandCamera: Codable, Sendable, Hashable {
    public var x: Double
    public var y: Double
    public var viewportWidth: Double
    public var viewportHeight: Double

    public init(x: Double, y: Double, viewportWidth: Double, viewportHeight: Double) {
        self.x = x
        self.y = y
        self.viewportWidth = viewportWidth
        self.viewportHeight = viewportHeight
    }
}

/// Her emotion (GLOSSARY.md「情绪」).
public enum StandEmotion: String, Codable, Sendable, Hashable, CaseIterable {
    case calm
    case happy
    case shy
    case surprised
    case sad
    case angry
    case thinking
}

/// A nod (`yes`) or a shake of the head (`no`); each gets a new id, so it plays once.
public struct StandNod: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable, Hashable {
        case yes
        case no
    }

    public var kind: Kind
    public var id: Int

    public init(kind: Kind, id: Int) {
        self.kind = kind
        self.id = id
    }
}

/// How she should look right now, with no word of which animations do it. The call
/// screen's directives (#31) build this from the call's events.
public struct StandDirection: Codable, Sendable, Hashable {
    /// Her emotion over the call so far.
    public var mood: StandEmotion
    /// Her mouth is moving.
    public var speaking: Bool
    /// She looks at the producer.
    public var looking: Bool
    public var nod: StandNod?

    public init(mood: StandEmotion, speaking: Bool, looking: Bool, nod: StandNod?) {
        self.mood = mood
        self.speaking = speaking
        self.looking = looking
        self.nod = nod
    }

    /// How she looks when a call starts.
    public static let calm = StandDirection(mood: .calm, speaking: false, looking: false, nod: nil)
}

/// What to play on each of the player's five tracks, by animation name (ADR-0017:
/// the animation table lives in Swift, the player only plays). The animation table
/// (#31) will build these from a `StandDirection` and the animations an outfit has.
public struct StandPose: Codable, Sendable, Hashable {
    /// Track 0, looped.
    public var body: String
    /// Track 1, looped; `blank` hands the face back to the body's own expression.
    public var face: String
    /// Track 5: her talking mouth, looping while open and held on its first frame
    /// while shut; nil leaves the track empty.
    public var mouth: Mouth?
    /// Track 3, looped; nil leaves the track empty.
    public var eye: String?
    /// Track 2, played once; nil leaves the track empty.
    public var nod: Nod?

    public struct Mouth: Codable, Sendable, Hashable {
        public var name: String
        public var open: Bool

        public init(name: String, open: Bool) {
            self.name = name
            self.open = open
        }
    }

    public struct Nod: Codable, Sendable, Hashable {
        public var name: String
        public var id: Int

        public init(name: String, id: Int) {
            self.name = name
            self.id = id
        }
    }

    public init(
        body: String,
        face: String,
        mouth: Mouth? = nil,
        eye: String? = nil,
        nod: Nod? = nil
    ) {
        self.body = body
        self.face = face
        self.mouth = mouth
        self.eye = eye
        self.nod = nod
    }

    /// What she looks like with nothing going on: the calm body and face, mouth shut.
    /// Every outfit carries `wait` and `face_wait`; #31 will pick from what an outfit
    /// actually has.
    public static let calm = StandPose(body: "wait", face: "face_wait")

    /// The JSON the player receives. Keys are sorted, so the wire shape is stable.
    public func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    /// What the player reports once an outfit is loaded: every animation's name and
    /// duration, and her range at rest (for the camera).
    public struct Report: Decodable, Sendable, Hashable {
        public var animations: [String: Double]
        public var bounds: StandBounds

        public init(animations: [String: Double], bounds: StandBounds) {
            self.animations = animations
            self.bounds = bounds
        }
    }
}

/// Which files the stand's local page may fetch. The page and the player are served
/// from the app bundle; her outfits come from the installed content bundle and from
/// nowhere else (ADR-0017).
public enum StandAssets {
    /// The part of an outfit's `directory` that lies under `contentRoot`, slash-terminated
    /// (for example `stand/idols/stand/1030010010/`); nil when it lies elsewhere.
    public static func relativeDirectory(of directory: URL, under contentRoot: URL) -> String? {
        let root = resolved(contentRoot)
        let directory = resolved(directory)
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard directory.hasPrefix(prefix) else { return nil }
        let relative = String(directory.dropFirst(prefix.count))
        return relative.isEmpty ? nil : relative + "/"
    }

    /// The file a request path names under `root`; nil when the path is not an
    /// absolute path inside the root (parent traversal, percent-encoded traversal and
    /// symlinks out of the root are all refused).
    public static func file(at requestPath: String, under root: URL) -> URL? {
        guard requestPath.hasPrefix("/"),
              let decoded = requestPath.removingPercentEncoding,
              !decoded.contains("\0")
        else { return nil }
        let relative = String(decoded.dropFirst())
        guard !relative.isEmpty else { return nil }
        let components = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains(where: { $0 == ".." || $0 == "." }) else { return nil }

        let rootPath = resolved(root)
        let candidate = resolved(root.appendingPathComponent(relative))
        guard candidate.hasPrefix(rootPath + "/") else { return nil }
        return URL(fileURLWithPath: candidate)
    }

    /// The standardised path with symlinks followed, so a link cannot smuggle a file
    /// in from outside the allowed root.
    private static func resolved(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
