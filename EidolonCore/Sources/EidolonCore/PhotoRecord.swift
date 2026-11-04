import CoreGraphics
import Foundation

public enum PhotoStatus: String, Codable, Sendable, Hashable {
    case pending
    case ready
    case failed
}

public enum PhotoFailureReason: String, Codable, Sendable, Hashable {
    case timeout
    case serviceError = "service_error"
    case badImage = "bad_image"
    case usedUp = "used_up"

    /// The few words the failure line puts after 照片没发出来.
    public var shortText: String {
        switch self {
        case .timeout: "超时了"
        case .serviceError: "生图服务出错"
        case .badImage: "图不对"
        case .usedUp: "这一小时的额度用完了"
        }
    }
}

/// The one picture size the image service is asked for (upstream `832×1216`), shared by
/// the request, the saved row and the views so they cannot drift apart.
public enum PhotoGeometry {
    public static let width = 832
    public static let height = 1216
    public static let aspectRatio = CGFloat(width) / CGFloat(height)
    /// The width a picture takes in a chat bubble.
    public static let bubbleWidth: CGFloat = 192
}

/// What a conversation row says about a photo without reading the image itself.
public struct PhotoReference: Sendable, Hashable {
    public var id: String
    public var status: PhotoStatus
    public var reason: PhotoFailureReason?

    public init(id: String, status: PhotoStatus, reason: PhotoFailureReason? = nil) {
        self.id = id
        self.status = status
        self.reason = reason
    }
}

/// What a turn needs to try a photo. It is absent when the producer has not configured an
/// image service; the turn then behaves exactly as before.
public struct PhotoTurnContext: Sendable {
    public var generator: any ImageGenerating
    public var settings: ImageServiceSettings

    public init(generator: any ImageGenerating, settings: ImageServiceSettings) {
        self.generator = generator
        self.settings = settings
    }

    public var isConfigured: Bool { settings.isConfigured }
}

struct PhotoDraft: Sendable {
    var id: String
    var tag: PhotoTag
    var startedAt: Date
    var status: PhotoStatus = .pending
    var reason: PhotoFailureReason?
    var data: Data?
    var fileName: String?
    var finishedAt: Date?
    var messageID: String?
    var conversationID: String?
}
