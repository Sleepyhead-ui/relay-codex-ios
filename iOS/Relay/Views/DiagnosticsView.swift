import SwiftUI

struct DiagnosticsView: View {
    @EnvironmentObject private var store: RelayStore
    @Environment(\.dismiss) private var dismiss
    @State private var diagnosticsExport: SharedFile?
    @State private var exportURLToRemove: URL?
    @State private var isExporting = false

    var body: some View {
        NavigationStack {
            List {
                if let report = store.diagnosticsReport {
                    Section("构建信息") {
                        LabeledContent("Relay", value: AppBuildIdentity().displayText)
                            .font(.system(size: 12, design: .monospaced))
                    }

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

                    Section("性能") {
                        metricRow(
                            title: "消息解码",
                            value: "P95 \(formatMilliseconds(report.clientPerformance.decodeLatency.p95Ms))",
                            detail: "\(report.clientPerformance.inboundMessages) 条 · \(formatBytes(report.clientPerformance.inboundBytes))"
                        )
                        metricRow(
                            title: "会话增量同步",
                            value: "\(report.clientPerformance.patches) 补丁 / \(report.clientPerformance.snapshots) 快照",
                            detail: "应用 P95 \(formatMilliseconds(report.clientPerformance.patchApplyLatency.p95Ms)) · \(report.clientPerformance.revisionGaps) 次修订缺口"
                        )
                        metricRow(
                            title: "流式内容刷新",
                            value: "P95 \(formatMilliseconds(report.clientPerformance.deltaFlushLatency.p95Ms))",
                            detail: "\(report.clientPerformance.deltaFlushes) 批 · 单批最多 \(report.clientPerformance.maxItemsPerFlush) 项"
                        )
                        metricRow(
                            title: "Bridge RPC",
                            value: "P95 \(formatMilliseconds(report.bridgePerformance.rpcLatency.p95Ms))",
                            detail: "补丁/快照流量比 \(formatRatio(report.bridgePerformance.patchToSnapshotByteRatio))"
                        )
                        metricRow(
                            title: "请求至首个内容",
                            value: "P95 \(formatDuration(report.bridgePerformance.firstVisibleLatency.p95Ms))",
                            detail: "最近 \(report.bridgePerformance.firstVisibleLatency.count) 个 Relay 任务"
                        )
                    }

                    Section {
                        if let metrics = report.transcriptScrollMetrics {
                            metricRow(
                                title: "主对话滚动视图",
                                value: metrics.scrollClass,
                                detail: "offset \(formatPoint(metrics.offsetY)) · content \(formatPoint(metrics.contentHeight)) · viewport \(formatPoint(metrics.viewportHeight))"
                            )
                            metricRow(
                                title: "距底部",
                                value: formatPoint(metrics.distanceFromBottom),
                                detail: "inset \(formatPoint(metrics.insetTop))/\(formatPoint(metrics.insetBottom)) · 到底 \(metrics.isAtBottom ? "是" : "否") · 拖动 \(metrics.isDragging ? "是" : "否")"
                            )
                        } else {
                            Text("尚未绑定主对话滚动视图")
                                .foregroundStyle(.secondary)
                        }

                        ForEach(report.transcriptScrollCommands.prefix(8)) { command in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(scrollReason(command.reason))
                                        .font(.system(size: 12, weight: .semibold))
                                    Spacer(minLength: 10)
                                    Text(command.recordedAt.formatted(date: .omitted, time: .standard))
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.tertiary)
                                }
                                Text("动画 \(command.animated ? "是" : "否") · 触发前到底 \(command.isAtBottom ? "是" : "否") · 用户滚动 \(command.isUserScrolling ? "是" : "否")")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } header: {
                        Text("对话滚动诊断")
                    } footer: {
                        Text("显示最近一次原生 UIScrollView 指标和最近 8 次主动滚动到底部的原因。")
                    }

                    if !report.bridgePerformance.recentTurnLatencies.isEmpty {
                        Section {
                            ForEach(report.bridgePerformance.recentTurnLatencies.prefix(8)) { latency in
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack(alignment: .firstTextBaseline) {
                                        Text(latency.receivedAt.formatted(date: .omitted, time: .standard))
                                            .font(.system(size: 13, weight: .semibold))
                                        Spacer(minLength: 10)
                                        Text("首个内容 \(formatOptionalDuration(latency.totalToFirstVisibleMs))")
                                            .font(.system(size: 12, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                    }
                                    Text(latencyBreakdown(latency))
                                        .font(.system(size: 10))
                                        .foregroundStyle(.tertiary)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Text("总计 \(formatDuration(latency.totalDurationMs)) · \(visibleEventName(latency.firstVisibleMethod))")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.vertical, 2)
                            }
                        } header: {
                            Text("最近任务延迟")
                        } footer: {
                            Text("Relay 转发和 RPC 通常应低于 100 ms；较长的“启动至首个内容”表示等待 Codex 或模型输出。")
                        }
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
                    Button { beginExport() } label: {
                        if isExporting {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                    .disabled(store.diagnosticsReport == nil || isExporting)
                }
                ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } }
            }
            .refreshable { await store.refreshDiagnostics() }
            .task { await store.refreshDiagnostics() }
            .sheet(item: $diagnosticsExport, onDismiss: removeExportedFile) { file in
                ShareSheet(items: [file.url])
            }
        }
    }

    private func beginExport() {
        guard !isExporting else { return }
        isExporting = true
        Task {
            let file = await store.prepareDiagnosticsExport()
            isExporting = false
            guard let file else { return }
            removeExportedFile()
            exportURLToRemove = file.url
            // Present the activity controller on the next run-loop turn. The
            // export completion can arrive while List is still relaying out,
            // which makes the share sheet stutter or briefly dismiss itself.
            DispatchQueue.main.async {
                diagnosticsExport = file
            }
        }
    }

    private func removeExportedFile() {
        guard let url = exportURLToRemove else { return }
        exportURLToRemove = nil
        try? FileManager.default.removeItem(at: url)
    }

    private func color(for level: String) -> Color {
        switch level { case "ok", "info": return RelayTheme.accent; case "error": return .red; default: return .orange }
    }

    private func icon(for level: String) -> String {
        switch level { case "ok": return "checkmark.circle.fill"; case "error": return "xmark.octagon.fill"; default: return "exclamationmark.triangle.fill" }
    }

    private func metricRow(title: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 12)
                Text(value).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
            }
            Text(detail).font(.system(size: 10)).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    private func formatMilliseconds(_ value: Double) -> String {
        value < 10 ? String(format: "%.1f ms", value) : String(format: "%.0f ms", value)
    }

