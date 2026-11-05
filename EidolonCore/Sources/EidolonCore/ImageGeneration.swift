import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import ZIPFoundation

/// How an image service is spoken to. The person who configures it chooses; the app
/// never probes.
public enum ImageAPIFormat: String, Codable, Sendable, CaseIterable, Identifiable {
    case novelai
    case openai

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .novelai: "NovelAI 原生格式"
        case .openai: "OpenAI 图像格式"
        }
    }
}

public enum GPTImageQuality: String, Codable, Sendable, CaseIterable, Identifiable {
    case low
    case medium
    case high
    case auto

    public var id: String { rawValue }
    public var title: String { rawValue }
}

/// One image service as the settings page configures it. `apiKey` is kept separately from
/// the non-secret fields in `ChatSettings`, and only reaches this value for a request.
public struct ImageServiceSettings: Sendable, Equatable {
    public var apiFormat: ImageAPIFormat
    public var baseURL: String
    public var model: String
    public var adultModel: String
    public var style: String
    public var hourlyLimit: Int
    public var apiKey: String

    public static let defaultBaseURL = "https://image.novelai.net"
    public static let defaultModel = "nai-diffusion-5-curated"
    public static let defaultAdultModel = "nai-diffusion-5-full"
    public static let defaultHourlyLimit = 5
    /// What the settings' 试一张 uses on NovelAI: the older, cheaper 4.5 Curated model,
    /// so confirming the key and the address costs less (spec #98's try-out rule).
    public static let testModel = "nai-diffusion-4-5-curated"

    public init(
        apiFormat: ImageAPIFormat = .novelai,
        baseURL: String = ImageServiceSettings.defaultBaseURL,
        model: String = ImageServiceSettings.defaultModel,
        adultModel: String = ImageServiceSettings.defaultAdultModel,
        style: String = "",
        hourlyLimit: Int = ImageServiceSettings.defaultHourlyLimit,
        apiKey: String = ""
    ) {
        self.apiFormat = apiFormat
        self.baseURL = baseURL
        self.model = model
        self.adultModel = adultModel
        self.style = style
        self.hourlyLimit = hourlyLimit
        self.apiKey = apiKey
    }

    public var isConfigured: Bool {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let url = URL(string: baseURL),
              url.scheme != nil, url.host != nil
        else { return false }
        return true
    }

    public var endpoint: URL? {
        guard let base = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        switch apiFormat {
        case .novelai:
            return base.appendingPathComponent("ai/generate-image")
        case .openai:
            return base.appendingPathComponent("images/generations")
        }
    }

    /// The same service with the cheaper model 试一张 draws on. An OpenAI-shaped relay
    /// names its own models, so there the configured model stays as it is.
    public var testSettings: ImageServiceSettings {
        guard apiFormat == .novelai else { return self }
        var settings = self
        settings.model = Self.testModel
        return settings
    }
}

/// GPT Image, for the moments pictures no one is in. It is optional and separate from the
/// photo service.
public struct GPTImageSettings: Sendable, Equatable {
    public var enabled: Bool
    public var baseURL: String
    public var model: String
    public var quality: GPTImageQuality
    public var style: String
    public var apiKey: String

    public static let defaultBaseURL = "https://api.openai.com/v1"
    public static let defaultModel = "gpt-image-2"
    public static let defaultStyle =
        "Flat cel-shaded anime background art, like a background painting from a TV anime:"
        + " clean line art, cel shading, simplified shapes and details, soft flat colors."
        + " It must look hand-drawn, never photographic: no lens effects, no HDR,"
        + " no photo-real textures."

    public init(
        enabled: Bool = false,
        baseURL: String = GPTImageSettings.defaultBaseURL,
        model: String = GPTImageSettings.defaultModel,
        quality: GPTImageQuality = .medium,
        style: String = GPTImageSettings.defaultStyle,
        apiKey: String = ""
    ) {
        self.enabled = enabled
        self.baseURL = baseURL
        self.model = model
        self.quality = quality
        self.style = style
        self.apiKey = apiKey
    }

    public var isConfigured: Bool {
        enabled
            && !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && URL(string: baseURL)?.host != nil
    }

    public var endpoint: URL? {
        guard let base = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        return base.appendingPathComponent("images/generations")
    }
}

