import SwiftUI
import UIKit

struct MarkdownContentView: View {
    let source: String

    private var blocks: [MarkdownBlock] { MarkdownParser.parse(source) }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let text):
            InlineMarkdownText(text, size: 16)
        case .heading(let level, let text):
            InlineMarkdownText(text, size: headingSize(level), weight: level <= 2 ? .bold : .semibold)
                .padding(.top, level == 1 ? 5 : 2)
        case .code(let language, let code):
            CodeBlockView(language: language, code: code)
        case .unorderedList(let values):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Circle()
                            .fill(Color.secondary)
                            .frame(width: 5, height: 5)
                            .offset(y: -2)
                        InlineMarkdownText(value, size: 16)
                    }
                }
            }
        case .orderedList(let values):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\(index + 1).")
                            .font(.system(size: 15, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 20, alignment: .trailing)
                        InlineMarkdownText(value, size: 16)
                    }
                }
            }
        case .quote(let text):
            HStack(alignment: .top, spacing: 12) {
                Capsule()
                    .fill(Color.secondary.opacity(0.35))
                    .frame(width: 3)
                InlineMarkdownText(text, size: 15)
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
        case 1: return 23
        case 2: return 20
        case 3: return 18
        default: return 16
        }
    }
}

private struct InlineMarkdownText: View {
    let text: String
    let size: CGFloat
    let weight: Font.Weight

    init(_ text: String, size: CGFloat, weight: Font.Weight = .regular) {
        self.text = text
        self.size = size
        self.weight = weight
    }

    var body: some View {
        if let attributed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .full)
        ) {
            Text(attributed)
                .font(.system(size: size, weight: weight))
                .lineSpacing(4)
                .tint(RelayTheme.accent)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(text)
                .font(.system(size: size, weight: weight))
                .lineSpacing(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
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
                    .textSelection(.enabled)
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

private enum MarkdownBlock {
    case paragraph(String)
    case heading(Int, String)
    case code(String, String)
    case unorderedList([String])
    case orderedList([String])
    case quote(String)
    case rule
    case table([String], [[String]])
}

private enum MarkdownParser {
    static func parse(_ source: String) -> [MarkdownBlock] {
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
