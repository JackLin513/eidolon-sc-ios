import Foundation

public enum EidolonError: LocalizedError, Equatable {
    /// The archive is missing, unreadable, or not a zip.
    case unreadableBundle(String)
    /// The bundle's manifest or contents do not meet the format contract.
    case invalidBundle(String)
    /// The bundle's content database is fine as a file but not usable.
    case invalidContent(String)
    /// The installed bundle does not match what the app expects.
    case unsupportedVersion(String)
    /// No content bundle has been installed yet.
    case contentNotInstalled
    /// She does not want to talk until `Date` (GLOSSARY.md「冷却」).
    case coolingDown(Date)
    /// The current conversation is hers to end (GLOSSARY.md「已结束的对话」).
    case conversationEnded
    /// The current conversation cannot be deleted; only past ones can.
    case conversationIsCurrent
    /// The producer sent nothing to answer (upstream `BLANK`).
    case blankInput
    /// The producer's line is longer than `TurnInput.maxLength` (upstream `TOO_LONG`).
    case inputTooLong(Int)
    /// The turn could not be answered: the model failed or said nothing she could say.
    /// What the producer reads is all of it, as upstream's `FAILED` (the details stay in
    /// the trace).
    case turnFailed

    /// Whether the turn refused the producer's line itself, rather than failing to
    /// answer it: what it says is already the message to show.
    public var isInputRejection: Bool {
        switch self {
        case .blankInput, .inputTooLong: true
        default: false
        }
    }

    public var errorDescription: String? {
        switch self {
        case .unreadableBundle(let reason):
            return "无法读取内容包：\(reason)"
        case .invalidBundle(let reason):
            return "内容包不符合约定：\(reason)"
        case .invalidContent(let reason):
            return "内容库不可用：\(reason)"
        case .unsupportedVersion(let reason):
            return "内容包版本不受支持：\(reason)"
        case .contentNotInstalled:
            return "还没有导入内容包"
        case .conversationEnded:
            return "这段对话已经结束了，只能翻看；想接着聊就开一段新对话"
        case .conversationIsCurrent:
            return "当前对话不能删除，先开一段新对话"
        case .blankInput:
            return "没有收到要说的话。"
        case .inputTooLong(let limit):
            return "这句话太长了，最多 \(limit) 字。"
        case .turnFailed:
            // Upstream `engine.FAILED`, word for word.
            return "角色暂时无法回复，请稍后再试。"
        case .coolingDown(let until):
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.dateFormat = "M月d日 HH:mm"
            return "她现在不想说话，晚些时候再来吧（大约到 \(formatter.string(from: until))）"
        }
    }
}