    private func formatDuration(_ value: Double) -> String {
        value >= 1_000 ? String(format: "%.1f 秒", value / 1_000) : formatMilliseconds(value)
    }

    private func formatOptionalDuration(_ value: Double?) -> String {
        guard let value else { return "未记录" }
        return formatDuration(value)
    }

    private func latencyBreakdown(_ latency: BridgeTurnLatencyDiagnostic) -> String {
        "Relay \(formatOptionalDuration(latency.receivedToForwardMs)) · RPC \(formatOptionalDuration(latency.forwardToAcceptedMs)) · 启动 \(formatOptionalDuration(latency.acceptedToStartedMs)) · Codex \(formatOptionalDuration(latency.startedToFirstVisibleMs))"
    }

    private func visibleEventName(_ method: String?) -> String {
        switch method {
        case "item/reasoning/summaryTextDelta", "item/reasoning/textDelta": return "首项：思考"
        case "item/agentMessage/delta": return "首项：回答"
        case "turn/plan/updated": return "首项：计划"
        case "item/started", "item/completed": return "首项：操作"
        case nil: return "未收到可见事件"
        default: return "首项：其他"
        }
    }

    private func formatBytes(_ value: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file)
    }

    private func formatRatio(_ value: Double) -> String {
        String(format: "%.1f%%", value * 100)
    }

    private func formatPoint(_ value: CGFloat) -> String {
        String(format: "%.1f", value)
    }

    private func scrollReason(_ reason: TranscriptScrollCommandReason) -> String {
        switch reason {
        case .initialThread: return "首次打开对话"
        case .liveUpdate: return "实时内容更新"
        case .outgoingMessage: return "发送消息"
        case .outgoingMessageLayout: return "发送消息排版完成"
        case .queuedFollowUp: return "引导队列变化"
        case .bottomButton: return "点击回到底部"
        case .keyboardTransition: return "键盘高度变化"
        }
    }
}
