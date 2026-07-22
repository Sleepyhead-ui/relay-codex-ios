import SwiftUI
import UIKit

struct MarkdownContentView: View {
    let source: String
    let baseFontSize: CGFloat
    let blockSpacing: CGFloat
    let lineSpacing: CGFloat
    @State private var document: IncrementalMarkdownDocument

    init(source: String, baseFontSize: CGFloat = 16, blockSpacing: CGFloat = 13, lineSpacing: CGFloat = 4) {
        self.source = source
        self.baseFontSize = baseFontSize
        self.blockSpacing = blockSpacing
        self.lineSpacing = lineSpacing
        _document = State(initialValue: IncrementalMarkdownDocument(source: source))
    }

    private var blocks: [MarkdownBlock] { document.blocks(for: source) }

    private var numberedBlocks: [(block: MarkdownBlock, orderedStart: Int?)] {
        var nextOrderedNumber = 1
        var sequenceActive = false
        return blocks.map { block in
            switch block {
            case .orderedList(let values):
                let start = sequenceActive ? nextOrderedNumber : 1
                nextOrderedNumber = start + values.count
                sequenceActive = true
                return (block, start)
            case .paragraph(_):
                // Markdown renderers commonly split a numbered list around
                // continuation paragraphs. Keep numbering through those
                // paragraphs instead of restarting at 1.
                return (block, nil)
            default:
                sequenceActive = false
                nextOrderedNumber = 1
                return (block, nil)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: blockSpacing) {
            ForEach(Array(numberedBlocks.enumerated()), id: \.offset) { _, entry in
                blockView(entry.block, orderedStart: entry.orderedStart)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock, orderedStart: Int? = nil) -> some View {
        switch block {
        case .paragraph(let text):
            InlineMarkdownText(text, size: baseFontSize, lineSpacing: lineSpacing)
        case .heading(let level, let text):
            InlineMarkdownText(text, size: headingSize(level), weight: level <= 2 ? .bold : .semibold, lineSpacing: lineSpacing)
                .padding(.top, level == 1 ? 5 : 2)
        case .code(let language, let code):
            CodeBlockView(language: language, code: code)
        case .unorderedList(let values):
            VStack(alignment: .leading, spacing: max(4, blockSpacing * 0.6)) {
                ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Circle()
                            .fill(Color.secondary)
                            .frame(width: 5, height: 5)
                            .offset(y: -2)
                        InlineMarkdownText(value, size: baseFontSize, lineSpacing: lineSpacing)
                    }
                }
            }
        case .orderedList(let values):
            VStack(alignment: .leading, spacing: max(4, blockSpacing * 0.6)) {
                ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\((orderedStart ?? 1) + index).")
                            .font(.system(size: max(10, baseFontSize - 1), weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 20, alignment: .trailing)
                        InlineMarkdownText(value, size: baseFontSize, lineSpacing: lineSpacing)
                    }
                }
            }
        case .quote(let text):
            HStack(alignment: .top, spacing: 12) {
                Capsule()
                    .fill(Color.secondary.opacity(0.35))
                    .frame(width: 3)
                InlineMarkdownText(text, size: max(10, baseFontSize - 1), lineSpacing: lineSpacing)
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .rule:
            Divider().padding(.vertical, 4)
        case .table(let headers, let rows):
            MarkdownTable(headers: headers, rows: rows)
        }
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return baseFontSize + 7
        case 2: return baseFontSize + 4
        case 3: return baseFontSize + 2
        default: return baseFontSize
        }
    }
}

private struct InlineMarkdownText: View {
    let text: String
    let size: CGFloat
    let weight: Font.Weight
    let lineSpacing: CGFloat

    init(_ text: String, size: CGFloat, weight: Font.Weight = .regular, lineSpacing: CGFloat = 4) {
        self.text = text
        self.size = size
        self.weight = weight
        self.lineSpacing = lineSpacing
    }

    var body: some View {
        if let attributed = styledMarkdown {
            Text(attributed)
                .font(.system(size: size, weight: weight))
                .lineSpacing(lineSpacing)
                .tint(RelayTheme.accent)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(text)
                .font(.system(size: size, weight: weight))
                .lineSpacing(lineSpacing)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var styledMarkdown: AttributedString? {
        guard var attributed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .full)
        ) else { return nil }

        for run in attributed.runs {
            guard run.inlinePresentationIntent?.contains(.code) == true else { continue }
            attributed[run.range].font = .system(size: max(11, size - 1), design: .monospaced)
            attributed[run.range].backgroundColor = RelayTheme.codeFill
            attributed[run.range].foregroundColor = .primary
        }
        return attributed
    }
}

