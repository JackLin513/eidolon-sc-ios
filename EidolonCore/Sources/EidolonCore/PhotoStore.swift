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
                  model: adult ? context.settings.adultModel : context.settings.model,
                  producerTags: context.settings.producerTags
              )
        else { return nil }
        let id = UUID().uuidString
        photoDrafts[id] = PhotoDraft(id: id, tag: tag, startedAt: now)
        Task {
            let started = Date()
            do {
                let data = try await imageQueue.run(
                    priority: .photo,
                    timeout: .seconds(90)
                ) {
                    try await context.generator.generate(request, settings: context.settings)
                }
                finishPhoto(id: id, data: data, at: Date())
                recordImageCall(
                    conversationID: photoDrafts[id]?.conversationID,
                    request: request,
                    settings: context.settings,
                    started: started,
                    error: nil
                )
            } catch let error as ImageGenerationError {
                finishPhoto(id: id, reason: Self.photoReason(error), detail: error.localizedDescription, at: Date())
                recordImageCall(
                    conversationID: photoDrafts[id]?.conversationID,
                    request: request,
                    settings: context.settings,
                    started: started,
                    error: error.localizedDescription
                )
            } catch {
                finishPhoto(id: id, reason: .serviceError, detail: error.localizedDescription, at: Date())
                recordImageCall(
                    conversationID: photoDrafts[id]?.conversationID,
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
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
                    reason, file, PhotoGeometry.width, PhotoGeometry.height,
                    startedAt, finishedAt,
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

    /// When the longest-waiting picture in the window gives its slot back: the oldest
    /// one's start plus the hour (spec #98's HH:MM).
    func photoSlotsFreeAt(since start: Date) throws -> Date? {
        try userQueue.read { db in
            let oldest: String? = try String.fetchOne(
                db,
                sql: """
                    SELECT MIN(started_at) FROM photos
                    WHERE started_at >= ? AND status != 'failed'
                    """,
                arguments: [Eidolon.timestamp(start)]
            )
            return oldest.flatMap(Eidolon.parseTimestamp)
        }
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

    /// Removes picture files no photo row points at: a write that failed after the file
    /// landed, or a row that went with its conversation (ticket #102).
    static func removeOrphanPhotoFiles(_ queue: DatabaseQueue, in directory: URL) throws {
        let photosDirectory = directory.appendingPathComponent("images/photos")
        guard let names = try? FileManager.default.contentsOfDirectory(
            at: photosDirectory,
            includingPropertiesForKeys: nil
        ) else { return }
        let known = try queue.read { db in
            try Set(String.fetchAll(db, sql: "SELECT file FROM photos WHERE file IS NOT NULL"))
        }
        for url in names {
            let relative = "images/photos/\(url.lastPathComponent)"
            if !known.contains(relative) {
                try? FileManager.default.removeItem(at: url)
            }
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
        conversationID: String?,
        request: ImageRequest,
        settings: ImageServiceSettings,
        started: Date,
        error: String?
    ) {
        // A picture only costs one when the service returned it (spec #98).
        let call = ServiceCall(
            at: Date(),
            service: .image,
            provider: URL(string: settings.baseURL)?.host ?? "",
            model: request.model,
            operation: .image,
            unit: .images,
            input: error == nil ? 1 : 0,
            latency: Date().timeIntervalSince(started),
            error: error,
            conversationID: conversationID
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

    /// Development aid for this phone: make a picture for a reply that did not get one,
    /// from a tag the producer writes by hand. It writes the same row, file and usage
    /// record as a turn does; the tag is cleaned by the same table.
    @discardableResult
    public func makePhotoForTesting(
        messageID: String,
        conversationID: String,
        characterID: String,
        tag: PhotoTag,
        context: PhotoTurnContext,
        adult: Bool,
        now: Date = Date()
    ) async throws -> PhotoReference {
        guard context.isConfigured else { throw ImageGenerationError.missingKey }
        guard let character = try characters().first(where: { $0.id == characterID }),
              character.canSendPhoto
        else { throw PhotoTagError.malformed("这位角色不能发自拍") }
        guard let table = try photoTags() else {
            throw PhotoTagError.malformed("这份内容包没有照片 tag 表")
        }
        let belongs: String? = try await userQueue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT conversation_id FROM messages WHERE id = ?",
                arguments: [messageID]
            )
        }
        guard belongs == conversationID else {
            throw EidolonError.invalidContent("这条回复不在这个对话里")
        }
        // A reply has at most one picture; a second press keeps the first — unless the
        // first failed, in which case this press is the retry and replaces it.
        let existing: PhotoReference? = try await userQueue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT id, status, reason FROM photos WHERE message_id = ?",
                arguments: [messageID]
            ) else { return nil }
            return Self.photoStatus(row)
        }
        if let existing, existing.status != .failed { return existing }
        if existing != nil {
            try await userQueue.write { db in
                try db.execute(
                    sql: "DELETE FROM photos WHERE message_id = ?",
                    arguments: [messageID]
                )
            }
        }
        let request = try PhotoPromptBuilder.request(
            tag: tag,
            character: character,
            style: context.settings.style,
            adult: adult,
            table: table,
            model: adult ? context.settings.adultModel : context.settings.model,
            producerTags: context.settings.producerTags
        )
        let id = UUID().uuidString
        let started = Date()
        var data: Data?
        var reason: PhotoFailureReason?
        var detail: String?
        do {
            data = try await imageQueue.run(priority: .photo, timeout: .seconds(90)) {
                try await context.generator.generate(request, settings: context.settings)
            }
        } catch let error as ImageGenerationError {
            reason = Self.photoReason(error)
            detail = error.localizedDescription
        } catch {
            reason = .serviceError
            detail = error.localizedDescription
        }
        recordImageCall(
            conversationID: conversationID,
            request: request,
            settings: context.settings,
            started: started,
            error: detail
        )
        let file: String?
        if let data {
            file = try? writePhotoFile(id: id, data: data)
        } else {
            file = nil
        }
        let status: PhotoStatus = data == nil ? .failed : .ready
        let reasonValue = reason?.rawValue
        let statusValue = status.rawValue
        try await userQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO photos(
                        id, conversation_id, message_id, tag, status, reason, file,
                        width, height, started_at, finished_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    id, conversationID, messageID, tag.raw, statusValue,
                    reasonValue, file, PhotoGeometry.width, PhotoGeometry.height,
                    Eidolon.timestamp(started), Eidolon.timestamp(now),
                ]
            )
        }
        return PhotoReference(id: id, status: status, reason: reason)
    }

    func photoFileURL(_ relative: String) -> URL {
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
