import Foundation

enum ThreadBranchNaming {
    static func nextTitle(sourceTitle: String, existingTitles: [String]) -> String {
        let source = sourceTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return "New task (2)" }

        let normalizedExisting = existingTitles.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let base = branchBase(for: source, existingTitles: normalizedExisting)
        let highestIndex = normalizedExisting.reduce(1) { highest, title in
            max(highest, branchIndex(for: title, base: base) ?? 0)
        }
        return "\(base) (\(max(2, highestIndex + 1)))"
    }

    private static func branchBase(for source: String, existingTitles: [String]) -> String {
        guard let parsed = numberedSuffix(in: source) else { return source }
        let hasFamilyMember = existingTitles.contains(parsed.base)
            || existingTitles.contains { title in
                title != source && numberedSuffix(in: title)?.base == parsed.base
            }
        return hasFamilyMember ? parsed.base : source
    }

    private static func branchIndex(for title: String, base: String) -> Int? {
        if title == base { return 1 }
        guard let parsed = numberedSuffix(in: title), parsed.base == base else { return nil }
        return parsed.index
    }

    private static func numberedSuffix(in title: String) -> (base: String, index: Int)? {
        guard title.hasSuffix(")"),
              let opening = title.lastIndex(of: "("),
              opening > title.startIndex,
              title[title.index(before: opening)] == " " else { return nil }
        let numberStart = title.index(after: opening)
        let numberEnd = title.index(before: title.endIndex)
        guard let index = Int(title[numberStart..<numberEnd]), index >= 2 else { return nil }
        let base = String(title[..<title.index(before: opening)])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return base.isEmpty ? nil : (base, index)
    }
}
