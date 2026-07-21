export type DiagnosticLevel = "info" | "warning" | "error";

export interface DiagnosticEvent {
  id: number;
  at: string;
  level: DiagnosticLevel;
  category: string;
  message: string;
  details?: Record<string, unknown>;
}

export interface DiagnosticCheck {
  id: string;
  level: "ok" | "warning" | "error";
  title: string;
  detail: string;
}

interface DiagnosticState {
  codexReady: boolean;
  clients: number;
  activeTurns: number;
  pendingRpcCount: number;
  pendingApprovalCount: number;
  queuedPromptCount: number;
  codexRestartAttempt: number;
  uptimeSeconds: number;
  desktopSync: Record<string, unknown>;
  socket: Record<string, unknown>;
  rpc: Record<string, unknown>;
  codexProfile: Record<string, unknown>;
}

export class DiagnosticsLog {
  private events: DiagnosticEvent[] = [];
  private nextId = 1;

  constructor(private readonly limit = 100) {}

  record(level: DiagnosticLevel, category: string, message: string, details?: Record<string, unknown>): void {
    const event: DiagnosticEvent = { id: this.nextId++, at: new Date().toISOString(), level, category, message };
    if (details) event.details = details;
    this.events.push(event);
    if (this.events.length > this.limit) this.events.splice(0, this.events.length - this.limit);
  }

  report(state: DiagnosticState): Record<string, unknown> {
    const checks: DiagnosticCheck[] = [
      {
        id: "bridge",
        level: "ok",
        title: "Relay Bridge",
        detail: `已运行 ${formatDuration(state.uptimeSeconds)}`,
      },
      {
        id: "codex",
        level: state.codexReady ? "ok" : state.codexRestartAttempt > 0 ? "warning" : "error",
        title: "Codex App Server",
        detail: state.codexReady ? "已就绪" : state.codexRestartAttempt > 0 ? `正在进行第 ${state.codexRestartAttempt} 次恢复` : "尚未就绪",
      },
      {
        id: "client",
        level: state.clients > 0 ? "ok" : "warning",
        title: "远程客户端",
        detail: state.clients > 0 ? `${state.clients} 台设备已连接` : "当前没有设备连接",
      },
      {
        id: "rpc",
        level: state.pendingRpcCount > 0 ? "warning" : "ok",
        title: "请求队列",
        detail: state.pendingRpcCount > 0 ? `${state.pendingRpcCount} 个请求仍在等待` : "没有积压请求",
      },
      {
        id: "approval",
        level: state.pendingApprovalCount > 0 ? "warning" : "ok",
        title: "待处理审批",
        detail: state.pendingApprovalCount > 0 ? `${state.pendingApprovalCount} 项操作等待确认` : "没有等待确认的操作",
      },
    ];
    const summary = checks.some((check) => check.level === "error")
      ? "error"
      : checks.some((check) => check.level === "warning") ? "warning" : "ok";
    return {
      generatedAt: new Date().toISOString(),
      summary,
      checks,
      metrics: {
        clients: state.clients,
        activeTurns: state.activeTurns,
        pendingRpcCount: state.pendingRpcCount,
        pendingApprovalCount: state.pendingApprovalCount,
        queuedPromptCount: state.queuedPromptCount,
        uptimeSeconds: state.uptimeSeconds,
      },
      desktopSync: state.desktopSync,
      socket: state.socket,
      rpc: state.rpc,
      codexProfile: state.codexProfile,
      events: [...this.events].reverse(),
    };
  }
}

function formatDuration(seconds: number): string {
  if (seconds < 60) return `${seconds} 秒`;
  if (seconds < 3600) return `${Math.floor(seconds / 60)} 分钟`;
  return `${Math.floor(seconds / 3600)} 小时 ${Math.floor((seconds % 3600) / 60)} 分钟`;
}
