import Foundation
import GRDB

extension Eidolon {
    /// Starts the picture her `<photo>` tag describes. The reply is not recorded yet, so
    /// the row waits for `attachPhoto`; the image may arrive before or after it.
    @discardableResult
    func beginPhoto(
        tag: PhotoTag,
        character: CharacterConfig,
        context: PhotoTurnContext,
        adult: Bool,
        now: Date
    ) -> String? {
        guard context.isConfigured, character.canSendPhoto else { return nil }
        guard let table = try? photoTags() else { return nil }
        guard let request = try? PhotoPromptBuilder.request(
                  tag: tag,
                  character: character,
                  style: context.settings.style,
                  adult: adult,
                  table: table,
                  model: adult ? context.settings.adultModel : context.settings.model
              )
        else { return nil }
        let id = UUID().uuidString
        photoDrafts[id] = PhotoDraft(id: id, tag: tag, startedAt: now)
        Task {
            let started = Date()
            do {
                let data = try await imageQueue.run(priority: .photo) {
                    try await context.generator.generate(request, settings: context.settings)
                }
                finishPhoto(id: id, data: data, at: Date())
                recordImageCall(request: request, settings: context.settings, started: started, error: nil)
            } catch let error as ImageGenerationError {
                finishPhoto(id: id, reason: Self.photoReason(error), detail: error.localizedDescription, at: Date())
                recordImageCall(
                    request: request,
                    settings: context.settings,
                    started: started,
                    error: error.localizedDescription
                )
            } catch {
                finishPhoto(id: id, reason: .serviceError, detail: error.localizedDescription, at: Date())
                recordImageCall(
                    request: request,
                    settings: context.settings,
                    started: started,
                    error: error.localizedDescription
                )
            }
        }
        return id
    }

    /// Writes the photo row once the reply has an id. A result that already arrived is
    /// kept; one still being made updates the row when it lands.
    func attachPhoto(
        id: String,
        messageID: String,
        conversationID: String,
        at now: Date
    ) throws {
        guard var draft = photoDrafts[id] else { return }
        draft.messageID = messageID
        draft.conversationID = conversationID
        if let data = draft.data {
            draft.fileName = try writePhotoFile(id: id, data: data)
        }
        photoDrafts[id] = draft
        let status = draft.status
        let reason = draft.reason?.rawValue
        let file = draft.fileName
        let startedAt = Eidolon.timestamp(draft.startedAt)
        let finishedAt = draft.finishedAt.map(Eidolon.timestamp)
        try userQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO photos(
                        id, conversation_id, message_id, tag, status, reason, file,
                        width, height, started_at, finished_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, 832, 1216, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        conversation_id = excluded.conversation_id,
                        message_id = excluded.message_id,
                        status = excluded.status,
                        reason = excluded.reason,
                        file = excluded.file,
                        finished_at = excluded.finished_at
                    """,
                arguments: [
                    id, conversationID, messageID, draft.tag.raw, status.rawValue,
                    reason, file, startedAt, finishedAt,
                ]
            )
        }
    }

    /// Drops a draft whose reply was never written. The generation, if still running,
    /// finds nothing to store when it lands.
    func discardPhoto(id: String) {
        photoDrafts.removeValue(forKey: id)
    }

    /// The status of one photo, for the app's polling after the turn has finished.
    public func photo(id: String) throws -> PhotoReference? {
        try userQueue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT id, status, reason FROM photos WHERE id = ?",
                arguments: [id]
            ) else { return nil }
            return Self.photoStatus(row)
        }
    }

    /// The image bytes, or nil when it is still being made, failed, or has no file.
    public func photoImage(id: String) throws -> Data? {
        let file: String? = try userQueue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT file FROM photos WHERE id = ? AND status = 'ready'",
                arguments: [id]
            )
        }
        guard let file else { return nil }
        return try? Data(contentsOf: photoFileURL(file))
    }

    /// How many photos were started in the given window; used by the hourly allowance.
    func photoCount(since start: Date) throws -> Int {
        try userQueue.read { db in
            try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM photos
                    WHERE started_at >= ? AND status != 'failed'
                    """,
                arguments: [Eidolon.timestamp(start)]
            ) ?? 0
        }
    }

    /// Marks photos left pending by a previous process as timed out.
    static func failPendingPhotos(_ queue: DatabaseQueue) throws {
        try queue.write { db in
            try db.execute(
                sql: """
                    UPDATE photos
                    SET status = 'failed', reason = 'timeout', finished_at = ?
                    WHERE status = 'pending'
                    """,
                arguments: [Eidolon.timestamp(Date())]
            )
        }
    }

    private func finishPhoto(id: String, data: Data, at now: Date) {
        guard var draft = photoDrafts[id] else { return }
        draft.status = .ready
        draft.data = data
        draft.finishedAt = now
        if let messageID = draft.messageID, let conversationID = draft.conversationID {
            let file = try? writePhotoFile(id: id, data: data)
            draft.fileName = file
            try? userQueue.write { db in
                try db.execute(
                    sql: """
                        UPDATE photos SET status = 'ready', reason = NULL, file = ?,
                            finished_at = ? WHERE id = ?
                        """,
                    arguments: [file, Eidolon.timestamp(now), id]
                )
            }
            _ = messageID
            _ = conversationID
        }
        photoDrafts[id] = draft
    }

    private func finishPhoto(
        id: String,
        reason: PhotoFailureReason,
        detail: String,
        at now: Date
    ) {
        guard var draft = photoDrafts[id] else { return }
        draft.status = .failed
        draft.reason = reason
        draft.finishedAt = now
        if draft.messageID != nil, draft.conversationID != nil {
            try? userQueue.write { db in
                try db.execute(
                    sql: """
                        UPDATE photos SET status = 'failed', reason = ?, finished_at = ?
                        WHERE id = ?
                        """,
                    arguments: [reason.rawValue, Eidolon.timestamp(now), id]
                )
            }
        }
        _ = detail
        photoDrafts[id] = draft
    }

    /// One real generation, for the usage page (spec #96, ticket #101): what model, how
    /// many pictures, how long and what went wrong — never the tag she wrote.
    private func recordImageCall(
        request: ImageRequest,
        settings: ImageServiceSettings,
        started: Date,
        error: String?
    ) {
        let call = ServiceCall(
            at: Date(),
            service: .image,
            provider: URL(string: settings.baseURL)?.host ?? "",
            model: request.model,
            operation: .image,
            unit: .images,
            input: 1,
            latency: Date().timeIntervalSince(started),
            error: error
        )
        try? recordServiceCall(call)
    }

    private static func photoReason(_ error: ImageGenerationError) -> PhotoFailureReason {
        switch error {
        case .timeout: .timeout
        case .badImage: .badImage
        case .missingKey, .invalidAddress, .serviceError: .serviceError
        }
    }

    /// A photo's own row, which carries no tag or message: `Conversation`'s
    /// `photoReference` reads the joined message row and answers nil when there is none.
    private static func photoStatus(_ row: Row) -> PhotoReference {
        let status = PhotoStatus(rawValue: row["status"]) ?? .failed
        let reason = (row["reason"] as String?).flatMap(PhotoFailureReason.init(rawValue:))
        return PhotoReference(id: row["id"], status: status, reason: reason)
    }

    private func photoFileURL(_ relative: String) -> URL {
        location.userDirectory.appendingPathComponent(relative)
    }

    private func writePhotoFile(id: String, data: Data) throws -> String {
        let relative = "images/photos/\(id).jpg"
        let url = photoFileURL(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
        return relative
    }
}
