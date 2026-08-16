import Foundation

enum SidebarOrganization: String, Equatable {
    case byProject
    case singleList
}

enum SidebarSort: String, Equatable {
    case priority
    case recent
}

struct HostConfiguration: Codable, Equatable {
    var name = "Windows PC"
    var endpoint = "ws://127.0.0.1:8765"
    var workingDirectory = ""
}

struct CodexProfile: Identifiable, Equatable {
    let id: String
    let name: String
    let codexHome: String
    let source: String
    let isActive: Bool
    let isRunning: Bool

    init?(json: JSONValue) {
        guard let id = json["id"]?.stringValue,
              let name = json["name"]?.stringValue else { return nil }
        self.id = id
        self.name = name
        codexHome = json["codexHome"]?.stringValue ?? ""
        source = json["source"]?.stringValue ?? "custom"
        isActive = json["active"]?.boolValue ?? false
        isRunning = json["running"]?.boolValue ?? false
    }
}

struct CodexRuntimeInfo: Equatable {
    let version: String?
    let source: String
    let compatibility: String
    let minimumSupportedVersion: String
    let maximumTestedVersion: String

    init?(json: JSONValue?) {
        guard let json, let source = json["source"]?.stringValue,
              let compatibility = json["compatibility"]?.stringValue else { return nil }
        version = json["version"]?.stringValue
        self.source = source
        self.compatibility = compatibility
        minimumSupportedVersion = json["minimumSupportedVersion"]?.stringValue ?? ""
        maximumTestedVersion = json["maximumTestedVersion"]?.stringValue ?? ""
    }

    var sourceLabel: String {
        switch source {
        case "codexDesktop": return "Codex Desktop"
        case "configured": return "自定义路径"
        default: return "Relay 内置"
        }
    }

    var compatibilityLabel: String {
        switch compatibility {
        case "compatible": return "兼容"
        case "outdated": return "版本过旧"
        case "untested": return "尚未验证"
        default: return "无法检测"
        }
    }
}

enum GoalStatus: String, Equatable {
    case active
    case paused
    case blocked
    case usageLimited = "usage_limited"
    case budgetLimited = "budget_limited"
    case complete

    var label: String {
        switch self {
        case .active: return "进行中的目标"
        case .paused: return "已暂停的目标"
        case .blocked: return "目标已阻塞"
        case .usageLimited: return "目标已达用量限制"
        case .budgetLimited: return "目标已达预算"
        case .complete: return "目标已完成"
        }
    }

    var protocolValue: String {
        switch self {
        case .usageLimited: return "usageLimited"
        case .budgetLimited: return "budgetLimited"
        default: return rawValue
        }
    }

    init?(protocolValue: String) {
        switch protocolValue {
        case "active": self = .active
        case "paused": self = .paused
        case "blocked": self = .blocked
        case "usageLimited", "usage_limited": self = .usageLimited
        case "budgetLimited", "budget_limited": self = .budgetLimited
        case "complete": self = .complete
        default: return nil
        }
    }
}

struct GoalState: Identifiable, Equatable {
    let id: String
    let threadId: String
    let objective: String
    let status: GoalStatus
    let tokenBudget: Int?
    let tokensUsed: Int
    let timeUsedSeconds: Int
    let createdAt: Date
    let updatedAt: Date

    init?(json: JSONValue) {
        guard let threadId = json["threadId"]?.stringValue,
              let objective = json["objective"]?.stringValue,
              let rawStatus = json["status"]?.stringValue,
              let status = GoalStatus(protocolValue: rawStatus) else { return nil }
        id = json["id"]?.stringValue ?? "goal.\(threadId)"
        self.threadId = threadId
        self.objective = objective
        self.status = status
        tokenBudget = json["tokenBudget"]?.intValue
        tokensUsed = json["tokensUsed"]?.intValue ?? 0
        timeUsedSeconds = json["timeUsedSeconds"]?.intValue ?? 0
        createdAt = Self.date(json["createdAt"]?.doubleValue)
        updatedAt = Self.date(json["updatedAt"]?.doubleValue)
    }

    private static func date(_ rawValue: Double?) -> Date {
        guard let rawValue else { return Date() }
        let seconds = rawValue > 10_000_000_000 ? rawValue / 1_000 : rawValue
        return Date(timeIntervalSince1970: seconds)
    }
}

enum ComposerMode: String, Equatable {
    case standard
    case plan
    case goal

    var title: String {
        switch self {
        case .standard: return "默认模式"
        case .plan: return "计划模式"
        case .goal: return "目标模式"
        }
    }

    var icon: String {
        switch self {
        case .standard: return "message"
        case .plan: return "list.bullet.clipboard"
        case .goal: return "scope"
        }
    }
}

struct CollaborationModeOption: Identifiable, Equatable {
    let name: String
    let mode: String
    let model: String?
    let reasoningEffort: String?

    var id: String { mode }

    init?(json: JSONValue) {
        guard let name = json["name"]?.stringValue,
              let mode = json["mode"]?.stringValue else { return nil }
        self.name = name
        self.mode = mode
        model = json["model"]?.stringValue
        reasoningEffort = json["reasoning_effort"]?.stringValue
    }

    func payload(fallbackModel: String, fallbackEffort: String?) -> JSONValue {
        var settings: [String: JSONValue] = [
            "model": .string(model ?? fallbackModel),
            "developer_instructions": .null
        ]
        if let effort = reasoningEffort ?? fallbackEffort, !effort.isEmpty {
            settings["reasoning_effort"] = .string(effort)
        } else {
            settings["reasoning_effort"] = .null
        }
        return .object([
            "mode": .string(mode),
            "settings": .object(settings)
        ])
    }
}

