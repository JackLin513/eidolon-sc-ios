#if DEBUG
import Foundation

extension Eidolon {
    /// Development aid for the settings pages' UI tests: a few calls in today's ledger, so
    /// the usage page has something to show without spending a real key (spec #96).
    public func debugSeedUsage(now: Date = Date()) throws {
        let existing = try userQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM service_calls") ?? 0
        }
        guard existing == 0 else { return }
        let calls = [
            ServiceCall(
                at: now, service: .chat, provider: "api.deepseek.com",
                model: "deepseek-v4-pro", operation: .chatText, unit: .tokens,
                input: 1_200, output: 400, estimated: false
            ),
            ServiceCall(
                at: now, service: .speech, provider: "api.fish.audio",
                model: "s2-pro", operation: .speech, unit: .bytes,
                input: 300, estimated: false
            ),
            ServiceCall(
                at: now, service: .recognition, provider: "stt-rt.soniox.com",
                model: "stt-rt-v5", operation: .recognition, unit: .seconds,
                input: 600, estimated: false
            ),
        ]
        for call in calls { try recordServiceCall(call) }
    }
}

extension Eidolon {
    /// Development aid for the stats page's UI test: a few kept contacts and a connected
    /// call, so the page has a portrait, a heatmap and a range (spec #96).
    public func debugSeedStats(now: Date = Date()) async throws {
        let characters = try characters()
        guard let character = characters.first else { return }
        let existing = try await userQueue.read { db in
            try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM messages m
                    JOIN conversations c ON c.id = m.conversation_id
                    WHERE m.role = 'user'
                    """
            ) ?? 0
        }
        guard existing == 0 else { return }
        let conversation = "debug-stats"
        let yesterday = now.addingTimeInterval(-86_400)
        let twoDays = now.addingTimeInterval(-172_800)
        try await userQueue.write { db in
            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO conversations(id, character_id, created_at, title)
                    VALUES (?, ?, ?, '统计测试')
                    """,
                arguments: [conversation, character.id, Self.timestamp(twoDays)]
            )
            for (index, at) in [twoDays, yesterday, now].enumerated() {
                try db.execute(
                    sql: """
                        INSERT INTO messages(id, conversation_id, role, text, created_at)
                        VALUES (?, ?, 'user', '统计测试', ?)
                        """,
                    arguments: ["debug-stats-\(index)", conversation, Self.timestamp(at)]
                )
            }
            try db.execute(
                sql: """
                    INSERT INTO conversation_events(
                        conversation_id, kind, created_at, gift_id, liked
                    ) VALUES (?, 'gift', ?, 'cake', 1)
                    """,
                arguments: [conversation, Self.timestamp(yesterday)]
            )
            try db.execute(
                sql: """
                    INSERT INTO call_ends(
                        conversation_id, character_id, ended_at, connected_at, duration_s
                    ) VALUES (?, ?, ?, ?, 120)
                    """,
                arguments: [
                    conversation, character.id, Self.timestamp(yesterday),
                    Self.timestamp(yesterday),
                ]
            )
        }
    }
}
#endif
