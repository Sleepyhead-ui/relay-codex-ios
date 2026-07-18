import { spawn } from "node:child_process";
import { WebSocket } from "ws";

const THREAD_ID_PATTERN = /^[a-f0-9]{8}-[a-f0-9-]{27,}$/i;

export interface DesktopSyncStatus {
  enabled: boolean;
  mode: "off" | "pending" | "enhanced" | "deep-link";
  lastAttemptAt?: string;
  lastResult?: string;
}

interface CdpTarget {
  type?: string;
  title?: string;
  url?: string;
  webSocketDebuggerUrl?: string;
}

export class DesktopSync {
  private readonly lastActivation = new Map<string, number>();
  private statusValue: DesktopSyncStatus;
  private lastLaunchAttemptAt = 0;

  constructor(
    readonly enabled: boolean,
    private readonly cdpPort: number,
    private readonly desktopAppPath: string | undefined,
    private readonly log: (message: string) => void,
    private readonly onStatusChange: (status: DesktopSyncStatus) => void = () => {},
  ) {
    this.statusValue = { enabled, mode: enabled ? "pending" : "off" };
  }

  get status(): DesktopSyncStatus { return { ...this.statusValue }; }

  activateThread(threadId: unknown, reason: "turn-started" | "turn-completed"): void {
    if (!this.enabled || process.platform !== "win32" || typeof threadId !== "string" || !THREAD_ID_PATTERN.test(threadId)) {
      return;
    }

    const now = Date.now();
    const previous = this.lastActivation.get(threadId) ?? 0;
    if (now - previous < 750) return;
    this.lastActivation.set(threadId, now);

    const delay = reason === "turn-started" ? 240 : 120;
    setTimeout(() => void this.performSync(threadId, reason), delay).unref();
  }

  private async performSync(threadId: string, reason: "turn-started" | "turn-completed"): Promise<void> {
    this.statusValue = { ...this.statusValue, lastAttemptAt: new Date().toISOString() };
    this.onStatusChange(this.status);
    await this.ensureDesktopDebugging();
    let enhanced = false;
    if (reason === "turn-completed") {
      try {
        enhanced = await this.reloadDesktopRenderer();
      } catch (error) {
        this.log(`Enhanced refresh unavailable: ${error instanceof Error ? error.message : String(error)}`);
      }
    }

    if (enhanced) await delay(550);
    const opened = this.openThread(threadId);
    this.statusValue = {
      enabled: true,
      mode: enhanced ? "enhanced" : "deep-link",
      lastAttemptAt: new Date().toISOString(),
      lastResult: opened
        ? enhanced ? "Renderer refreshed and thread reopened." : "Thread deep link opened."
        : "Could not open the desktop thread.",
    };
    this.onStatusChange(this.status);
    this.log(`${enhanced ? "Enhanced refresh" : "Deep-link refresh"} ${opened ? "completed" : "failed"} for ${threadId} (${reason}).`);
  }

  private openThread(threadId: string): boolean {
    try {
      const child = spawn("explorer.exe", [`codex://threads/${threadId}`], {
        detached: true,
        windowsHide: true,
        stdio: "ignore",
      });
      child.unref();
      return true;
    } catch {
      return false;
    }
  }

  private async reloadDesktopRenderer(): Promise<boolean> {
    const response = await fetch(`http://127.0.0.1:${this.cdpPort}/json/list`, { signal: AbortSignal.timeout(1_500) });
    if (!response.ok) return false;
    const targets = await response.json() as CdpTarget[];
    const target = targets.find((item) =>
      item.type === "page" &&
      typeof item.webSocketDebuggerUrl === "string" &&
      (item.url?.startsWith("app://") || /codex|chatgpt/i.test(item.title ?? "")),
    );
    if (!target?.webSocketDebuggerUrl) return false;
    await sendCdpReload(target.webSocketDebuggerUrl);
    return true;
  }

  private async ensureDesktopDebugging(): Promise<void> {
    if (await this.isCdpAvailable() || !this.desktopAppPath || Date.now() - this.lastLaunchAttemptAt < 30_000) return;
    this.lastLaunchAttemptAt = Date.now();
    try {
      const child = spawn(this.desktopAppPath, [
        "--remote-debugging-address=127.0.0.1",
        `--remote-debugging-port=${this.cdpPort}`,
      ], {
        detached: true,
        windowsHide: false,
        stdio: "ignore",
      });
      child.unref();
      await delay(900);
    } catch (error) {
      this.log(`Could not start Codex for enhanced sync: ${error instanceof Error ? error.message : String(error)}`);
    }
  }

  private async isCdpAvailable(): Promise<boolean> {
    try {
      const response = await fetch(`http://127.0.0.1:${this.cdpPort}/json/version`, { signal: AbortSignal.timeout(600) });
      return response.ok;
    } catch {
      return false;
    }
  }
}

function sendCdpReload(endpoint: string): Promise<void> {
  return new Promise((resolve, reject) => {
    const socket = new WebSocket(endpoint);
    const timer = setTimeout(() => {
      socket.terminate();
      reject(new Error("Desktop refresh timed out."));
    }, 2_000);
    socket.once("open", () => {
      socket.send(JSON.stringify({ id: 1, method: "Page.reload", params: { ignoreCache: false } }), (error) => {
        clearTimeout(timer);
        if (error) reject(error);
        else resolve();
        setTimeout(() => socket.close(), 100).unref();
      });
    });
    socket.once("error", (error) => {
      clearTimeout(timer);
      reject(error);
    });
  });
}

function delay(milliseconds: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}
