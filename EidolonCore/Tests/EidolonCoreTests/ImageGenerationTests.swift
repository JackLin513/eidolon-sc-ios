import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
import ZIPFoundation
@testable import EidolonCore

final class ImageGenerationTests: XCTestCase {
    private final class FakeTransport: ImageHTTPTransport, @unchecked Sendable {
        var requests: [URLRequest] = []
        var responses: [Result<ImageHTTPResponse, Error>] = []

        func send(_ request: URLRequest) async throws -> ImageHTTPResponse {
            requests.append(request)
            guard !responses.isEmpty else {
                throw ImageGenerationError.serviceError("no fake response")
            }
            switch responses.removeFirst() {
            case let .success(response): return response
            case let .failure(error): throw error
            }
        }
    }

    private func settings(format: ImageAPIFormat = .novelai) -> ImageServiceSettings {
        ImageServiceSettings(
            apiFormat: format,
            baseURL: format == .novelai
                ? "https://image.novelai.net"
                : "https://relay.example/v1",
            apiKey: "test-key"
        )
    }

    private func request(model: String = "test-model") -> ImageRequest {
        ImageRequest(
            prompt: "1girl, solo, smile",
            negativePrompt: "nsfw",
            width: 832,
            height: 1216,
            model: model,
            seed: 42
        )
    }

    func testNovelAiSendsTheSceneAndTheCharacterCaptionsApart() throws {
        let split = ImageRequest(
            prompt: "1girl, solo, mano, smile",
            basePrompt: "1girl, solo, smile",
            characterPrompt: "girl, mano",
            negativePrompt: "nsfw",
            width: 832,
            height: 1216,
            model: "test-model",
            seed: 42
        )
        let body = RemoteImageGenerator.novelAIRequest(split)
        let parameters = try XCTUnwrap(body["parameters"] as? [String: Any])
        let v4 = try XCTUnwrap(parameters["v4_prompt"] as? [String: Any])
        let caption = try XCTUnwrap(v4["caption"] as? [String: Any])
        XCTAssertEqual(caption["base_caption"] as? String, "1girl, solo, smile")
        let characters = try XCTUnwrap(caption["char_captions"] as? [[String: Any]])
        XCTAssertEqual(characters.first?["char_caption"] as? String, "girl, mano")
        XCTAssertEqual(parameters["scale"] as? Int, 6)
    }

