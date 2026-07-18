import Foundation

struct HostConfiguration: Codable, Equatable {
    var name = "Windows PC"
    var endpoint = "ws://127.0.0.1:8765"
    var workingDirectory = ""
}

struct ThreadSummary: Identifiable, Equatable {
    let id: String
    var title: String
    var preview: String
    var cwd: String
    var updatedAt: Date
    var status: String

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

enum TranscriptRole: Equatable {
    case user
    case assistant
    case tool
    case system
}

enum TranscriptKind: Equatable {
    case message
    case command
    case fileChange
    case reasoning
    case webSearch
    case other
}

struct TranscriptItem: Identifiable, Equatable {
    let id: String
    var role: TranscriptRole
    var kind: TranscriptKind
    var title: String?
    var text: String
    var detail: String?
    var status: String?

    static func from(json: JSONValue) -> TranscriptItem? {
        guard let id = json["id"]?.stringValue, let type = json["type"]?.stringValue else { return nil }
        switch type {
        case "userMessage":
            let text = json["content"]?.arrayValue?
                .compactMap { $0["text"]?.stringValue }
                .joined(separator: "\n") ?? ""
            return TranscriptItem(id: id, role: .user, kind: .message, text: text)
        case "agentMessage":
            return TranscriptItem(id: id, role: .assistant, kind: .message, text: json["text"]?.stringValue ?? "")
        case "reasoning":
            let summary = json["summary"]?.arrayValue?.compactMap { $0.stringValue }.joined(separator: "\n") ?? ""
            return TranscriptItem(id: id, role: .tool, kind: .reasoning, title: "Reasoning", text: summary)
        case "commandExecution":
            return TranscriptItem(
                id: id,
                role: .tool,
                kind: .command,
                title: "Terminal",
                text: json["command"]?.stringValue ?? "Command",
                detail: json["aggregatedOutput"]?.stringValue,
                status: json["status"]?.stringValue
            )
        case "fileChange":
            let changes = json["changes"]?.arrayValue ?? []
            let paths = changes.compactMap { $0["path"]?.stringValue }.joined(separator: "\n")
            let diffs = changes.compactMap { $0["diff"]?.stringValue }.joined(separator: "\n")
            return TranscriptItem(id: id, role: .tool, kind: .fileChange, title: "Files changed", text: paths, detail: diffs, status: json["status"]?.stringValue)
        case "webSearch":
            return TranscriptItem(id: id, role: .tool, kind: .webSearch, title: "Web search", text: json["query"]?.stringValue ?? "")
        case "mcpToolCall", "dynamicToolCall", "collabAgentToolCall":
            let name = json["tool"]?.stringValue ?? json["name"]?.stringValue ?? "Tool"
            return TranscriptItem(id: id, role: .tool, kind: .other, title: name, text: json["server"]?.stringValue ?? "", status: json["status"]?.stringValue)
        case "plan":
            return TranscriptItem(id: id, role: .assistant, kind: .message, title: "Plan", text: json["text"]?.stringValue ?? "")
        default:
            return nil
        }
    }
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

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
    var lastPathComponentForDisplay: String {
        let normalized = replacingOccurrences(of: "\\", with: "/")
        return normalized.split(separator: "/").last.map(String.init) ?? self
    }
}