public struct ImageRequest: Sendable, Equatable {
    /// The whole prompt, for services that take one string.
    public var prompt: String
    /// NovelAI's V4/V5 captions split the scene from the character: the base prompt
    /// carries the scene, style and quality tags, and the character prompt carries only
    /// her. With one caption every one of those tags is sent twice.
    public var basePrompt: String?
    public var characterPrompt: String?
    public var negativePrompt: String
    public var width: Int
    public var height: Int
    public var model: String
    public var seed: UInt32

    public init(
        prompt: String,
        basePrompt: String? = nil,
        characterPrompt: String? = nil,
        negativePrompt: String,
        width: Int,
        height: Int,
        model: String,
        seed: UInt32 = UInt32.random(in: 0...(UInt32.max - 7))
    ) {
        self.prompt = prompt
        self.basePrompt = basePrompt
        self.characterPrompt = characterPrompt
        self.negativePrompt = negativePrompt
        self.width = width
        self.height = height
        self.model = model
        self.seed = seed
    }
}

public enum ImageGenerationError: LocalizedError, Equatable {
    case missingKey
    case invalidAddress
    case timeout
    case serviceError(String)
    case badImage(String)

    public var errorDescription: String? {
        switch self {
        case .missingKey: "没有填写生图密钥"
        case .invalidAddress: "生图接口地址不对"
        case .timeout: "生图服务没有及时回应"
        case let .serviceError(detail): "生图服务出错：\(detail)"
        case let .badImage(detail): "生成的图不对：\(detail)"
        }
    }
}

/// A response from an image service, already detached from URLSession so tests and the
/// production client share the same boundary.
public struct ImageHTTPResponse: Sendable {
    public var statusCode: Int
    public var body: Data

    public init(statusCode: Int, body: Data) {
        self.statusCode = statusCode
        self.body = body
    }
}

public protocol ImageHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> ImageHTTPResponse
}

public struct URLSessionImageTransport: ImageHTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> ImageHTTPResponse {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ImageGenerationError.serviceError("没有 HTTP 回应")
        }
        return ImageHTTPResponse(statusCode: http.statusCode, body: data)
    }
}

public protocol ImageGenerating: Sendable {
    func generate(_ request: ImageRequest, settings: ImageServiceSettings) async throws -> Data
}

public protocol GPTImageGenerating: Sendable {
    func generate(_ request: ImageRequest, settings: GPTImageSettings) async throws -> Data
}

/// The production client: one request, one checked and re-encoded JPEG.
public struct RemoteImageGenerator: ImageGenerating {
    private let transport: any ImageHTTPTransport

    public init(transport: any ImageHTTPTransport = URLSessionImageTransport()) {
        self.transport = transport
    }

    public func generate(
        _ request: ImageRequest,
        settings: ImageServiceSettings
    ) async throws -> Data {
        guard settings.isConfigured, !settings.apiKey.isEmpty else {
            throw ImageGenerationError.missingKey
        }
        guard let endpoint = settings.endpoint else {
            throw ImageGenerationError.invalidAddress
        }
        let body: [String: Any]
        switch settings.apiFormat {
        case .novelai:
            body = Self.novelAIRequest(request)
        case .openai:
            body = Self.openAIRequest(request)
        }
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 90
        urlRequest.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

        let response: ImageHTTPResponse
        do {
            response = try await transport.send(urlRequest)
        } catch let error as ImageGenerationError {
            throw error
        } catch let error as URLError where error.code == .timedOut {
            throw ImageGenerationError.timeout
        } catch {
            throw ImageGenerationError.serviceError(error.localizedDescription)
        }
        try Self.checkStatus(response)
        let picture: Data
        switch settings.apiFormat {
        case .novelai:
            picture = try Self.pictureInZip(response.body)
        case .openai:
            picture = try await Self.pictureInOpenAIAnswer(response.body, transport: transport)
        }
        return try ImageTranscoder.jpeg(
            picture,
            width: request.width,
            height: request.height,
            fit: false
        )
    }

