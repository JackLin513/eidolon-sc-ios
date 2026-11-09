import Foundation

/// The `model3d` package manifest: one package per franchise, declaring which characters
/// have a 3D model, which outfits they carry, and which emotion maps to which native face.
/// It deliberately contains no acquisition or extraction instructions; the files are
/// produced on the producer's own machine.
public struct Model3DManifest: Codable, Sendable, Hashable {
    public static let supportedFormatVersion = 1

    public var formatVersion: Int
    public var kind: ContentKind
    public var franchise: String
    public var runtime: RuntimeRequirement
    public var capabilities: RuntimeCapabilities
    public var files: [Model3DFile]
    public var characters: [Model3DCharacter]
    public var legal: LegalNotice?

    public init(
        formatVersion: Int = supportedFormatVersion,
        kind: ContentKind = .model3d,
        franchise: String,
        runtime: RuntimeRequirement = RuntimeRequirement(
            preferred: .unityUaaL,
            engineVersion: nil,
            fallbacks: [.spineWebGL, .avatar]
        ),
        capabilities: RuntimeCapabilities = .unity3D,
        files: [Model3DFile],
        characters: [Model3DCharacter],
        legal: LegalNotice? = nil
    ) {
        self.formatVersion = formatVersion
        self.kind = kind
        self.franchise = franchise
        self.runtime = runtime
        self.capabilities = capabilities
        self.files = files
        self.characters = characters
        self.legal = legal
    }

    /// The character with this local id, if this package carries one.
    public func character(localID: String) -> Model3DCharacter? {
        characters.first { $0.localID == localID }
    }

    /// Structural checks that do not need the files on disk. Throws a readable error so an
    /// installer can refuse the package instead of failing later.
    public func validate(expectedEngineVersion: String? = nil) throws {
        guard formatVersion == Self.supportedFormatVersion else {
            throw Model3DManifestError.unsupportedFormat(formatVersion)
        }
        guard kind == .model3d else {
            throw Model3DManifestError.wrongKind(kind.rawValue)
        }
        guard !franchise.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Model3DManifestError.missingFranchise
        }
        if let expectedEngineVersion, let actual = runtime.engineVersion,
           actual != expectedEngineVersion {
            throw Model3DManifestError.engineVersionMismatch(
                expected: expectedEngineVersion,
                actual: actual
            )
        }
        var paths = Set<String>()
        for file in files {
            try file.validate()
            guard paths.insert(file.path).inserted else {
                throw Model3DManifestError.duplicateFile(file.path)
            }
        }
        var ids = Set<String>()
        for character in characters {
            try character.validate()
            guard ids.insert(character.localID).inserted else {
                throw Model3DManifestError.duplicateCharacter(character.localID)
            }
        }
    }
}

/// One file in the package. `path` is package-relative and must not escape the package;
/// `sha256` is the lowercase hex digest the installer verifies.
public struct Model3DFile: Codable, Sendable, Hashable {
    public var path: String
    public var sha256: String
    public var size: Int

    public init(path: String, sha256: String, size: Int) {
        self.path = path
        self.sha256 = sha256
        self.size = size
    }

    public func validate() throws {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.split(separator: "/").contains(where: { $0 == ".." || $0 == "." })
        else {
            throw Model3DManifestError.unsafePath(path)
        }
        guard sha256.count == 64,
              sha256.allSatisfy({ $0.isHexDigit })
        else {
            throw Model3DManifestError.invalidChecksum(path)
        }
        guard size >= 0 else {
            throw Model3DManifestError.invalidSize(path)
        }
    }
}

/// One character in a `model3d` package: the app's local character id, the native model
/// name, its outfits, and the emotion→native face map.
public struct Model3DCharacter: Codable, Sendable, Hashable {
    public var localID: String
    public var model: String
    public var outfits: [String]
    public var emotionMap: [String: String]
    public var bounds: StandBounds?

    public init(
        localID: String,
        model: String,
        outfits: [String],
        emotionMap: [String: String] = [:],
        bounds: StandBounds? = nil
    ) {
        self.localID = localID
        self.model = model
        self.outfits = outfits
        self.emotionMap = emotionMap
        self.bounds = bounds
    }

    public func validate() throws {
        guard !localID.isEmpty, !model.isEmpty else {
            throw Model3DManifestError.missingCharacterIdentity(localID)
        }
        guard !outfits.isEmpty, outfits.allSatisfy({ !$0.isEmpty }) else {
            throw Model3DManifestError.missingOutfits(localID)
        }
        for key in emotionMap.keys where StandEmotion(rawValue: key) == nil {
            throw Model3DManifestError.unknownEmotion(key: key, localID: localID)
        }
    }

    /// The native face for an app emotion, if this model declares one.
    public func nativeFace(for emotion: StandEmotion) -> String? {
        emotionMap[emotion.rawValue]
    }
}

public enum Model3DManifestError: Error, Equatable, Sendable, CustomStringConvertible {
    case unsupportedFormat(Int)
    case wrongKind(String)
    case missingFranchise
    case engineVersionMismatch(expected: String, actual: String)
    case duplicateFile(String)
    case duplicateCharacter(String)
    case unsafePath(String)
    case invalidChecksum(String)
    case invalidSize(String)
    case missingCharacterIdentity(String)
    case missingOutfits(String)
    case unknownEmotion(key: String, localID: String)

    public var description: String {
        switch self {
        case .unsupportedFormat(let version): "不支持的 model3d 包格式 v\(version)"
        case .wrongKind(let kind): "包类型是 \(kind)，不是 model3d"
        case .missingFranchise: "model3d 包没有声明企划"
        case .engineVersionMismatch(let expected, let actual):
            "引擎版本不匹配：需要 \(expected)，包是 \(actual)"
        case .duplicateFile(let path): "包内文件重复：\(path)"
        case .duplicateCharacter(let id): "包内角色重复：\(id)"
        case .unsafePath(let path): "包内路径不安全：\(path)"
        case .invalidChecksum(let path): "文件校验值不合法：\(path)"
        case .invalidSize(let path): "文件大小不合法：\(path)"
        case .missingCharacterIdentity(let id): "角色缺少 id 或模型名：\(id)"
        case .missingOutfits(let id): "角色没有衣装：\(id)"
        case .unknownEmotion(let key, let id): "角色 \(id) 的情绪名不合法：\(key)"
        }
    }
}
