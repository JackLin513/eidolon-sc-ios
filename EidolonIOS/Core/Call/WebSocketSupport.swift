import Foundation

/// Sends over one websocket one message at a time: an audio pump and a keepalive would
/// otherwise interleave sends on the same connection.
actor WebSocketWriter {
    private let socket: URLSessionWebSocketTask

    init(_ socket: URLSessionWebSocketTask) {
        self.socket = socket
    }

    func sendData(_ data: Data) async throws {
        try await socket.send(.data(data))
    }

    func sendText(_ text: String) async throws {
        try await socket.send(.string(text))
    }
}

/// Makes a connection, failing if it cannot be made in `timeout`: a socket that never
/// opens must not sit in `send` forever. Once made, nothing here times the socket out; an
/// idle connection stays up.
func withWebSocketConnectTimeout(
    _ timeout: Duration,
    _ connect: @escaping @Sendable () async throws -> Void
) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { try await connect() }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw URLError(.timedOut)
        }
        defer { group.cancelAll() }
        try await group.next()
    }
}