    static func novelAIRequest(_ request: ImageRequest) -> [String: Any] {
        let unplaced = [["x": 0, "y": 0]]
        let positives = [[
            "char_caption": request.characterPrompt ?? "",
            "centers": unplaced,
        ]]
        let negatives = [["char_caption": "", "centers": unplaced]]
        return [
            "input": request.prompt,
            "model": request.model,
            "action": "generate",
            "parameters": [
                "params_version": 3,
                "width": request.width,
                "height": request.height,
                "scale": 6,
                "sampler": "k_euler_ancestral",
                "steps": 23,
                "n_samples": 1,
                "ucPreset": 3,
                "qualityToggle": false,
                "seed": Int(request.seed),
                "noise_schedule": "karras",
                "cfg_rescale": 0,
                "negative_prompt": request.negativePrompt,
                "v4_prompt": [
                    "caption": [
                        "base_caption": request.basePrompt ?? request.prompt,
                        "char_captions": positives,
                    ],
                    "use_coords": false,
                    "use_order": true,
                ],
                "v4_negative_prompt": [
                    "caption": [
                        "base_caption": request.negativePrompt,
                        "char_captions": negatives,
                    ],
                    "legacy_uc": false,
                ],
            ],
        ]
    }

    static func openAIRequest(_ request: ImageRequest) -> [String: Any] {
        [
            "model": request.model,
            "prompt": request.prompt,
            "negative_prompt": request.negativePrompt,
            "size": "\(request.width)x\(request.height)",
            "n": 1,
            "response_format": "b64_json",
        ]
    }

    static func checkStatus(_ response: ImageHTTPResponse) throws {
        guard (200..<300).contains(response.statusCode) else {
            let detail = String(decoding: response.body.prefix(300), as: UTF8.self)
            throw ImageGenerationError.serviceError("HTTP \(response.statusCode)：\(detail)")
        }
    }

    static func pictureInZip(_ data: Data) throws -> Data {
        guard let archive = try? Archive(data: data, accessMode: .read) else {
            throw ImageGenerationError.badImage("返回的不是 ZIP")
        }
        var pictures: [Data] = []
        for entry in archive where entry.type == .file {
            var picture = Data()
            do {
                _ = try archive.extract(entry) { picture.append($0) }
            } catch {
                throw ImageGenerationError.badImage("ZIP 里的文件解不开")
            }
            pictures.append(picture)
        }
        guard pictures.count == 1 else {
            throw ImageGenerationError.badImage("ZIP 里有 \(pictures.count) 个文件")
        }
        return pictures[0]
    }

    static func pictureInOpenAIAnswer(
        _ data: Data,
        transport: any ImageHTTPTransport
    ) async throws -> Data {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = object["data"] as? [[String: Any]]
        else {
            throw ImageGenerationError.badImage("不是 OpenAI 图像格式的返回")
        }
        guard items.count == 1 else {
            throw ImageGenerationError.badImage("返回了 \(items.count) 张图")
        }
        let item = items[0]
        if let encoded = item["b64_json"] as? String {
            let payload = encoded.hasPrefix("data:")
                ? String(encoded.drop(while: { $0 != "," }).dropFirst())
                : encoded
            guard let decoded = Data(base64Encoded: payload) else {
                throw ImageGenerationError.badImage("b64_json 不是 base64")
            }
            return decoded
        }
        if let text = item["url"] as? String,
           let url = URL(string: text) {
            var request = URLRequest(url: url)
            request.timeoutInterval = 90
            let response = try await transport.send(request)
            try checkStatus(response)
            return response.body
        }
        throw ImageGenerationError.badImage("返回里没有 b64_json，也没有 url")
    }
}

/// GPT Image's own format: no negative prompt, quality at the top level, and a returned
/// picture that may need centring and scaling.
public struct RemoteGPTImageGenerator: GPTImageGenerating {
    private let transport: any ImageHTTPTransport

    public init(transport: any ImageHTTPTransport = URLSessionImageTransport()) {
        self.transport = transport
    }

