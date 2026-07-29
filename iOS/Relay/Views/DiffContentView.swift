import SwiftUI

struct DiffContentView: View {
    private let lines: [DiffLine]
    private let lineHeight: CGFloat = 19
    private var height: CGFloat { CGFloat(min(max(lines.count, 2), 18)) * lineHeight + 16 }

    init(source: String) {
        lines = DiffLine.parse(source)
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView([.horizontal, .vertical], showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(lines) { line in
                        HStack(spacing: 0) {
                            Text(gutter(for: line.kind))
                                .foregroundStyle(foreground(for: line.kind).opacity(0.8))
                                .frame(width: 24, alignment: .center)
                            Text(content(for: line))
                                .foregroundStyle(foreground(for: line.kind))
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .padding(.trailing, 14)
                        }
                        .font(.system(size: 12, design: .monospaced))
                        .frame(minWidth: max(geometry.size.width, 1), minHeight: lineHeight, alignment: .leading)
                        .background(background(for: line.kind))
                    }
                }
                .frame(minWidth: max(geometry.size.width, 1), alignment: .leading)
            }
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .background(RelayTheme.codeFill)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(RelayTheme.hairline, lineWidth: 1)
        }
    }

    private func gutter(for kind: DiffLineKind) -> String {
        switch kind { case .added: return "+"; case .removed: return "-"; default: return "" }
    }

    private func content(for line: DiffLine) -> String {
        let text = line.kind == .added || line.kind == .removed ? String(line.text.dropFirst()) : line.text
        return text.isEmpty ? " " : text
    }

    private func foreground(for kind: DiffLineKind) -> Color {
        switch kind { case .added: return .green; case .removed: return .red; case .hunk: return .blue; case .header: return .secondary; case .context: return .primary.opacity(0.78) }
    }

    private func background(for kind: DiffLineKind) -> Color {
        switch kind { case .added: return .green.opacity(0.09); case .removed: return .red.opacity(0.09); case .hunk: return .blue.opacity(0.07); default: return .clear }
    }
}
