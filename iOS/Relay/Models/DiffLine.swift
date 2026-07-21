import Foundation

enum DiffLineKind: Equatable {
    case context
    case added
    case removed
    case header
    case hunk
}

struct DiffLine: Identifiable, Equatable {
    let id: Int
    let text: String
    let kind: DiffLineKind

    static func parse(_ source: String) -> [DiffLine] {
        source.components(separatedBy: .newlines).enumerated().map { index, text in
            let kind: DiffLineKind
            if text.hasPrefix("+++") || text.hasPrefix("---") || text.hasPrefix("diff ") || text.hasPrefix("index ") {
                kind = .header
            } else if text.hasPrefix("@@") {
                kind = .hunk
            } else if text.hasPrefix("+") {
                kind = .added
            } else if text.hasPrefix("-") {
                kind = .removed
            } else {
                kind = .context
            }
            return DiffLine(id: index, text: text, kind: kind)
        }
    }
}
