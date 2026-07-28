import { randomUUID } from "node:crypto";
import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import path from "node:path";

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
  activeTransferCount: number;
  pendingRpcCount: number;
  pendingApprovalCount: number;
  queuedPromptCount: number;
  pendingDeliveryCount: number;
  codexRestartAttempt: number;
  uptimeSeconds: number;
  desktopSync: Record<string, unknown>;
  socket: Record<string, unknown>;
  rpc: Record<string, unknown>;
  codexProfile: Record<string, unknown>;
  performance: Record<string, unknown>;
}

export class DiagnosticsLog {
  private events: DiagnosticEvent[] = [];
  private nextId = 1;
  private persistChain: Promise<void> = Promise.resolve();
  private persistTimer: NodeJS.Timeout | undefined;

  constructor(private readonly limit = 100, private readonly storagePath?: string) {}

  async restore(): Promise<void> {
    if (!this.storagePath) return;
    try {
      const parsed: unknown = JSON.parse(await readFile(this.storagePath, "utf8"));
      if (!Array.isArray(parsed)) return;
      this.events = parsed.flatMap((value) => isDiagnosticEvent(value) ? [value] : []).slice(-this.limit);
      this.nextId = this.events.reduce((highest, event) => Math.max(highest, event.id), 0) + 1;
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") {
        this.events = [];
        this.nextId = 1;
      }
    }
  }

  async flush(): Promise<void> {
    if (!this.storagePath) return;
    if (this.persistTimer) {
      clearTimeout(this.persistTimer);
      this.persistTimer = undefined;
    }
    await this.persist();
  }

  record(level: DiagnosticLevel, category: string, message: string, details?: Record<string, unknown>): void {
    const event: DiagnosticEvent = { id: this.nextId++, at: new Date().toISOString(), level, category, message };
    if (details) event.details = details;
    this.events.push(event);
    if (this.events.length > this.limit) this.events.splice(0, this.events.length - this.limit);
    this.schedulePersist();
  }

  private schedulePersist(): void {
    if (!this.storagePath || this.persistTimer) return;
    this.persistTimer = setTimeout(() => {
      this.persistTimer = undefined;
      void this.persist();
    }, 250);
    this.persistTimer.unref();
  }

  private async persist(): Promise<void> {
    if (!this.storagePath) return;
    const operation = this.persistChain.then(async () => {
      const snapshot = `${JSON.stringify(this.events, null, 2)}\n`;
      await mkdir(path.dirname(this.storagePath!), { recursive: true });
      const temporary = `${this.storagePath}.${process.pid}.${randomUUID()}.tmp`;
      await writeFile(temporary, snapshot, { encoding: "utf8", mode: 0o600 });
      await rename(temporary, this.storagePath!);
    });
    this.persistChain = operation.catch(() => {});
    await operation;
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
        id: "delivery",
        level: state.pendingDeliveryCount > 0 ? "warning" : "ok",
        title: "可靠投递",
        detail: state.pendingDeliveryCount > 0 ? `${state.pendingDeliveryCount} 条消息等待 Codex 确认` : "没有等待确认的消息",
      },
      {
        id: "approval",
        level: state.pendingApprovalCount > 0 ? "warning" : "ok",
        title: "待处理审批",
        detail: state.pendingApprovalCount > 0 ? `${state.pendingApprovalCount} 项操作等待确认` : "没有等待确认的操作",
      },
      {
        id: "transfer",
        level: state.activeTransferCount > 0 ? "warning" : "ok",
        title: "文件传输",
        detail: state.activeTransferCount > 0 ? `${state.activeTransferCount} 个文件仍在传输` : "没有进行中的文件传输",
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
        activeTransferCount: state.activeTransferCount,
        pendingRpcCount: state.pendingRpcCount,
        pendingApprovalCount: state.pendingApprovalCount,
        queuedPromptCount: state.queuedPromptCount,
        pendingDeliveryCount: state.pendingDeliveryCount,
        uptimeSeconds: state.uptimeSeconds,
      },
      desktopSync: state.desktopSync,
      socket: state.socket,
      rpc: state.rpc,
      codexProfile: state.codexProfile,
      performance: state.performance,
      events: [...this.events].reverse(),
    };
  }
}

function isDiagnosticEvent(value: unknown): value is DiagnosticEvent {
  if (!value || typeof value !== "object") return false;
  const event = value as Partial<DiagnosticEvent>;
  return typeof event.id === "number"
    && typeof event.at === "string"
    && ["info", "warning", "error"].includes(String(event.level))
    && typeof event.category === "string"
    && typeof event.message === "string";
}

function formatDuration(seconds: number): string {
  if (seconds < 60) return `${seconds} 秒`;
  if (seconds < 3600) return `${Math.floor(seconds / 60)} 分钟`;
  return `${Math.floor(seconds / 3600)} 小时 ${Math.floor((seconds % 3600) / 60)} 分钟`;
}
