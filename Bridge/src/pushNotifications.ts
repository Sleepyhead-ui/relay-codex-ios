import { readFile } from "node:fs/promises";

export interface PushPreferences {
  remoteNotifications: boolean;
  barkUrl: string;
  pushIncludePreview: boolean;
}

export interface TaskCompletionPush {
  turnId: string;
  threadId: string;
  failed: boolean;
  taskTitle?: string;
  preview?: string;
}

export interface ExternalSessionState {
  known: boolean;
  isRunning: boolean;
  turnId?: string;
  completedAt?: number;
}

export interface ActiveTurnState {
  known: boolean;
  isRunning: boolean;
  activeTurnId?: string;
}

type Fetch = typeof fetch;

const defaultPreferences: PushPreferences = {
  remoteNotifications: false,
  barkUrl: "",
  pushIncludePreview: false,
};

export const defaultBarkIconUrl = "https://cdn.jsdelivr.net/gh/Sleepyhead-ui/relay-codex-ios@v1.1.24/assets/relay-push-icon.png";

export function isActiveTurnCompletion(state: ActiveTurnState, params: unknown): boolean {
  if (!state.known || !state.isRunning || !isRecord(params)) return false;
  const turn = isRecord(params.turn) ? params.turn : {};
  const turnId = typeof params.turnId === "string"
    ? params.turnId
    : typeof turn.id === "string" ? turn.id : undefined;
  return Boolean(turnId && state.activeTurnId === turnId);
}

export class ExternalCompletionTracker {
  private readonly states = new Map<string, { turnId: string; isRunning: boolean }>();

  constructor(private readonly startedAt = Date.now() / 1000) {}

  observe(threadId: string, snapshot: ExternalSessionState): boolean {
    if (!snapshot.known || !snapshot.turnId) return false;
    const previous = this.states.get(threadId);
    this.states.set(threadId, { turnId: snapshot.turnId, isRunning: snapshot.isRunning });
    if (snapshot.isRunning) return false;
    if (previous?.isRunning === true && previous.turnId === snapshot.turnId) return true;
    if (previous && previous.turnId !== snapshot.turnId) {
      return typeof snapshot.completedAt === "number" && snapshot.completedAt >= this.startedAt;
    }
    return previous === undefined
      && typeof snapshot.completedAt === "number"
      && snapshot.completedAt >= this.startedAt;
  }

  retry(threadId: string, turnId: string): void {
    const current = this.states.get(threadId);
    if (current?.turnId === turnId) this.states.set(threadId, { turnId, isRunning: true });
  }

  reset(): void {
    this.states.clear();
  }
}

export class BarkPushNotifier {
  private readonly sentTurnIds = new Set<string>();
  private readonly pendingTurnIds = new Set<string>();
  private readonly sentTurnOrder: string[] = [];

  constructor(
    private readonly preferencesPath = process.env.RELAY_PUSH_CONFIG,
    private readonly environmentUrl = process.env.RELAY_BARK_URL,
    private readonly fetcher: Fetch = fetch,
    private readonly iconUrl = process.env.RELAY_BARK_ICON_URL?.trim() || defaultBarkIconUrl,
  ) {}

  async status(): Promise<{ configured: boolean; enabled: boolean; includePreview: boolean }> {
    const preferences = await this.preferences();
    return {
      configured: Boolean(preferences.barkUrl),
      enabled: preferences.remoteNotifications && Boolean(preferences.barkUrl),
      includePreview: preferences.pushIncludePreview,
    };
  }

  async sendTaskCompletion(message: TaskCompletionPush): Promise<boolean> {
    if (this.sentTurnIds.has(message.turnId) || this.pendingTurnIds.has(message.turnId)) return false;
    this.pendingTurnIds.add(message.turnId);
    try {
      const preferences = await this.preferences();
      if (!preferences.remoteNotifications || !preferences.barkUrl) return false;

      const title = message.failed ? "Relay 任务执行失败" : "Relay 任务已完成";
      const privateBody = message.failed ? "Codex 未能完成这个任务" : "任务已处理完毕";
      const preview = cleanPreview(message.preview ?? "");
      const taskTitle = cleanPreview(message.taskTitle ?? "", 80);
      const body = preferences.pushIncludePreview
        ? preview || taskTitle || privateBody
        : privateBody;
      await sendBark(this.fetcher, preferences.barkUrl, {
        title,
        body,
        group: "Relay",
        icon: this.iconUrl,
        level: message.failed ? "timeSensitive" : "active",
        url: relayThreadURL(message.threadId),
      });
      this.remember(message.turnId);
      return true;
    } finally {
      this.pendingTurnIds.delete(message.turnId);
    }
  }

