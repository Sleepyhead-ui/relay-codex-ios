import Foundation

struct HostConfiguration: Codable, Equatable {
    var name = "Windows PC"
    var endpoint = "ws://127.0.0.1:8765"
    var workingDirectory = ""
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
    var title: String { self == .steer ? "引导" : "排队" }
    var detail: String {
        self == .steer ? "立即补充到当前任务" : "当前任务结束后自动发送"
    }
}

struct QueuedFollowUp: Identifiable, Equatable {
    let id: UUID
    let threadId: String
    let text: String
    let attachments: [PendingAttachment]
    let createdAt: Date

    var displayText: String {
        if let text = text.nonEmpty { return text }
        return attachments.map(\.name).joined(separator: "、")
    }
}

struct SharedFile: Identifiable {
    let id = UUID()
    let url: URL
}

struct ExecutionPlanStep: Identifiable, Equatable {
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
        return normalized == "active" || normalized == "running" || normalized == "inprogress"
    }

    init?(json: JSONValue) {
        guard let id = json["id"]?.stringValue else { return nil }
        self.id = id
        preview = json["preview"]?.stringValue ?? ""
        title = json["name"]?.stringValue?.nonEmpty ?? preview.nonEmpty ?? "New task"
        cwd = json["cwd"]?.stringValue ?? ""
        updatedAt = Date(timeIntervalSince1970: json["updatedAt"]?.doubleValue ?? 0)
        status = json["status"]?["type"]?.stringValue ?? "idle"
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
        return normalized == "inprogress" || normalized == "active" || normalized == "running"
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

struct TranscriptItem: Identifiable, Equatable {
    let id: String
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
        deliveryState: MessageDeliveryState? = nil
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
    }

    var isCommentary: Bool { role == .assistant && phase == "commentary" }
    var isFinalAnswer: Bool { role == .assistant && phase != "commentary" }
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
        switch type {
        case "userMessage":
            let text = json["content"]?.arrayValue?
                .compactMap { content -> String? in
                    if let text = content["text"]?.stringValue { return cleanDesktopUserText(text) }
                    if content["type"]?.stringValue == "mention" {
                        return "📎 \(content["name"]?.stringValue ?? content["path"]?.stringValue?.lastPathComponentForDisplay ?? "文件")"
                    }
                    if content["type"]?.stringValue == "localImage" {
                        return "📎 \(content["path"]?.stringValue?.lastPathComponentForDisplay ?? "图片")"
                    }
                    return nil
                }
                .joined(separator: "\n") ?? ""
            return TranscriptItem(id: id, turnId: turnId, role: .user, kind: .message, text: text)
        case "agentMessage":
            return TranscriptItem(
                id: id,
                turnId: turnId,
                role: .assistant,
                kind: .message,
                text: json["text"]?.stringValue ?? "",
                phase: json["phase"]?.stringValue
            )
        case "reasoning":
            let summary = json["summary"]?.arrayValue?.compactMap { $0.stringValue }.joined(separator: "\n\n") ?? ""
            let content = json["content"]?.arrayValue?.compactMap { $0.stringValue }.joined(separator: "\n\n") ?? ""
            return TranscriptItem(id: id, turnId: turnId, role: .tool, kind: .reasoning, title: "思考", text: summary, detail: content)
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
                errorMessage: (exitCode ?? 0) != 0 ? commandFailureSummary(output) : nil
            )
        case "fileChange":
            let changes = json["changes"]?.arrayValue ?? []
            let paths = changes.compactMap { $0["path"]?.stringValue }.joined(separator: "\n")
            let diffs = changes.compactMap { $0["diff"]?.stringValue }.joined(separator: "\n\n")
            return TranscriptItem(id: id, turnId: turnId, role: .tool, kind: .fileChange, title: "修改文件", text: paths, detail: diffs, status: json["status"]?.stringValue)
        case "webSearch":
            return TranscriptItem(id: id, turnId: turnId, role: .tool, kind: .webSearch, title: "搜索网页", text: json["query"]?.stringValue ?? "")
        case "mcpToolCall":
            let name = json["tool"]?.stringValue ?? "MCP tool"
            let server = json["server"]?.stringValue ?? ""
            let result = prettyJSON(json["result"]) ?? prettyJSON(json["error"]) ?? prettyJSON(json["arguments"])
            return TranscriptItem(id: id, turnId: turnId, role: .tool, kind: .other, title: friendlyToolTitle(name: name, namespace: server), text: friendlyToolSummary(name: name, namespace: server), detail: result, status: json["status"]?.stringValue, durationMs: json["durationMs"]?.intValue, errorMessage: readableError(json))
        case "dynamicToolCall":
            let name = json["tool"]?.stringValue ?? "Tool"
            let namespace = json["namespace"]?.stringValue ?? ""
            let detail = prettyJSON(json["contentItems"]) ?? prettyJSON(json["result"]) ?? prettyJSON(json["arguments"])
            return TranscriptItem(id: id, turnId: turnId, role: .tool, kind: .other, title: friendlyToolTitle(name: name, namespace: namespace), text: friendlyToolSummary(name: name, namespace: namespace), detail: detail, status: json["status"]?.stringValue, durationMs: json["durationMs"]?.intValue, errorMessage: readableError(json))
        case "collabAgentToolCall":
            let tool = json["tool"]?.stringValue ?? "Agent"
            let prompt = json["prompt"]?.stringValue ?? ""
            return TranscriptItem(id: id, turnId: turnId, role: .tool, kind: .subagent, title: "协作代理 · \(tool)", text: prompt, detail: prettyJSON(json["agentsStates"]), status: json["status"]?.stringValue)
        case "subAgentActivity":
            return TranscriptItem(id: id, turnId: turnId, role: .tool, kind: .subagent, title: "子代理", text: json["agentPath"]?.stringValue ?? "", detail: json["kind"]?.stringValue)
        case "plan":
            return TranscriptItem(id: id, turnId: turnId, role: .tool, kind: .plan, title: "计划", text: json["text"]?.stringValue ?? "")
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

    private static func cleanDesktopUserText(_ text: String) -> String {
        let pattern = #"(?im)^\s*#{0,6}\s*My request for Codex:\s*$"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let markerRange = Range(match.range, in: text) else { return text }
        return String(text[markerRange.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
    var items: [TranscriptItem]
    var metadata: TurnMetadata

    var userItems: [TranscriptItem] { items.filter { $0.role == .user } }
    var activityItems: [TranscriptItem] { items.filter(\.isActivity) }
    var answerItems: [TranscriptItem] { items.filter(\.isFinalAnswer) }
}

struct ApprovalRequest: Identifiable, Equatable {
    let rpcId: JSONValue
    let method: String
    let requestedPermissions: JSONValue?
    let title: String
    let summary: String
    let detail: String

    var id: String { rpcId.stringValue ?? UUID().uuidString }

    init?(message: JSONValue) {
        guard let rpcId = message["id"], let method = message["method"]?.stringValue else { return nil }
        self.rpcId = rpcId
        self.method = method
        let params = message["params"] ?? .object([:])
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
