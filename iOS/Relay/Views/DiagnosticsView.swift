import SwiftUI

struct DiagnosticsView: View {
    @EnvironmentObject private var store: RelayStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let report = store.diagnosticsReport {
                    Section {
                        ForEach(report.checks) { check in
                            HStack(alignment: .top, spacing: 11) {
                                Image(systemName: icon(for: check.level))
                                    .foregroundStyle(color(for: check.level))
                                    .frame(width: 18)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(check.title).font(.system(size: 14, weight: .semibold))
                                    Text(check.detail).font(.system(size: 12)).foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 3)
                        }
                    } header: {
                        Text("系统检查")
                    } footer: {
                        Text("更新于 \(report.generatedAt.formatted(date: .omitted, time: .standard))")
                    }

                    Section("最近事件") {
                        if report.events.isEmpty {
                            Text("暂无异常事件").foregroundStyle(.secondary)
                        } else {
                            ForEach(report.events.prefix(30)) { event in
                                HStack(alignment: .top, spacing: 10) {
                                    Circle().fill(color(for: event.level)).frame(width: 6, height: 6).padding(.top, 6)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(event.message).font(.system(size: 12, weight: .medium))
                                        Text("\(event.category) · \(event.date.formatted(date: .omitted, time: .standard))")
                                            .font(.system(size: 10)).foregroundStyle(.tertiary)
                                    }
                                }
                            }
                        }
                    }
                } else {
                    HStack { ProgressView(); Text("正在读取诊断信息").foregroundStyle(.secondary) }
                }
            }
            .scrollContentBackground(.hidden)
            .background(RelayTheme.canvas)
            .navigationTitle("诊断中心")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { store.exportDiagnostics() } label: { Image(systemName: "square.and.arrow.up") }
                        .disabled(store.diagnosticsReport == nil)
                }
                ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } }
            }
            .refreshable { await store.refreshDiagnostics() }
            .task { await store.refreshDiagnostics() }
        }
    }

    private func color(for level: String) -> Color {
        switch level { case "ok", "info": return RelayTheme.accent; case "error": return .red; default: return .orange }
    }

    private func icon(for level: String) -> String {
        switch level { case "ok": return "checkmark.circle.fill"; case "error": return "xmark.octagon.fill"; default: return "exclamationmark.triangle.fill" }
    }
}
