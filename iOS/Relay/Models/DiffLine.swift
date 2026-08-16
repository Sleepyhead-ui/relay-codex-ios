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

struct DiffFileStatistics: Identifiable, Codable, Equatable {
    var id: String { path }
    let path: String
    var added: Int
    var removed: Int
}

struct DiffStatistics: Codable, Equatable {
    let added: Int
    let removed: Int
    let files: [DiffFileStatistics]

    static func parse(_ source: String) -> DiffStatistics {
        var added = 0
        var removed = 0
        var oldPath: String?
        var currentPath: String?
        var fileOrder: [String] = []
        var fileCounts: [String: (added: Int, removed: Int)] = [:]

        func registerFile(_ path: String?) {
            guard let path, !path.isEmpty, fileCounts[path] == nil else { return }
            fileOrder.append(path)
            fileCounts[path] = (0, 0)
        }

        for line in source.components(separatedBy: .newlines) {
            if line.hasPrefix("diff --git ") {
                let paths = gitHeaderPaths(String(line.dropFirst("diff --git ".count)))
                oldPath = paths.old
                currentPath = paths.new ?? paths.old
                registerFile(currentPath)
                continue
            }
            if line.hasPrefix("--- ") {
                oldPath = normalizedPath(String(line.dropFirst(4)))
                continue
            }
            if line.hasPrefix("+++ ") {
                let newPath = normalizedPath(String(line.dropFirst(4)))
                currentPath = newPath ?? oldPath
                registerFile(currentPath)
                continue
            }
            if line.hasPrefix("diff ") || line.hasPrefix("index ") || line.hasPrefix("@@") {
                continue
            }

            if line.hasPrefix("+") {
                added += 1
                if let currentPath {
                    var count = fileCounts[currentPath] ?? (0, 0)
                    count.added += 1
                    fileCounts[currentPath] = count
                }
            } else if line.hasPrefix("-") {
                removed += 1
                if let currentPath {
                    var count = fileCounts[currentPath] ?? (0, 0)
                    count.removed += 1
                    fileCounts[currentPath] = count
                }
            }
        }

        return DiffStatistics(
            added: added,
            removed: removed,
            files: fileOrder.compactMap { path in
                guard let count = fileCounts[path] else { return nil }
                return DiffFileStatistics(path: path, added: count.added, removed: count.removed)
            }
        )
    }

    static func from(json: JSONValue) -> DiffStatistics? {
        guard let added = json["added"]?.intValue,
              let removed = json["removed"]?.intValue else { return nil }
        let files = json["files"]?.arrayValue?.compactMap { file -> DiffFileStatistics? in
            guard let path = file["path"]?.stringValue,
                  let fileAdded = file["added"]?.intValue,
                  let fileRemoved = file["removed"]?.intValue else { return nil }
            return DiffFileStatistics(path: path, added: fileAdded, removed: fileRemoved)
        } ?? []
        return DiffStatistics(added: added, removed: removed, files: files)
    }

    private static func normalizedPath(_ source: String) -> String? {
        let path = source
            .split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !path.isEmpty, path != "/dev/null" else { return nil }
        if path.hasPrefix("a/") || path.hasPrefix("b/") {
            return String(path.dropFirst(2))
        }
        return path
    }

    private static func gitHeaderPaths(_ source: String) -> (old: String?, new: String?) {
        guard let separator = source.range(of: " b/", options: .backwards) else {
            return (normalizedPath(source), nil)
        }
        let old = normalizedPath(String(source[..<separator.lowerBound]))
        let new = normalizedPath(String(source[separator.lowerBound...]).trimmingCharacters(in: .whitespaces))
        return (old, new)
    }
}