private struct CodeBlockView: View {
    let language: String
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(language.isEmpty ? "code" : language.lowercased())
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    UIPasteboard.general.string = code
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
                } label: {
                    Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .frame(height: 34)

            Divider().opacity(0.45)

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 13, design: .monospaced))
                    .lineSpacing(3)
                    .padding(12)
            }
        }
        .background(RelayTheme.codeFill)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(RelayTheme.hairline, lineWidth: 1)
        }
    }
}

private struct MarkdownTable: View {
    let headers: [String]
    let rows: [[String]]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                tableRow(headers, isHeader: true)
                Divider()
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    tableRow(row, isHeader: false)
                    Divider().opacity(0.55)
                }
            }
            .background(RelayTheme.elevated)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(RelayTheme.hairline, lineWidth: 1)
            }
        }
    }

    private func tableRow(_ values: [String], isHeader: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                InlineMarkdownText(value, size: 13, weight: isHeader ? .semibold : .regular)
                    .frame(width: 170, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
            }
        }
        .background(isHeader ? RelayTheme.softFill : Color.clear)
    }
}

enum MarkdownBlock: Equatable {
    case paragraph(String)
    case heading(Int, String)
    case code(String, String)
    case unorderedList([String])
    case orderedList([String])
    case quote(String)
    case rule
    case table([String], [[String]])
}

enum MarkdownParser {
    static func parse(_ source: String) -> [MarkdownBlock] {
        let key = source as NSString
        if let cached = cache.object(forKey: key) { return cached.blocks }
        let blocks = parseUncached(source)
        cache.setObject(MarkdownBlocksBox(blocks), forKey: key, cost: source.utf8.count)
        return blocks
    }

    private static let cache: NSCache<NSString, MarkdownBlocksBox> = {
        let cache = NSCache<NSString, MarkdownBlocksBox>()
        cache.countLimit = 128
        cache.totalCostLimit = 2 * 1024 * 1024
        return cache
    }()

    static func parseUncached(_ source: String) -> [MarkdownBlock] {
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var index = 0

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { index += 1; continue }

            if trimmed.hasPrefix("```") {
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                index += 1
                var codeLines: [String] = []
                while index < lines.count && !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    codeLines.append(lines[index])
                    index += 1
                }
                if index < lines.count { index += 1 }
                blocks.append(.code(language, codeLines.joined(separator: "\n")))
                continue
            }

            if let heading = heading(line) {
                blocks.append(.heading(heading.level, heading.text))
                index += 1
                continue
            }

            if ["---", "***", "___"].contains(trimmed) {
                blocks.append(.rule)
                index += 1
                continue
            }