    private func jpeg(width: Int, height: Int, red: CGFloat = 0.5) throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ), let image = {
            context.setFillColor(CGColor(red: red, green: 0.4, blue: 0.6, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            return context.makeImage()
        }() else {
            throw ImageGenerationError.badImage("test image")
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil
        ) else { throw ImageGenerationError.badImage("test image") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ImageGenerationError.badImage("test image")
        }
        return data as Data
    }

    private func zip(_ image: Data) throws -> Data {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("image-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: url) }
        let archive = try Archive(url: url, accessMode: .create)
        try archive.addEntry(
            with: "image.png",
            type: .file,
            uncompressedSize: UInt32(image.count),
            compressionMethod: .deflate,
            provider: { position, size in
                image.subdata(in: Int(position)..<(Int(position) + size))
            }
        )
        return try Data(contentsOf: url)
    }

    private func openAI(_ image: Data) throws -> Data {
        let encoded = image.base64EncodedString()
        return try JSONSerialization.data(withJSONObject: ["data": [["b64_json": encoded]]])
    }

    private func dimensions(_ data: Data) throws -> (Int, Int) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw ImageGenerationError.badImage("test image") }
        return (image.width, image.height)
    }

    func testNovelAIFormatSendsTheRequestAndReadsTheZip() async throws {
        let transport = FakeTransport()
        transport.responses = [.success(ImageHTTPResponse(
            statusCode: 200,
            body: try zip(jpeg(width: 832, height: 1216))
        ))]
        let generator = RemoteImageGenerator(transport: transport)

        let output = try await generator.generate(request(), settings: settings())

        let size = try dimensions(output)
        XCTAssertEqual(size.0, 832)
        XCTAssertEqual(size.1, 1216)
        let url = try XCTUnwrap(transport.requests.first?.url)
        XCTAssertEqual(url.path, "/ai/generate-image")
        let body = try JSONSerialization.jsonObject(
            with: try XCTUnwrap(transport.requests.first?.httpBody)
        ) as? [String: Any]
        XCTAssertEqual(body?["model"] as? String, "test-model")
        let parameters = body?["parameters"] as? [String: Any]
        XCTAssertEqual(parameters?["width"] as? Int, 832)
        XCTAssertEqual(parameters?["height"] as? Int, 1216)
        XCTAssertEqual(parameters?["steps"] as? Int, 23)
        XCTAssertEqual(parameters?["scale"] as? Int, 6)
        XCTAssertEqual(parameters?["negative_prompt"] as? String, "nsfw")
        XCTAssertEqual(parameters?["seed"] as? Int, 42)
    }

    func testOpenAIImageFormatReadsBase64() async throws {
        let transport = FakeTransport()
        transport.responses = [.success(ImageHTTPResponse(
            statusCode: 200,
            body: try openAI(jpeg(width: 832, height: 1216))
        ))]
        let generator = RemoteImageGenerator(transport: transport)

        let output = try await generator.generate(
            request(), settings: settings(format: .openai)
        )

        let size = try dimensions(output)
        XCTAssertEqual(size.0, 832)
        XCTAssertEqual(size.1, 1216)
        let url = try XCTUnwrap(transport.requests.first?.url)
        XCTAssertEqual(url.path, "/v1/images/generations")
        let body = try JSONSerialization.jsonObject(
            with: try XCTUnwrap(transport.requests.first?.httpBody)
        ) as? [String: Any]
        XCTAssertEqual(body?["size"] as? String, "832x1216")
        XCTAssertEqual(body?["negative_prompt"] as? String, "nsfw")
    }

    func testOpenAIURLIsDownloadedOnTheSameTransport() async throws {
        let image = try jpeg(width: 832, height: 1216)
        let answer = try JSONSerialization.data(
            withJSONObject: ["data": [["url": "https://cdn.example/image.png"]]]
        )
        let transport = FakeTransport()
        transport.responses = [
            .success(ImageHTTPResponse(statusCode: 200, body: answer)),
            .success(ImageHTTPResponse(statusCode: 200, body: image)),
        ]
        let generator = RemoteImageGenerator(transport: transport)

        let output = try await generator.generate(
            request(), settings: settings(format: .openai)
        )

        let size = try dimensions(output)
        XCTAssertEqual(size.0, 832)
        XCTAssertEqual(size.1, 1216)
        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertEqual(transport.requests.last?.url?.host, "cdn.example")
    }

    func testWrongSizeIsABadImage() async throws {
        let transport = FakeTransport()
        transport.responses = [.success(ImageHTTPResponse(
            statusCode: 200,
            body: try zip(jpeg(width: 512, height: 512))
        ))]
        let generator = RemoteImageGenerator(transport: transport)

        do {
            _ = try await generator.generate(request(), settings: settings())
            XCTFail("expected badImage")
        } catch let error as ImageGenerationError {
            guard case .badImage = error else { return XCTFail("expected badImage, got \(error)") }
        }
    }

    func testTimeoutIsItsOwnError() async throws {
        let transport = FakeTransport()
        transport.responses = [.failure(URLError(.timedOut))]
        let generator = RemoteImageGenerator(transport: transport)

        do {
            _ = try await generator.generate(request(), settings: settings())
            XCTFail("expected timeout")
        } catch let error as ImageGenerationError {
            XCTAssertEqual(error, .timeout)
        }
    }

    func testGPTImageFitsAnUnexpectedSizeToTheAskedShape() async throws {
        let transport = FakeTransport()
        transport.responses = [.success(ImageHTTPResponse(
            statusCode: 200,
            body: try openAI(jpeg(width: 1024, height: 1024))
        ))]
        let gpt = GPTImageSettings(enabled: true, apiKey: "gpt-key")
        let generator = RemoteGPTImageGenerator(transport: transport)

        let output = try await generator.generate(request(), settings: gpt)

        let size = try dimensions(output)
        XCTAssertEqual(size.0, 832)
        XCTAssertEqual(size.1, 1216)
        let body = try JSONSerialization.jsonObject(
            with: try XCTUnwrap(transport.requests.first?.httpBody)
        ) as? [String: Any]
        XCTAssertEqual(body?["model"] as? String, "test-model")
        XCTAssertEqual(body?["quality"] as? String, "medium")
        XCTAssertNil(body?["negative_prompt"])
    }

    func testEndpointsFollowTheChosenFormat() {
        XCTAssertEqual(
            settings().endpoint?.absoluteString,
            "https://image.novelai.net/ai/generate-image"
        )
        XCTAssertEqual(
            settings(format: .openai).endpoint?.absoluteString,
            "https://relay.example/v1/images/generations"
        )
    }

    func testAJobThatRunsOutOfTimeFreesItsPlace() async throws {
        let queue = ImageQueue()
        let started = ContinuousClock.now
        do {
            _ = try await queue.run(timeout: .milliseconds(100)) {
                try await Task.sleep(for: .seconds(5))
                return 1
            }
            XCTFail("expected the job to time out")
        } catch let error as ImageGenerationError {
            XCTAssertEqual(error, .timeout)
        }
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(2))
        let next = try await queue.run(timeout: .seconds(1)) { 2 }
        XCTAssertEqual(next, 2)
    }

    func testAJobThatTimesOutInLineNeverRuns() async throws {
        let queue = ImageQueue()
        actor Ran {
            var values: [Int] = []
            func record(_ value: Int) { values.append(value) }
        }
        let ran = Ran()
        async let first: Int = queue.run { 
            try await Task.sleep(for: .milliseconds(300))
            return 1
        }
        try await Task.sleep(for: .milliseconds(20))
        do {
            _ = try await queue.run(timeout: .milliseconds(50)) {
                await ran.record(2)
                return 2
            }
            XCTFail("expected the queued job to time out")
        } catch let error as ImageGenerationError {
            XCTAssertEqual(error, .timeout)
        }
        let firstValue = try await first
        XCTAssertEqual(firstValue, 1)
        // Give a late start every chance to happen before checking it did not.
        try await Task.sleep(for: .milliseconds(400))
        let values = await ran.values
        XCTAssertTrue(values.isEmpty)
    }


    func testTheTryOutUsesTheCheaperModelOnNovelAIOnly() {
        var settings = self.settings()
        settings.model = "nai-diffusion-5-curated"
        XCTAssertEqual(settings.testSettings.model, "nai-diffusion-4-5-curated")
        XCTAssertEqual(settings.testSettings.apiKey, settings.apiKey)
        XCTAssertEqual(settings.testSettings.baseURL, settings.baseURL)

        var relay = self.settings(format: .openai)
        relay.model = "relay-image-1"
        XCTAssertEqual(relay.testSettings.model, "relay-image-1")
    }

}
