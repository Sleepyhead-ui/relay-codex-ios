import SwiftUI

struct DiffContentView: View {
    let source: String

    private var lines: [DiffLine] { DiffLine.parse(source) }
    private var height: CGFloat { CGFloat(min(max(lines.count, 2), 18)) * 18 + 16 }

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(lines) { line in
                    HStack(spacing: 0) {
                        Text(gutter(for: line.kind))
                            .foregroundStyle(foreground(for: line.kind).opacity(0.8))
                            .frame(width: 20, alignment: .center)
                        Text(content(for: line))
                            .foregroundStyle(foreground(for: line.kind))
                            .padding(.trailing, 12)
                    }
                    .font(.system(size: 11, design: .monospaced))
                    .frame(minHeight: 18)
                    .background(background(for: line.kind))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: height)
        .background(Color.black.opacity(0.16))
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