enum WorkspaceAccessMode: String, Codable, CaseIterable, Identifiable {
    case readOnly
    case workspaceWrite
    case fullAccess

    var id: String { rawValue }
    var title: String {
        switch self {
        case .readOnly: return "只读"
        case .workspaceWrite: return "工作区写入"
        case .fullAccess: return "完全访问"
        }
    }
    var detail: String {
        switch self {
        case .readOnly: return "可以查看文件，但不能修改"
        case .workspaceWrite: return "可以修改当前工作区内的文件"
        case .fullAccess: return "可以访问这台电脑上的所有文件和网络"
        }
    }
    var threadSandbox: String {
        switch self {
        case .readOnly: return "read-only"
        case .workspaceWrite: return "workspace-write"
        case .fullAccess: return "danger-full-access"
        }
    }

    var approvalPolicy: String {
        self == .fullAccess ? "never" : "on-request"
    }
    func sandboxPolicy(workingDirectory: String) -> JSONValue {
        switch self {
        case .readOnly:
            return .object(["type": .string("readOnly"), "networkAccess": .bool(false)])
        case .workspaceWrite:
            let roots: [JSONValue] = workingDirectory.isEmpty ? [] : [.string(workingDirectory)]
            return .object([
                "type": .string("workspaceWrite"),
                "writableRoots": .array(roots),
                "networkAccess": .bool(false)
            ])
        case .fullAccess:
            return .object(["type": .string("dangerFullAccess")])
        }
    }
}

struct PendingAttachment: Identifiable, Equatable {
    enum State: Equatable { case uploading, ready, failed(String) }
    let id: UUID
    let name: String
    let localURL: URL
    var remotePath: String?
    var size: Int64
    var progress: Double
    var state: State
    var isImage: Bool
}

enum FollowUpBehavior: String, Codable, CaseIterable, Identifiable {
    case steer
    case queue

    var id: String { rawValue }
    var title: String { self == .steer ? "立即引导" : "等待处理" }
    var detail: String {
        self == .steer ? "立即补充到当前任务，发出后不可编辑" : "当前任务结束后发送，处理前可编辑"
    }
}

struct QueuedFollowUp: Identifiable, Equatable {
    let id: String
    let threadId: String
    let clientUserMessageId: String
    let text: String
    let attachmentNames: [String]
    let createdAt: Date
    let input: [JSONValue]

    init?(json: JSONValue) {
        guard let id = json["id"]?.stringValue,
              let threadId = json["threadId"]?.stringValue,
              let clientUserMessageId = json["clientUserMessageId"]?.stringValue else { return nil }
        self.id = id
        self.threadId = threadId
        self.clientUserMessageId = clientUserMessageId
        text = json["text"]?.stringValue ?? ""
        createdAt = Date(timeIntervalSince1970: json["createdAt"]?.doubleValue ?? 0)
        let parsedInput = json["input"]?.arrayValue ?? []
        input = parsedInput
        attachmentNames = parsedInput.compactMap { input in
            guard input["type"]?.stringValue != "text" else { return nil }
            if let name = input["name"]?.stringValue?.nonEmpty { return name }
            guard let path = input["path"]?.stringValue?.nonEmpty else { return nil }
            return path.lastPathComponentForDisplay
        }
    }

    var displayText: String {
        if let text = text.nonEmpty { return text }
        return attachmentNames.joined(separator: "、")
    }

    var imagePaths: [String] {
        input.compactMap { value in
            guard value["type"]?.stringValue == "localImage" else { return nil }
            return value["path"]?.stringValue?.nonEmpty
        }
    }

    var nonImageAttachmentNames: [String] {
        input.compactMap { value in
            guard value["type"]?.stringValue != "text",
                  value["type"]?.stringValue != "localImage" else { return nil }
            if let name = value["name"]?.stringValue?.nonEmpty { return name }
            guard let path = value["path"]?.stringValue?.nonEmpty else { return nil }
            return path.lastPathComponentForDisplay
        }
    }
}

struct SharedFile: Identifiable {
    let id = UUID()
    let url: URL
}

struct ImagePreviewPresentation: Identifiable, Equatable {
    var id: String { path }
    let path: String
    let url: URL
}

struct ExecutionPlanStep: Identifiable, Codable, Equatable {
    let id: String
    let text: String
    let status: String

    var normalizedStatus: String {
        status.replacingOccurrences(of: "_", with: "").lowercased()
    }
    var isCompleted: Bool { normalizedStatus == "completed" }
    var isRunning: Bool {
        normalizedStatus == "inprogress" || normalizedStatus == "running" || normalizedStatus == "active"
    }
}

struct ThreadSummary: Identifiable, Equatable, Codable {
    let id: String
    var title: String
    var preview: String
    var cwd: String
    var updatedAt: Date
    var status: String

    var isRunning: Bool {
        let normalized = status
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
        return ["active", "running", "inprogress", "started", "pending", "queued", "processing"].contains(normalized)
    }

    init?(json: JSONValue) {
        guard let id = json["id"]?.stringValue else { return nil }
        self.id = id
        preview = json["preview"]?.stringValue ?? ""
        title = json["name"]?.stringValue?.nonEmpty
            ?? json["title"]?.stringValue?.nonEmpty
            ?? preview.nonEmpty
            ?? "New task"
        cwd = json["cwd"]?.stringValue ?? ""
        var updatedSeconds = 0.0
        for key in ["updatedAt", "updated_at", "recencyAt", "recency_at", "createdAt", "created_at"] {
            if let value = json[key]?.doubleValue {
                updatedSeconds = value
                break
            }
        }
        updatedAt = Date(timeIntervalSince1970: updatedSeconds)
        status = json["status"]?["type"]?.stringValue
            ?? json["status"]?.stringValue
            ?? "idle"
    }
}