    public func generate(
        _ request: ImageRequest,
        settings: GPTImageSettings
    ) async throws -> Data {
        guard settings.isConfigured else { throw ImageGenerationError.missingKey }
        guard let endpoint = settings.endpoint else {
            throw ImageGenerationError.invalidAddress
        }
        let body: [String: Any] = [
            "model": request.model,
            "prompt": request.prompt,
            "size": "\(request.width)x\(request.height)",
            "quality": settings.quality.rawValue,
            "n": 1,
        ]
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 240
        urlRequest.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        let response: ImageHTTPResponse
        do {
            response = try await transport.send(urlRequest)
        } catch let error as ImageGenerationError {
            throw error
        } catch let error as URLError where error.code == .timedOut {
            throw ImageGenerationError.timeout
        } catch {
            throw ImageGenerationError.serviceError(error.localizedDescription)
        }
        try RemoteImageGenerator.checkStatus(response)
        let picture = try await RemoteImageGenerator.pictureInOpenAIAnswer(
            response.body,
            transport: transport
        )
        return try ImageTranscoder.jpeg(
            picture,
            width: request.width,
            height: request.height,
            fit: true
        )
    }
}

/// The one-at-a-time image queue. Photos go before moments; the job already running is
/// never interrupted.
public enum ImageJobPriority: Int, Sendable, Comparable {
    case moment = 0
    case photo = 1

    public static func < (lhs: ImageJobPriority, rhs: ImageJobPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public actor ImageQueue {
    private var running = false
    private struct Waiter {
        let id: UUID
        let priority: ImageJobPriority
        let continuation: CheckedContinuation<Bool, Never>
    }
    private var waiters: [Waiter] = []

    public init() {}

    /// Runs one picture at a time. `timeout` covers the wait in line and the work alike,
    /// and a job that ran out of time gives its place up (spec #98: 90 seconds for a
    /// photo, ten minutes for a moments picture).
    public func run<T: Sendable>(
        priority: ImageJobPriority = .photo,
        timeout: Duration? = nil,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        guard let timeout else {
            guard await acquire(id: UUID(), priority: priority) else {
                throw ImageGenerationError.timeout
            }
            do {
                let value = try await operation()
                release()
                return value
            } catch {
                release()
                throw error
            }
        }
        let id = UUID()
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                guard await self.acquire(id: id, priority: priority) else {
                    throw CancellationError()
                }
                do {
                    let value = try await operation()
                    await self.release()
                    return value
                } catch {
                    await self.release()
                    throw error
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw ImageGenerationError.timeout
            }
            defer { group.cancelAll() }
            guard let value = try await group.next() else {
                throw ImageGenerationError.timeout
            }
            return value
        }
    }

    /// Waits for the one place. A waiter whose task is cancelled leaves the line instead
    /// of taking the place later and drawing a picture nobody asked for any more.
    private func acquire(id: UUID, priority: ImageJobPriority) async -> Bool {
        if !running {
            running = true
            return true
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    waiters.append(Waiter(id: id, priority: priority, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
    }

    private func cancel(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(returning: false)
    }

    private func release() {
        guard !waiters.isEmpty else {
            running = false
            return
        }
        let index = waiters.indices.max { waiters[$0].priority < waiters[$1].priority }!
        let next = waiters.remove(at: index)
        next.continuation.resume(returning: true)
    }
}

enum ImageTranscoder {
    static func jpeg(
        _ data: Data,
        width: Int,
        height: Int,
        fit: Bool
    ) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw ImageGenerationError.badImage("图片解不开")
        }
        let target = CGSize(width: width, height: height)
        let final: CGImage
        if Int(image.width) == width, Int(image.height) == height {
            final = image
        } else if fit {
            final = try fitted(image, to: target)
        } else {
            throw ImageGenerationError.badImage(
                "图片尺寸是 \(image.width)×\(image.height)，不是 \(width)×\(height)"
            )
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw ImageGenerationError.badImage("写不了 JPEG")
        }
        let properties = [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary
        CGImageDestinationAddImage(destination, final, properties)
        guard CGImageDestinationFinalize(destination) else {
            throw ImageGenerationError.badImage("写不了 JPEG")
        }
        return output as Data
    }

    private static func fitted(_ image: CGImage, to size: CGSize) throws -> CGImage {
        let scale = max(size.width / CGFloat(image.width), size.height / CGFloat(image.height))
        let drawn = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        let rect = CGRect(
            x: (size.width - drawn.width) / 2,
            y: (size.height - drawn.height) / 2,
            width: drawn.width,
            height: drawn.height
        )
        guard let context = CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            throw ImageGenerationError.badImage("缩放不了图片")
        }
        context.interpolationQuality = .high
        context.draw(image, in: rect)
        guard let result = context.makeImage() else {
            throw ImageGenerationError.badImage("缩放不了图片")
        }
        return result
    }
}
