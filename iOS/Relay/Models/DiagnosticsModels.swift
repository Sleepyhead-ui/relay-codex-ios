import Foundation

struct DiagnosticCheck: Identifiable, Equatable {
    let id: String
    let level: String
    let title: String
    let detail: String

    init?(json: JSONValue) {
        guard let id = json["id"]?.stringValue,
              let title = json["title"]?.stringValue else { return nil }
        self.id = id
        level = json["level"]?.stringValue ?? "warning"
        self.title = title
        detail = json["detail"]?.stringValue ?? ""
    }
}

struct DiagnosticEvent: Identifiable, Equatable {
    let id: String
    let date: Date
    let level: String
    let category: String
    let message: String

    init?(json: JSONValue) {
        guard let id = json["id"]?.stringValue,
              let message = json["message"]?.stringValue else { return nil }
        self.id = id
        level = json["level"]?.stringValue ?? "info"
        category = json["category"]?.stringValue ?? "relay"
        self.message = message
        date = ISO8601DateFormatter().date(from: json["at"]?.stringValue ?? "") ?? Date()
    }
}

struct DiagnosticsReport {
    let generatedAt: Date
    let summary: String
    let checks: [DiagnosticCheck]
    let events: [DiagnosticEvent]
    let raw: JSONValue

    init(json: JSONValue) {
        generatedAt = ISO8601DateFormatter().date(from: json["generatedAt"]?.stringValue ?? "") ?? Date()
        summary = json["summary"]?.stringValue ?? "warning"
        checks = (json["checks"]?.arrayValue ?? []).compactMap(DiagnosticCheck.init(json:))
        events = (json["events"]?.arrayValue ?? []).compactMap(DiagnosticEvent.init(json:))
        raw = json
    }
}
