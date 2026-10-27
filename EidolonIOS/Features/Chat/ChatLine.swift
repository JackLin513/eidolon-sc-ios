import EidolonCore

/// One row of a conversation as shown: a turn, her reach-out, or something that happened
/// instead of one. The core keeps the database's order; the chat never reorders it.
typealias ChatLine = ConversationLine