            if isTableHeader(lines: lines, index: index) {
                let headers = cells(lines[index])
                index += 2
                var rows: [[String]] = []
                while index < lines.count, lines[index].contains("|"), !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                    rows.append(cells(lines[index]))
                    index += 1
                }
                blocks.append(.table(headers, rows))
                continue
            }

            if unorderedValue(trimmed) != nil {
                var values: [String] = []
                while index < lines.count, let value = unorderedValue(lines[index].trimmingCharacters(in: .whitespaces)) {
                    values.append(value)
                    index += 1
                }
                blocks.append(.unorderedList(values))
                continue
            }

            if orderedValue(trimmed) != nil {
                var values: [String] = []
                while index < lines.count, let value = orderedValue(lines[index].trimmingCharacters(in: .whitespaces)) {
                    values.append(value)
                    index += 1
                }
                blocks.append(.orderedList(values))
                continue
            }

            if trimmed.hasPrefix(">") {
                var quoteLines: [String] = []
                while index < lines.count {
                    let value = lines[index].trimmingCharacters(in: .whitespaces)
                    guard value.hasPrefix(">") else { break }
                    quoteLines.append(String(value.dropFirst()).trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                blocks.append(.quote(quoteLines.joined(separator: "\n")))
                continue
            }

            var paragraph: [String] = [trimmed]
            index += 1
            while index < lines.count {
                let next = lines[index].trimmingCharacters(in: .whitespaces)
                if next.isEmpty || next.hasPrefix("```") || heading(lines[index]) != nil || unorderedValue(next) != nil || orderedValue(next) != nil || next.hasPrefix(">") || isTableHeader(lines: lines, index: index) { break }
                paragraph.append(next)
                index += 1
            }
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
        }

        return blocks.isEmpty && !source.isEmpty ? [.paragraph(source)] : blocks
    }

    private static func heading(_ line: String) -> (level: Int, text: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let count = trimmed.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(count), trimmed.dropFirst(count).first == " " else { return nil }
        return (count, String(trimmed.dropFirst(count + 1)))
    }

    private static func unorderedValue(_ line: String) -> String? {
        for prefix in ["- ", "* ", "+ "] where line.hasPrefix(prefix) {
            return String(line.dropFirst(prefix.count))
        }
        return nil
    }

    private static func orderedValue(_ line: String) -> String? {
        guard let dot = line.firstIndex(of: ".") else { return nil }
        let number = line[..<dot]
        guard !number.isEmpty, number.allSatisfy(\.isNumber) else { return nil }
        let after = line.index(after: dot)
        guard after < line.endIndex, line[after] == " " else { return nil }
        return String(line[line.index(after: after)...])
    }

    private static func isTableHeader(lines: [String], index: Int) -> Bool {
        guard index + 1 < lines.count, lines[index].contains("|") else { return false }
        let separator = cells(lines[index + 1])
        return !separator.isEmpty && separator.allSatisfy { cell in
            let stripped = cell.replacingOccurrences(of: ":", with: "").trimmingCharacters(in: .whitespaces)
            return stripped.count >= 3 && stripped.allSatisfy { $0 == "-" }
        }
    }

    private static func cells(_ line: String) -> [String] {
        var value = line.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("|") { value.removeFirst() }
        if value.hasSuffix("|") { value.removeLast() }
        return value.split(separator: "|", omittingEmptySubsequences: false).map {
            String($0).trimmingCharacters(in: .whitespaces)
        }
    }
}

final class IncrementalMarkdownDocument {
    private(set) var source = ""
    private(set) var stablePrefix = ""
    private(set) var stableBlocks: [MarkdownBlock] = []
    private(set) var blocks: [MarkdownBlock] = []

    init(source: String) {
        update(source: source)
    }

    @discardableResult
    func update(source newSource: String) -> [MarkdownBlock] {
        let normalized = newSource.replacingOccurrences(of: "\r\n", with: "\n")
        guard normalized.hasPrefix(source) else {
            reset(source: normalized)
            return blocks
        }

        let normalizedUTF16 = normalized as NSString
        let stableLength = (stablePrefix as NSString).length
        let unstable = normalizedUTF16.substring(from: min(stableLength, normalizedUTF16.length))
        let promoted = Self.safeStablePrefix(in: unstable)
        if !promoted.isEmpty {
            stablePrefix += promoted
            stableBlocks.append(contentsOf: MarkdownParser.parseUncached(promoted))
        }
        let tail = (unstable as NSString).substring(from: (promoted as NSString).length)
        blocks = stableBlocks + MarkdownParser.parseUncached(tail)
        source = normalized
        return blocks
    }

    func blocks(for source: String) -> [MarkdownBlock] {
        update(source: source)
    }

    private func reset(source: String) {
        self.source = ""
        stablePrefix = ""
        stableBlocks = []
        blocks = []
        update(source: source)
    }

    static func safeStablePrefix(in source: String) -> String {
        var lineStart = source.startIndex
        var stableEnd = source.startIndex
        var insideCodeFence = false

        while lineStart < source.endIndex {
            let newline = source[lineStart...].firstIndex(of: "\n")
            let lineEnd = newline ?? source.endIndex
            let line = source[lineStart..<lineEnd].trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") { insideCodeFence.toggle() }
            if line.isEmpty, !insideCodeFence, let newline {
                stableEnd = source.index(after: newline)
            }
            guard let newline else { break }
            lineStart = source.index(after: newline)
        }
        return String(source[..<stableEnd])
    }
}

private final class MarkdownBlocksBox: NSObject {
    let blocks: [MarkdownBlock]
    init(_ blocks: [MarkdownBlock]) { self.blocks = blocks }
}
