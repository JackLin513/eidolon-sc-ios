import EidolonCore
import Foundation

/// Real-time recognition on Alibaba Cloud Model Studio (阿里云百炼), over DashScope's
/// duplex WebSocket protocol. A task is opened with `run-task`, sent 16 kHz PCM in 100 ms
/// packets, and answers each sentence as far as it has heard it. A key works only in its
/// region, so Beijing is tried first and Singapore if Beijing refuses the key.
final class BailianRecognition: SpeechRecognition, @unchecked Sendable {
    private let apiKey: String
    private let model: String
    /// The names said in a call that the recognizer should write as the story does.
    private let terms: [String]
    /// How long a task may take to start; DashScope starts one in about 0.3 s.
    private static let connectTimeout: Duration = .seconds(10)
    /// A connection may carry nothing down while her voice keeps the microphone closed;
    /// URLSession's default request timeout would take that for a dead connection.
    private static let idleTimeout: TimeInterval = 60 * 60 * 24 * 365

    /// The region the key was found to work in, remembered for reconnects.
    private let regionLock = NSLock()
    private var knownRegion: BailianRegion?

    init(apiKey: String, model: String, terms: [String] = []) {
        self.apiKey = apiKey
        self.model = model
        self.terms = terms
    }

    func listen(_ audio: AsyncThrowingStream<Data, Error>) -> AsyncThrowingStream<SpeechEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { await self.run(audio: audio, emit: continuation) }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    /// A task DashScope refuses — a missing or refused key, a model not enabled for it —
    /// is the service failing, and ends the call; a dropped connection is reconnected.
    func failure(_ error: any Error) -> VoiceServiceFailure? {
        guard case let BailianError.service(code, message) = error else { return nil }
        let detail = [code, message].filter { !$0.isEmpty }.joined(separator: "：")
        return VoiceServiceFailure(service: "百炼", detail: detail)
    }

    private func region() -> BailianRegion? {
        regionLock.lock()
        defer { regionLock.unlock() }
        return knownRegion
    }

    private func remember(_ region: BailianRegion) {
        regionLock.lock()
        knownRegion = region
        regionLock.unlock()
    }

