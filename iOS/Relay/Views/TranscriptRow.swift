import SwiftUI

struct TranscriptRow: View {
    let item: TranscriptItem

    var body: some View {
        switch item.role {
        case .user:
            HStack {
                Spacer(minLength: 46)
                Text(item.text)
                    .font(.system(size: 16))
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(RelayTheme.softFill)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        case .assistant:
            VStack(alignment: .leading, spacing: 8) {
                if let title = item.title {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                MarkdownText(item.text)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .tool:
            ToolEventRow(item: item)
        case .system:
            Text(item.text)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct MarkdownText: View {
    let value: String

    init(_ value: String) { self.value = value }

    var body: some View {
        if let attributed = try? AttributedString(
            markdown: value,
            options: .init(interpretedSyntax: .full)
        ) {
            Text(attributed)
                .font(.system(size: 16))
                .lineSpacing(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(value)
                .font(.system(size: 16))
                .lineSpacing(4)
                .textSelection(.enabled)
        }
    }
}

private struct ToolEventRow: View {
    let item: TranscriptItem
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                guard item.detail?.isEmpty == false else { return }
                withAnimation(.easeOut(duration: 0.18)) { expanded.toggle() }
            } label: {
                HStack(spacing: 11) {
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title ?? title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)
                        if !item.text.isEmpty {
                            Text(item.text)
                                .font(.system(size: 12, design: item.kind == .command ? .monospaced : .default))
                                .foregroundStyle(.secondary)
                                .lineLimit(expanded ? 8 : 2)
                        }
                    }
                    Spacer()
                    if let status = item.status {
                        StatusGlyph(status: status)
                    }
                    if item.detail?.isEmpty == false {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .rotationEffect(.degrees(expanded ? 180 : 0))
                            .foregroundStyle(.tertiary)
                    }
                }
                .contentShape(Rectangle())
                .padding(.vertical, 9)
            }
            .buttonStyle(.plain)

            if expanded, let detail = item.detail, !detail.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(detail)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .padding(12)
                }
                .frame(maxHeight: 260)
                .background(Color.black.opacity(0.035))
                .clipShape(RoundedRectangle(cornerRadius: RelayTheme.controlRadius))
                .padding(.bottom, 8)
            }
        }
        .overlay(alignment: .bottom) { Divider().opacity(0.55) }
    }

    private var icon: String {
        switch item.kind {
        case .command: return "terminal"
        case .fileChange: return "doc.badge.gearshape"
        case .reasoning: return "sparkles"
        case .webSearch: return "globe"
        case .message, .other: return "wrench.and.screwdriver"
        }
    }

    private var title: String {
        switch item.kind {
        case .command: return "Terminal"
        case .fileChange: return "Files changed"
        case .reasoning: return "Reasoning"
        case .webSearch: return "Web search"
        case .message, .other: return "Tool"
        }
    }
}

private struct StatusGlyph: View {
    let status: String

    var body: some View {
        if status.lowercased().contains("progress") {
            ProgressView().controlSize(.mini)
        } else {
            Image(systemName: status.lowercased().contains("fail") ? "xmark.circle.fill" : "checkmark.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(status.lowercased().contains("fail") ? Color.red : RelayTheme.accent)
        }
    }
}