  async sendTest(): Promise<void> {
    const preferences = await this.preferences();
    if (!preferences.remoteNotifications) throw new Error("请先开启手机远程推送。");
    if (!preferences.barkUrl) throw new Error("请先填写 Bark 设备地址。");
    await sendBark(this.fetcher, preferences.barkUrl, {
      title: "Relay 推送已连接",
      body: "Windows 可以在 Relay 被 iOS 挂起时继续发送任务通知。",
      group: "Relay",
      icon: this.iconUrl,
      level: "active",
      url: "relay://open",
    });
  }

  private async preferences(): Promise<PushPreferences> {
    if (this.preferencesPath) {
      try {
        const raw = JSON.parse(await readFile(this.preferencesPath, "utf8")) as Partial<PushPreferences>;
        return {
          remoteNotifications: raw.remoteNotifications === true,
          barkUrl: typeof raw.barkUrl === "string" ? raw.barkUrl.trim() : "",
          pushIncludePreview: raw.pushIncludePreview === true,
        };
      } catch {}
    }
    if (this.environmentUrl?.trim()) {
      return { ...defaultPreferences, remoteNotifications: true, barkUrl: this.environmentUrl.trim() };
    }
    return defaultPreferences;
  }

  private remember(turnId: string): void {
    this.sentTurnIds.add(turnId);
    this.sentTurnOrder.push(turnId);
    while (this.sentTurnOrder.length > 256) {
      const removed = this.sentTurnOrder.shift();
      if (removed) this.sentTurnIds.delete(removed);
    }
  }
}

export function normalizeBarkEndpoint(source: string): URL {
  const url = new URL(source.trim());
  if (!["https:", "http:"].includes(url.protocol)) throw new Error("Bark 地址必须使用 HTTP 或 HTTPS。");
  if (url.username || url.password) throw new Error("Bark 地址不能包含登录凭据。");
  const segments = url.pathname.split("/").filter(Boolean);
  if (segments.length === 0) throw new Error("Bark 地址缺少设备 Key。");
  if (url.hostname.toLowerCase() === "api.day.app") url.pathname = `/${segments[0]}`;
  url.search = "";
  url.hash = "";
  return url;
}

export function cleanPreview(source: string, limit = 220): string {
  const withoutThinking = source.replace(/<thinking\b[^>]*>[\s\S]*?<\/thinking\s*>/gi, " ");
  const normalized = withoutThinking
    .replace(/!\[([^\]]*)\]\([^)]*\)/g, "$1")
    .replace(/\[([^\]]+)\]\([^)]*\)/g, "$1")
    .replace(/```[^\n]*\n?/g, "")
    .replace(/[`*_>#]/g, "")
    .replace(/\s+/g, " ")
    .trim();
  if (normalized.length <= limit) return normalized;
  return `${normalized.slice(0, Math.max(1, limit - 1)).trim()}…`;
}

async function sendBark(
  fetcher: Fetch,
  endpoint: string,
  payload: Record<string, string>,
): Promise<void> {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 10_000);
  try {
    const response = await fetcher(normalizeBarkEndpoint(endpoint), {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(payload),
      signal: controller.signal,
    });
    const text = await response.text();
    let result: unknown;
    try { result = JSON.parse(text); } catch { result = undefined; }
    const code = typeof result === "object" && result !== null && "code" in result
      ? Number((result as { code?: unknown }).code)
      : undefined;
    if (!response.ok || (code !== undefined && code !== 200)) {
      throw new Error(`Bark 推送失败（HTTP ${response.status}${code ? ` / ${code}` : ""}）。`);
    }
  } finally {
    clearTimeout(timeout);
  }
}

function relayThreadURL(threadId: string): string {
  const url = new URL("relay://thread");
  url.searchParams.set("threadId", threadId);
  return url.toString();
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