struct ReasoningEffortOption: Identifiable, Equatable {
    let id: String
    let description: String

    init?(json: JSONValue) {
        guard let id = json["reasoningEffort"]?.stringValue else { return nil }
        self.id = id
        description = json["description"]?.stringValue ?? ""
    }

    var displayName: String {
        switch id.lowercased() {
        case "none": return "关闭"
        case "minimal": return "最低"
        case "low": return "低"
        case "medium": return "中"
        case "high": return "高"
        case "xhigh": return "最高"
        case "ultra": return "极高+"
        default: return id
        }
    }
}

struct CodexModelOption: Identifiable, Equatable {
    let id: String
    let model: String
    let displayName: String
    let description: String
    let isDefault: Bool
    let efforts: [ReasoningEffortOption]
    let defaultEffort: String

    init?(json: JSONValue) {
        guard let id = json["id"]?.stringValue,
              let model = json["model"]?.stringValue else { return nil }
        self.id = id
        self.model = model
        displayName = json["displayName"]?.stringValue ?? model
        description = json["description"]?.stringValue ?? ""
        isDefault = json["isDefault"]?.boolValue ?? false
        efforts = json["supportedReasoningEfforts"]?.arrayValue?.compactMap(ReasoningEffortOption.init(json:)) ?? []
        defaultEffort = json["defaultReasoningEffort"]?.stringValue ?? efforts.first?.id ?? "medium"
    }
}

struct TokenUsageBreakdown: Equatable {
    var inputTokens = 0
    var cachedInputTokens = 0
    var outputTokens = 0
    var reasoningOutputTokens = 0
    var totalTokens = 0

    init(json: JSONValue?) {
        inputTokens = json?["inputTokens"]?.intValue ?? 0
        cachedInputTokens = json?["cachedInputTokens"]?.intValue ?? 0
        outputTokens = json?["outputTokens"]?.intValue ?? 0
        reasoningOutputTokens = json?["reasoningOutputTokens"]?.intValue ?? 0
        totalTokens = json?["totalTokens"]?.intValue ?? 0
    }
}

struct ThreadTokenUsage: Equatable {
    var last: TokenUsageBreakdown
    var total: TokenUsageBreakdown
    var modelContextWindow: Int?

    init(json: JSONValue) {
        last = TokenUsageBreakdown(json: json["last"])
        total = TokenUsageBreakdown(json: json["total"])
        modelContextWindow = json["modelContextWindow"]?.intValue
    }

    var contextPercentage: Int? {
        guard let modelContextWindow, modelContextWindow > 0 else { return nil }
        return min(100, max(0, Int((Double(last.totalTokens) / Double(modelContextWindow)) * 100)))
    }
}

struct TurnMetadata: Equatable {
    var status = "completed"
    var startedAt: Date?
    var completedAt: Date?
    var durationMs: Int?
    var errorMessage: String?

    init() {}

    init(json: JSONValue) {
        status = json["status"]?.stringValue ?? "completed"
        if let value = json["startedAt"]?.doubleValue { startedAt = Date(timeIntervalSince1970: value) }
        if let value = json["completedAt"]?.doubleValue { completedAt = Date(timeIntervalSince1970: value) }
        durationMs = json["durationMs"]?.intValue
        errorMessage = json["error"]?["message"]?.stringValue
    }

    var isRunning: Bool {
        let normalized = status
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
        return ["inprogress", "active", "running", "started", "pending", "queued", "processing"].contains(normalized)
    }

    var isFailed: Bool {
        let normalized = status
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
        return errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            || ["failed", "error", "cancelled", "canceled"].contains(normalized)
    }

    var allowsPromptEditing: Bool {
        let normalized = status
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
        return errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            || ["failed", "error", "cancelled", "canceled", "interrupted", "aborted"].contains(normalized)
    }
}

enum TranscriptRole: Equatable {
    case user
    case assistant
    case tool
    case system
}

enum MessageDeliveryState: Equatable {
    case sending
    case accepted
    case uncertain(String)
    case failed(String)
}

enum TranscriptKind: Equatable {
    case message
    case command
    case fileChange
    case reasoning
    case webSearch
    case plan
    case contextCompaction
    case image
    case subagent
    case other
}

struct AgentMessageContent: Equatable {
    let visibleText: String
    let thinkingText: String?
    let containsThinking: Bool

