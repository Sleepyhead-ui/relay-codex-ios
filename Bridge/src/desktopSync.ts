import { spawn } from "node:child_process";

const THREAD_ID_PATTERN = /^[a-f0-9]{8}-[a-f0-9-]{27,}$/i;

export class DesktopSync {
  private readonly lastActivation = new Map<string, number>();

  constructor(
    readonly enabled: boolean,
    private readonly log: (message: string) => void,
  ) {}

  activateThread(threadId: unknown, reason: "turn-started" | "turn-completed"): void {
    if (!this.enabled || process.platform !== "win32" || typeof threadId !== "string" || !THREAD_ID_PATTERN.test(threadId)) {
      return;
    }

    const now = Date.now();
    const previous = this.lastActivation.get(threadId) ?? 0;
    if (now - previous < 750) return;
    this.lastActivation.set(threadId, now);

    const delay = reason === "turn-started" ? 320 : 180;
    setTimeout(() => {
      try {
        const child = spawn("explorer.exe", [`codex://threads/${threadId}`], {
          detached: true,
          windowsHide: true,
          stdio: "ignore",
        });
        child.unref();
        this.log(`Desktop sync opened ${threadId} (${reason}).`);
      } catch (error) {
        this.log(`Desktop sync failed: ${error instanceof Error ? error.message : String(error)}`);
      }
    }, delay).unref();
  }
}