    private func run(
        audio: AsyncThrowingStream<Data, Error>,
        emit: AsyncThrowingStream<SpeechEvent, Error>.Continuation
    ) async {
        guard !apiKey.isEmpty else {
            emit.finish(throwing: BailianError.service("", "还没有填阿里云百炼的密钥"))
            return
        }
        let connection: Connection
        do {
            connection = try await connect()
        } catch {
            emit.finish(throwing: error)
            return
        }
        defer {
            connection.socket.cancel(with: .normalClosure, reason: nil)
            connection.session.invalidateAndCancel()
        }
        // The task started: DashScope can hear from here on, and the call is connected.
        emit.yield(.connected)

        let writer = PacketWriter(socket: connection.writer)
        let pump = Task {
            do {
                for try await chunk in audio {
                    if Task.isCancelled { break }
                    try await writer.send(chunk)
                }
            } catch {
                // The microphone ended or failed; finish what was heard.
            }
            guard !Task.isCancelled else { return }
            // Tell the task to finish so the sentence still open is transcribed; wait a
            // little for it, then close (upstream `_finish_task`, 3 s).
            do {
                try await writer.finish(taskID: connection.taskID)
            } catch {
                connection.socket.cancel(with: .normalClosure, reason: nil)
                return
            }
            try? await Task.sleep(for: .seconds(3))
            connection.socket.cancel(with: .normalClosure, reason: nil)
        }
        // DashScope ends a task sent nothing for 23 seconds; while her voice keeps the
        // microphone closed, the service sends silence itself (upstream `bailian.py`).
        let keepalive = Task {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: BailianKeepalive.interval)
                } catch {
                    break
                }
                do {
                    try await writer.keepaliveIfDue()
                } catch {
                    break
                }
            }
        }
        defer {
            pump.cancel()
            keepalive.cancel()
        }

        var transcript = BailianTranscript()
        do {
            while !Task.isCancelled {
                let message = try await connection.socket.receive()
                let data: Data?
                switch message {
                case let .data(bytes): data = bytes
                case let .string(text): data = Data(text.utf8)
                @unknown default: data = nil
                }
                guard let data else { continue }
                for update in try transcript.feed(data) {
                    switch update {
                    case let .partial(text):
                        emit.yield(.partial(text))
                    case let .final(text):
                        emit.yield(.final(text))
                    case .ended:
                        emit.finish()
                        return
                    }
                }
            }
            emit.finish()
        } catch is CancellationError {
            emit.finish()
        } catch {
            emit.finish(throwing: error)
        }
    }

    // MARK: - Connecting

    private struct Connection {
        let socket: URLSessionWebSocketTask
        let session: URLSession
        let taskID: String
        let writer: WebSocketWriter
    }

    /// The region's handshake refusing the key (401/403), which the other region may take.
    private struct RegionRefused: Error {}

    /// Opens a task in the remembered region, or in Beijing and then Singapore. A task
    /// that fails to start is refused outright; a handshake that refuses the key moves on
    /// to the other region.
    private func connect() async throws -> Connection {
        var regions = BailianRegion.allCases
        if let known = region(), let index = regions.firstIndex(of: known) {
            regions.remove(at: index)
            regions.insert(known, at: 0)
        }
        let configuration = BailianSTTConfiguration(model: model, hotWords: terms)
        let taskID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let runTask = try configuration.runTaskMessage(taskID: taskID)

        var refused = false
        var lastError: (any Error)?
        for region in regions {
            do {
                let connection = try await open(region: region, taskID: taskID, runTask: runTask)
                remember(region)
                return connection
            } catch is RegionRefused {
                refused = true
            } catch let error as BailianError {
                // `task-failed` is the task itself: the other region would say the same.
                throw error
            } catch {
                // A handshake failure without a refusal status is a connection to retry.
                lastError = error
            }
        }
        if refused {
            throw BailianError.service("", "key 在北京和新加坡都不被接受")
        }
        throw lastError ?? BailianError.service("", "连不上阿里云百炼")
    }

    private func open(
        region: BailianRegion,
        taskID: String,
        runTask: String
    ) async throws -> Connection {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = Self.idleTimeout
        let session = URLSession(configuration: configuration)
        var request = URLRequest(url: BailianSTTEndpoint.url(for: region))
        request.setValue("bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let socket = session.webSocketTask(with: request)
        socket.resume()
        let writer = WebSocketWriter(socket)
        do {
            try await withWebSocketConnectTimeout(Self.connectTimeout) {
                try await writer.sendText(runTask)
                while true {
                    let message = try await socket.receive()
                    let data: Data?
                    switch message {
                    case let .data(bytes): data = bytes
                    case let .string(text): data = Data(text.utf8)
                    @unknown default: data = nil
                    }
                    guard let data,
                          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let header = object["header"] as? [String: Any],
                          let event = header["event"] as? String
                    else { continue }
                    if event == "task-started" { return }
                    if event == "task-failed" {
                        throw BailianError.service(
                            header["error_code"] as? String ?? "",
                            header["error_message"] as? String ?? ""
                        )
                    }
                }
            }
        } catch {
            let status = (socket.response as? HTTPURLResponse)?.statusCode
            socket.cancel(with: .normalClosure, reason: nil)
            session.invalidateAndCancel()
            if status == 401 || status == 403 { throw RegionRefused() }
            throw error
        }
        return Connection(socket: socket, session: session, taskID: taskID, writer: writer)
    }

}

/// Sends over one websocket one message at a time, and owns the audio packetizer so the
/// pump and the keepalive do not interleave a partial packet.
private actor PacketWriter {
    private let socket: WebSocketWriter
    private var packets = BailianAudioPackets()
    private var lastAudio = Date()

    init(socket: WebSocketWriter) {
        self.socket = socket
    }

    func send(_ data: Data) async throws {
        for packet in packets.append(data) {
            try await socket.sendData(packet)
        }
        lastAudio = Date()
    }

    func keepaliveIfDue() async throws {
        guard BailianKeepalive.isDue(now: Date(), lastAudio: lastAudio) else { return }
        let packet = packets.drainPadded() ?? BailianKeepalive.silence()
        try await socket.sendData(packet)
        lastAudio = Date()
    }

    func finish(taskID: String) async throws {
        if let packet = packets.drainPadded() {
            try await socket.sendData(packet)
        }
        try await socket.sendText(BailianSTTConfiguration.finishTaskMessage(taskID: taskID))
        lastAudio = Date()
    }
}