    static func parse(_ source: String) -> AgentMessageContent {
        let fullPattern = #"<thinking\b[^>]*>([\s\S]*?)</thinking\s*>"#
        let openPattern = #"<thinking\b[^>]*>"#
        guard let fullExpression = try? NSRegularExpression(pattern: fullPattern, options: [.caseInsensitive]),
              let openExpression = try? NSRegularExpression(pattern: openPattern, options: [.caseInsensitive]) else {
            return AgentMessageContent(
                visibleText: CodexClientDirectiveFilter.cleanAssistantText(source),
                thinkingText: nil,
                containsThinking: false
            )
        }

        let fullRange = NSRange(source.startIndex..., in: source)
        let matches = fullExpression.matches(in: source, range: fullRange)
        if !matches.isEmpty {
            let thoughts = matches.compactMap { match -> String? in
                guard match.numberOfRanges > 1,
                      let range = Range(match.range(at: 1), in: source) else { return nil }
                return String(source[range]).trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            }
            let mutable = NSMutableString(string: source)
            for match in matches.reversed() { mutable.replaceCharacters(in: match.range, with: "") }
            let visible = CodexClientDirectiveFilter.cleanAssistantText(String(mutable)
                .replacingOccurrences(of: #"</?thinking\b[^>]*>"#, with: "", options: [.regularExpression, .caseInsensitive])
                .trimmingCharacters(in: .whitespacesAndNewlines))
            return AgentMessageContent(
                visibleText: visible,
                thinkingText: thoughts.joined(separator: "\n").nonEmpty,
                containsThinking: true
            )
        }

        if let open = openExpression.firstMatch(in: source, range: fullRange),
           let openRange = Range(open.range, in: source) {
            let visible = CodexClientDirectiveFilter.cleanAssistantText(
                String(source[..<openRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            )
            let thinking = String(source[openRange.upperBound...])
                .replacingOccurrences(of: #"</thinking\s*>"#, with: "", options: [.regularExpression, .caseInsensitive])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return AgentMessageContent(visibleText: visible, thinkingText: thinking.nonEmpty, containsThinking: true)
        }

        let visible = CodexClientDirectiveFilter.cleanAssistantText(
            source.replacingOccurrences(of: #"</thinking\s*>"#, with: "", options: [.regularExpression, .caseInsensitive])
        )
        return AgentMessageContent(visibleText: visible, thinkingText: nil, containsThinking: false)
    }
}

enum CodexClientDirectiveFilter {
    private static let directiveNames = [
        "git-stage",
        "git-commit",
        "git-push",
        "git-create-branch",
        "git-create-pr",
        "created-thread",
        "code-comment",
        "archive",
    ]

    static func cleanAssistantText(_ source: String) -> String {
        var contentEnd = source.endIndex
        while contentEnd > source.startIndex, source[source.index(before: contentEnd)].isWhitespace {
            contentEnd = source.index(before: contentEnd)
        }
        let lastLineStart = source[..<contentEnd].lastIndex(of: "\n")
            .map { source.index(after: $0) }
            ?? source.startIndex
        guard isDirectiveSequence(String(source[lastLineStart..<contentEnd]), allowIncompleteTail: true) else {
            return source
        }

        var lines = source.components(separatedBy: "\n")
        guard !lines.isEmpty else { return source }

        var firstRemovedIndex = lines.count
        var foundDirective = false
        var index = lines.count - 1
        while index >= 0 {
            let line = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty {
                if foundDirective { firstRemovedIndex = index }
            } else if isDirectiveSequence(line, allowIncompleteTail: !foundDirective) {
                foundDirective = true
                firstRemovedIndex = index
            } else {
                break
            }
            index -= 1
        }

        guard foundDirective, !isInsideCodeFence(lines: lines, before: firstRemovedIndex) else { return source }
        lines.removeSubrange(firstRemovedIndex...)
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isDirectiveSequence(_ line: String, allowIncompleteTail: Bool) -> Bool {
        var index = line.startIndex
        var parsedDirective = false

        while true {
            skipWhitespace(in: line, index: &index)
            guard index < line.endIndex else { return parsedDirective }

            let remainder = String(line[index...])
            let marker = directiveNames
                .map { "::\($0){" }
                .first(where: { remainder.hasPrefix($0) })
            if marker == nil {
                return allowIncompleteTail
                    && directiveNames.map { "::\($0){" }.contains(where: { $0.hasPrefix(remainder) })
                    && (!parsedDirective || remainder.hasPrefix("::"))
            }

            index = line.index(index, offsetBy: marker!.count)
            var depth = 1
            var quote: Character?
            var escaped = false
            while index < line.endIndex {
                let character = line[index]
                index = line.index(after: index)
                if escaped {
                    escaped = false
                    continue
                }
                if character == "\\", quote != nil {
                    escaped = true
                    continue
                }
                if let activeQuote = quote {
                    if character == activeQuote { quote = nil }
                    continue
                }
                if character == "\"" || character == "'" {
                    quote = character
                } else if character == "{" {
                    depth += 1
                } else if character == "}" {
                    depth -= 1
                    if depth == 0 { break }
                }
            }
            guard depth == 0 else { return allowIncompleteTail }
            parsedDirective = true
        }
    }

    private static func skipWhitespace(in value: String, index: inout String.Index) {
        while index < value.endIndex, value[index].isWhitespace { index = value.index(after: index) }
    }

    private static func isInsideCodeFence(lines: [String], before endIndex: Int) -> Bool {
        var activeFence: String?
        for line in lines.prefix(endIndex) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let marker = ["```", "~~~"].first(where: { trimmed.hasPrefix($0) }) else { continue }
            if activeFence == marker {
                activeFence = nil
            } else if activeFence == nil {
                activeFence = marker
            }
        }
        return activeFence != nil
    }
}

struct TranscriptItem: Identifiable, Equatable {
    var id: String
    var turnId: String?
    var role: TranscriptRole
    var kind: TranscriptKind
    var title: String?
    var text: String
    var detail: String?
    var status: String?
    var phase: String?
    var durationMs: Int?
    var exitCode: Int?
    var cwd: String?
    var errorMessage: String?
    var deliveryState: MessageDeliveryState?
    var imagePaths: [String]
    var goal: String?
    var rawAgentText: String?
    var createdAt: Date?

    init(
        id: String,
        turnId: String? = nil,
        role: TranscriptRole,
        kind: TranscriptKind,
        title: String? = nil,
        text: String,
        detail: String? = nil,
        status: String? = nil,
        phase: String? = nil,
        durationMs: Int? = nil,
        exitCode: Int? = nil,
        cwd: String? = nil,
        errorMessage: String? = nil,
        deliveryState: MessageDeliveryState? = nil,
        imagePaths: [String] = [],
        goal: String? = nil,
        rawAgentText: String? = nil,
        createdAt: Date? = nil
    ) {
        self.id = id
        self.turnId = turnId
        self.role = role
        self.kind = kind
        self.title = title
        self.text = text
        self.detail = detail
        self.status = status
        self.phase = phase
        self.durationMs = durationMs
        self.exitCode = exitCode
        self.cwd = cwd
        self.errorMessage = errorMessage
        self.deliveryState = deliveryState
        self.imagePaths = imagePaths
        self.goal = goal
        self.rawAgentText = rawAgentText
        self.createdAt = createdAt
    }

    var isCommentary: Bool { role == .assistant && phase == "commentary" }
    var isFinalAnswer: Bool { role == .assistant && phase != "commentary" }
    var isVisibleAssistantOutput: Bool {
        role == .assistant
            && kind == .message
            && !isCommentary
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    var isVisibleTaskActivity: Bool {
        guard role != .user else { return false }
        if role == .assistant && kind == .message {
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasDetail = detail?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        switch kind {
        case .reasoning:
            return hasText || hasDetail
        case .message:
            return hasText
        default:
            let hasTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            return hasText || hasDetail || hasTitle
        }
    }
    var isActivity: Bool { role == .tool || isCommentary }
    var isRunningStatus: Bool {
        let normalized = status?
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .lowercased() ?? ""
        return normalized.contains("progress") || normalized == "running" || normalized == "active"
    }
    var isFailedStatus: Bool {
        let normalized = status?.lowercased() ?? ""
        return normalized.contains("fail") || (exitCode.map { $0 != 0 } ?? false)
    }
    var downloadablePaths: [String] {
        if kind == .fileChange || kind == .image {
            return text.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
        }
        guard role == .assistant else { return [] }
        let pattern = #"\]\(<?([^)>]+)>?\)"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return expression.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > 1, let valueRange = Range(match.range(at: 1), in: text) else { return nil }
            var value = String(text[valueRange]).removingPercentEncoding ?? String(text[valueRange])
            if let lineSuffix = value.range(of: #":\d+$"#, options: .regularExpression) { value.removeSubrange(lineSuffix) }
            let normalized = value.replacingOccurrences(of: "\\", with: "/")
            guard normalized.range(of: #"^[A-Za-z]:/"#, options: .regularExpression) != nil else { return nil }
            return value
        }
    }
    var textWithoutDownloadLinks: String {
        guard role == .assistant, !downloadablePaths.isEmpty else { return text }
        let pattern = #"\[[^\]]+\]\(<?[A-Za-z]:[\\/][^)>]+>?\)"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return text }
        return text.components(separatedBy: .newlines).compactMap { line in
            let range = NSRange(line.startIndex..., in: line)
            guard expression.firstMatch(in: line, range: range) != nil else { return line }
            let stripped = expression.stringByReplacingMatches(in: line, range: range, withTemplate: "")
            return stripped.trimmingCharacters(in: .whitespaces).isEmpty ? nil : stripped
        }.joined(separator: "\n")
    }

    static func from(json: JSONValue, turnId: String? = nil) -> TranscriptItem? {
        guard let serverId = json["id"]?.stringValue, let type = json["type"]?.stringValue else { return nil }
        let id = type == "userMessage" ? (json["clientId"]?.stringValue ?? serverId) : serverId
        let createdAt = json["createdAt"]?.doubleValue.map { Date(timeIntervalSince1970: $0) }
            ?? codexTimestamp(from: serverId)
        switch type {
        case "userMessage":
            var imagePaths: [String] = []
            var goalObjective: String?
            let text = json["content"]?.arrayValue?
                .compactMap { content -> String? in
                    if let text = content["text"]?.stringValue {
                        let parsed = extractImageMarkup(text)
                        for path in parsed.paths where !imagePaths.contains(path) { imagePaths.append(path) }
                        let visible = extractGoalContext(cleanDesktopUserText(parsed.text))
                        if goalObjective == nil { goalObjective = visible.objective }
                        return visible.text.nonEmpty
                    }
                    if content["type"]?.stringValue == "mention" {
                        return "📎 \(content["name"]?.stringValue ?? content["path"]?.stringValue?.lastPathComponentForDisplay ?? "文件")"
                    }
                    if ["localImage", "image"].contains(content["type"]?.stringValue ?? "") {
                        if let path = content["path"]?.stringValue, !imagePaths.contains(path) {
                            imagePaths.append(path)
                        }
                        return nil
                    }
                    return nil
                }
                .joined(separator: "\n") ?? ""
            if isInternalEnvironmentContext(text), imagePaths.isEmpty { return nil }
            return TranscriptItem(id: id, turnId: turnId, role: .user, kind: .message, text: text, imagePaths: imagePaths, goal: goalObjective, createdAt: createdAt)
        case "agentMessage":
            let rawText = json["text"]?.stringValue ?? ""
            let content = AgentMessageContent.parse(rawText)
            return TranscriptItem(
                id: id,
                turnId: turnId,
                role: .assistant,
                kind: .message,
                text: content.visibleText,
                detail: content.thinkingText,
                phase: json["phase"]?.stringValue ?? (content.containsThinking ? "commentary" : nil),
                rawAgentText: content.containsThinking || content.visibleText != rawText ? rawText : nil,
                createdAt: createdAt
            )
        case "reasoning":
            let summary = json["summary"]?.arrayValue?.compactMap { $0.stringValue }.joined(separator: "\n\n") ?? ""
            let content = json["content"]?.arrayValue?.compactMap { $0.stringValue }.joined(separator: "\n\n") ?? ""
            return TranscriptItem(id: id, turnId: turnId, role: .tool, kind: .reasoning, title: "思考", text: summary, detail: content, createdAt: createdAt)
        case "commandExecution":
            let command = json["command"]?.stringValue ?? "Command"
            let output = json["aggregatedOutput"]?.stringValue
            let exitCode = json["exitCode"]?.intValue
            return TranscriptItem(
                id: id,
                turnId: turnId,
                role: .tool,
                kind: .command,
                title: commandTitle(json: json),
                text: command,
                detail: output,
                status: json["status"]?.stringValue,
                durationMs: json["durationMs"]?.intValue,
                exitCode: exitCode,
                cwd: json["cwd"]?.stringValue,
                errorMessage: (exitCode ?? 0) != 0 ? commandFailureSummary(output) : nil,
                createdAt: createdAt
            )
        case "fileChange":
            let changes = json["changes"]?.arrayValue ?? []
            let paths = changes.compactMap { $0["path"]?.stringValue }.joined(separator: "\n")
            let diffs = changes.compactMap { $0["diff"]?.stringValue }.joined(separator: "\n\n")
            return TranscriptItem(id: id, turnId: turnId, role: .tool, kind: .fileChange, title: "修改文件", text: paths, detail: diffs, status: json["status"]?.stringValue, createdAt: createdAt)
        case "webSearch":
            return TranscriptItem(id: id, turnId: turnId, role: .tool, kind: .webSearch, title: "搜索网页", text: json["query"]?.stringValue ?? "", createdAt: createdAt)
        case "mcpToolCall":
            let name = json["tool"]?.stringValue ?? "MCP tool"
            let server = json["server"]?.stringValue ?? ""
            if isCommandTool(name: name, namespace: server) {
                return commandToolItem(id: id, turnId: turnId, json: json, name: name)
            }
            let result = prettyJSON(json["result"]) ?? prettyJSON(json["error"]) ?? prettyJSON(json["arguments"])
            return TranscriptItem(id: id, turnId: turnId, role: .tool, kind: .other, title: friendlyToolTitle(name: name, namespace: server), text: friendlyToolSummary(name: name, namespace: server), detail: result, status: json["status"]?.stringValue, durationMs: json["durationMs"]?.intValue, errorMessage: readableError(json))
        case "dynamicToolCall":
            let name = json["tool"]?.stringValue ?? "Tool"
            let namespace = json["namespace"]?.stringValue ?? ""
            if isCommandTool(name: name, namespace: namespace) {
                return commandToolItem(id: id, turnId: turnId, json: json, name: name)
            }
            let detail = prettyJSON(json["contentItems"]) ?? prettyJSON(json["result"]) ?? prettyJSON(json["arguments"])
            return TranscriptItem(id: id, turnId: turnId, role: .tool, kind: .other, title: friendlyToolTitle(name: name, namespace: namespace), text: friendlyToolSummary(name: name, namespace: namespace), detail: detail, status: json["status"]?.stringValue, durationMs: json["durationMs"]?.intValue, errorMessage: readableError(json))
        case "collabAgentToolCall":
            let tool = json["tool"]?.stringValue ?? "Agent"
            let prompt = json["prompt"]?.stringValue ?? ""
            return TranscriptItem(id: id, turnId: turnId, role: .tool, kind: .subagent, title: "协作代理 · \(tool)", text: prompt, detail: prettyJSON(json["agentsStates"]), status: json["status"]?.stringValue)
        case "subAgentActivity":
            return TranscriptItem(id: id, turnId: turnId, role: .tool, kind: .subagent, title: "子代理", text: json["agentPath"]?.stringValue ?? "", detail: json["kind"]?.stringValue)
        case "plan":
            return TranscriptItem(id: id, turnId: turnId, role: .tool, kind: .plan, title: "计划", text: json["text"]?.stringValue ?? "", createdAt: createdAt)
        case "contextCompaction":
            return TranscriptItem(id: id, turnId: turnId, role: .tool, kind: .contextCompaction, title: "已压缩上下文", text: "Codex 已整理较早的对话内容，为后续工作释放上下文空间。", status: "completed")
        case "imageView":
            return TranscriptItem(id: id, turnId: turnId, role: .tool, kind: .image, title: "查看图片", text: json["path"]?.stringValue ?? "")
        case "imageGeneration":
            return TranscriptItem(id: id, turnId: turnId, role: .tool, kind: .image, title: "生成图片", text: json["savedPath"]?.stringValue ?? json["result"]?.stringValue ?? "", status: json["status"]?.stringValue)
        case "enteredReviewMode":
            return TranscriptItem(id: id, turnId: turnId, role: .tool, kind: .other, title: "开始审查", text: json["review"]?.stringValue ?? "")
        case "exitedReviewMode":
            return TranscriptItem(id: id, turnId: turnId, role: .tool, kind: .other, title: "完成审查", text: json["review"]?.stringValue ?? "", status: "completed")
        case "sleep":
            return TranscriptItem(id: id, turnId: turnId, role: .tool, kind: .other, title: "等待", text: formatDuration(milliseconds: json["durationMs"]?.intValue ?? 0), status: "completed")
        default:
            return nil
        }
    }

    private static func codexTimestamp(from identifier: String) -> Date? {
        guard let raw = identifier.split(separator: "_").last else { return nil }
        let groups = raw.split(separator: "-")
        guard groups.count == 5,
              groups[0].count == 8,
              groups[1].count == 4,
              groups[2].first == "7",
              let milliseconds = UInt64(String(groups[0]) + String(groups[1]), radix: 16) else { return nil }
        return Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
    }

    private static func commandTitle(json: JSONValue) -> String {
        guard let action = json["commandActions"]?.arrayValue?.first else { return "运行命令" }
        let type = action["type"]?.stringValue ?? action["kind"]?.stringValue ?? ""
        switch type {
        case "read": return "读取文件"
        case "search": return "搜索代码"
        case "listFiles": return "列出文件"
        case "write": return "写入文件"
        case "delete": return "删除文件"
        case "run": return "运行命令"
        default: return "运行命令"
        }
    }

    private static func isCommandTool(name: String, namespace: String) -> Bool {
        let normalizedName = name.lowercased()
        let combined = "\(namespace) \(name)".lowercased()
        return normalizedName == "exec"
            || normalizedName == "exec_command"
            || normalizedName == "shell_command"
            || combined.contains(" shell_command")
            || combined.contains(" exec_command")
    }

    private static func commandToolItem(
        id: String,
        turnId: String?,
        json: JSONValue,
        name: String
    ) -> TranscriptItem {
        let arguments = json["arguments"] ?? json["input"]
        let command = extractCommand(arguments)
            ?? (name.lowercased() == "exec" ? "执行命令" : name)
        let output = prettyJSON(json["contentItems"])
            ?? prettyJSON(json["result"])
            ?? prettyJSON(json["error"])
        return TranscriptItem(
            id: id,
            turnId: turnId,
            role: .tool,
            kind: .command,
            title: "运行命令",
            text: command,
            detail: output,
            status: json["status"]?.stringValue,
            durationMs: json["durationMs"]?.intValue,
            exitCode: json["exitCode"]?.intValue,
            cwd: json["cwd"]?.stringValue,
            errorMessage: readableError(json)
        )
    }

    private static func extractCommand(_ value: JSONValue?) -> String? {
        guard let value else { return nil }
        if let object = value.objectValue {
            for key in ["command", "cmd", "script"] {
                if let command = object[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !command.isEmpty {
                    return command
                }
            }
        }
        guard let raw = value.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }

        if let data = raw.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(JSONValue.self, from: data),
           decoded != value,
           let nested = extractCommand(decoded) {
            return nested
        }

        let pattern = #"(?s)\bcommand\s*:\s*(\"(?:\\.|[^\"\\])*\")"#
        if let expression = try? NSRegularExpression(pattern: pattern),
           let match = expression.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
           match.numberOfRanges > 1,
           let quotedRange = Range(match.range(at: 1), in: raw) {
            let quoted = String(raw[quotedRange])
            if let data = quoted.data(using: .utf8),
               let decoded = try? JSONDecoder().decode(String.self, from: data),
               !decoded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return decoded
            }
        }

        return raw.contains("tools.shell_command") ? nil : raw
    }

    private static func cleanDesktopUserText(_ text: String) -> String {
        let pattern = #"(?im)^\s*#{0,6}\s*My request(?: for Codex)?:\s*$"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let markerRange = Range(match.range, in: text) else { return text }
        return String(text[markerRange.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func extractGoalContext(_ text: String) -> (text: String, objective: String?) {
        let blockPattern = #"<codex_internal_context\b[^>]*\bsource\s*=\s*[\"']goal[\"'][^>]*>([\s\S]*?)</codex_internal_context>"#
        guard let blocks = try? NSRegularExpression(pattern: blockPattern, options: [.caseInsensitive]) else {
            return (text, nil)
        }
        var objective: String?
        for match in blocks.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard match.numberOfRanges > 1, let contentRange = Range(match.range(at: 1), in: text) else { continue }
            let content = String(text[contentRange])
            let objectivePattern = #"<objective>([\s\S]*?)</objective>"#
            guard let expression = try? NSRegularExpression(pattern: objectivePattern, options: [.caseInsensitive]),
                  let objectiveMatch = expression.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)),
                  objectiveMatch.numberOfRanges > 1,
                  let valueRange = Range(objectiveMatch.range(at: 1), in: content) else { continue }
            let candidate = String(content[valueRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !candidate.isEmpty { objective = candidate; break }
        }
        let cleaned = blocks.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (cleaned, objective)
    }

    private static func extractImageMarkup(_ text: String) -> (text: String, paths: [String]) {
        let pattern = #"<image\b[^>]*\bpath\s*=\s*(?:\"([^\"]+)\"|'([^']+)'|([^\s>]+))[^>]*>"#
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return (text, [])
        }
        let range = NSRange(text.startIndex..., in: text)
        let matches = expression.matches(in: text, range: range)
        var paths: [String] = []
        for match in matches {
            for index in 1..<match.numberOfRanges where match.range(at: index).location != NSNotFound {
                if let valueRange = Range(match.range(at: index), in: text) {
                    let path = String(text[valueRange])
                    if !path.isEmpty, !paths.contains(path) { paths.append(path) }
                    break
                }
            }
        }
        let withoutOpeningTags = expression.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        let cleaned = withoutOpeningTags.replacingOccurrences(
            of: #"</image\s*>"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        let compacted = cleaned.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return (compacted.trimmingCharacters(in: .whitespacesAndNewlines), paths)
    }

    private static func isInternalEnvironmentContext(_ text: String) -> Bool {
        let pattern = #"^\s*<environment_context\b[^>]*>[\s\S]*</environment_context>\s*$"#
        return text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func commandFailureSummary(_ output: String?) -> String? {
        let lines = output?
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []
        guard let line = lines.last else { return nil }
        return String(line.prefix(240))
    }

    private static func friendlyToolTitle(name: String, namespace: String) -> String {
        let combined = "\(namespace) \(name)".lowercased()
        if combined.contains("node_repl") || combined.contains("computer") { return "控制 Windows 应用" }
        if combined.contains("browser") || combined.contains("playwright") { return "操作浏览器" }
        if combined.contains("shell") || combined.contains("exec") { return "运行命令" }
        if combined.contains("image") { return "处理图片" }
        return "运行工具"
    }

    private static func friendlyToolSummary(name: String, namespace: String) -> String {
        let combined = "\(namespace) \(name)".lowercased()
        if combined.contains("node_repl") || combined.contains("computer") { return "正在与 Windows 上的应用交互" }
        if combined.contains("browser") || combined.contains("playwright") { return "正在浏览和操作网页" }
        if combined.contains("shell") || combined.contains("exec") { return "正在 Windows 上执行操作" }
        return name == "Tool" ? "" : name
    }

    private static func readableError(_ json: JSONValue) -> String? {
        for candidate in [json["error"], json["result"], json["contentItems"]] {
            if let message = findErrorText(candidate), !message.isEmpty { return message }
        }
        return nil
    }

    private static func findErrorText(_ value: JSONValue?) -> String? {
        guard let value else { return nil }
        if let object = value.objectValue {
            for key in ["message", "error", "text", "detail", "reason"] {
                if let text = object[key]?.stringValue, !text.isEmpty { return text }
            }
            for child in object.values {
                if let text = findErrorText(child) { return text }
            }
        } else if let array = value.arrayValue {
            for child in array {
                if let text = findErrorText(child) { return text }
            }
        }
        return nil
    }

    private static func prettyJSON(_ value: JSONValue?) -> String? {
        guard let value,
              JSONSerialization.isValidJSONObject(value.rawValue),
              let data = try? JSONSerialization.data(withJSONObject: value.rawValue, options: [.prettyPrinted, .sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

struct TranscriptGroup: Identifiable, Equatable {
    let id: String
    let turnId: String?
    let revision: Int
    var items: [TranscriptItem]
    var metadata: TurnMetadata

    var userItems: [TranscriptItem] { items.filter { $0.role == .user } }
    var activityItems: [TranscriptItem] { items.filter(\.isActivity) }
    var answerItems: [TranscriptItem] { items.filter(\.isFinalAnswer) }
}

struct ApprovalRequest: Identifiable, Equatable {
    let id: String
    let rpcId: JSONValue
    let method: String
    let threadId: String?
    let turnId: String?
    let requestedPermissions: JSONValue?
    let title: String
    let summary: String
    let detail: String

    init?(message: JSONValue) {
        guard let rpcId = message["id"], let method = message["method"]?.stringValue else { return nil }
        id = rpcId.stringValue ?? rpcId.intValue.map(String.init) ?? UUID().uuidString
        self.rpcId = rpcId
        self.method = method
        let params = message["params"] ?? .object([:])
        threadId = params["threadId"]?.stringValue
            ?? params["thread"]?["id"]?.stringValue
            ?? params["conversationId"]?.stringValue
        turnId = params["turnId"]?.stringValue
            ?? params["turn"]?["id"]?.stringValue
        requestedPermissions = params["permissions"]

        if method.contains("commandExecution") {
            title = "Run this command?"
            summary = params["reason"]?.stringValue ?? "Codex is requesting permission to run a command."
            let command = params["command"]?.stringValue ?? ""
            let cwd = params["cwd"]?.stringValue ?? ""
            detail = [command, cwd].filter { !$0.isEmpty }.joined(separator: "\n\n")
        } else if method.contains("fileChange") {
            title = "Apply file changes?"
            summary = params["reason"]?.stringValue ?? "Codex is requesting permission to update files."
            detail = params["grantRoot"]?.stringValue ?? "Review the affected files in the conversation."
        } else if method.contains("permissions") {
            title = "Grant additional access?"
            summary = params["reason"]?.stringValue ?? "Codex needs permissions outside the current sandbox."
            detail = params["cwd"]?.stringValue ?? ""
        } else if method == "mcpServer/elicitation/request" {
            title = "Action needs approval"
            summary = params["message"]?.stringValue ?? "An MCP server is requesting your input."
            detail = params["url"]?.stringValue
                ?? params["requestedSchema"]?.stringValue
                ?? method
        } else {
            title = "Action needs approval"
            summary = params["reason"]?.stringValue ?? "Review this action before continuing."
            detail = method
        }
    }
}

func formatDuration(milliseconds: Int) -> String {
    let seconds = max(0, milliseconds / 1000)
    if seconds < 60 { return "\(seconds) 秒" }
    let minutes = seconds / 60
    let remainder = seconds % 60
    if minutes < 60 { return remainder == 0 ? "\(minutes) 分钟" : "\(minutes) 分 \(remainder) 秒" }
    let hours = minutes / 60
    let minuteRemainder = minutes % 60
    return "\(hours) 小时 \(minuteRemainder) 分"
}

extension Sequence where Element == TranscriptItem {
    func firstVisibleTaskActivityAt(turnId: String?) -> Date? {
        for item in self where item.turnId == turnId && item.isVisibleTaskActivity {
            if let createdAt = item.createdAt { return createdAt }
        }
        return nil
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
    var lastPathComponentForDisplay: String {
        let normalized = replacingOccurrences(of: "\\", with: "/")
        return normalized.split(separator: "/").last.map(String.init) ?? self
    }
    var normalizedWindowsPath: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "\\")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\\"))
            .lowercased()
    }
}
