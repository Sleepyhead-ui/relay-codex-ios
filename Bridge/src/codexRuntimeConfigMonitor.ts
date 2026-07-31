import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import path from "node:path";

const runtimeConfigFiles = [
  "config.toml",
  "auth.json",
  ".env",
  ".cockpit_codex_auth.json",
] as const;

export type CodexRuntimeConfigChangeHandler = (changedFiles: string[]) => void | Promise<void>;

export class CodexRuntimeConfigMonitor {
  private codexHome: string | undefined;
  private snapshot = new Map<string, string>();
  private interval: NodeJS.Timeout | undefined;
  private checking = false;

  constructor(
    private readonly onChange: CodexRuntimeConfigChangeHandler,
    private readonly intervalMs = 1_500,
  ) {}

  async start(codexHome: string): Promise<void> {
    await this.setCodexHome(codexHome);
    if (this.interval || this.intervalMs <= 0) return;
    this.interval = setInterval(() => {
      void this.checkNow().catch((error) => {
        console.warn(`[codex] Could not inspect configuration changes: ${error instanceof Error ? error.message : error}`);
      });
    }, this.intervalMs);
    this.interval.unref();
  }

  async setCodexHome(codexHome: string): Promise<void> {
    this.codexHome = path.resolve(codexHome);
    this.snapshot = await readRuntimeConfigSnapshot(this.codexHome);
  }

  async checkNow(): Promise<boolean> {
    if (!this.codexHome || this.checking) return false;
    this.checking = true;
    try {
      const codexHome = this.codexHome;
      const next = await readRuntimeConfigSnapshot(codexHome);
      if (this.codexHome !== codexHome) return false;
      const changedFiles = runtimeConfigFiles.filter((file) => this.snapshot.get(file) !== next.get(file));
      if (changedFiles.length === 0) return false;
      this.snapshot = next;
      await this.onChange(changedFiles);
      return true;
    } finally {
      this.checking = false;
    }
  }

  stop(): void {
    if (this.interval) clearInterval(this.interval);
    this.interval = undefined;
  }
}

export async function readRuntimeConfigSnapshot(codexHome: string): Promise<Map<string, string>> {
  const entries = await Promise.all(runtimeConfigFiles.map(async (file) => {
    try {
      const contents = await readFile(path.join(codexHome, file));
      return [file, createHash("sha256").update(contents).digest("hex")] as const;
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ENOENT") return [file, "missing"] as const;
      throw error;
    }
  }));
  return new Map(entries);
}
