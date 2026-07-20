import { access, mkdir, readFile, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import path from "node:path";
import { execFile } from "node:child_process";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

export interface CodexProfile {
  id: string;
  name: string;
  codexHome: string;
  source: "default" | "cockpit" | "custom";
  active: boolean;
  running: boolean;
}

interface CockpitInstance {
  id?: unknown;
  name?: unknown;
  userDataDir?: unknown;
  lastPid?: unknown;
}

interface RegistryOptions {
  userHome?: string;
  relayDirectory?: string;
  cockpitDirectory?: string;
  environment?: NodeJS.ProcessEnv;
  detectRunning?: boolean;
}

export class CodexProfileRegistry {
  private activeHome: string;

  private constructor(
    private readonly userHome: string,
    private readonly relayDirectory: string,
    private readonly cockpitDirectory: string,
    private readonly detectRunning: boolean,
    initialHome: string,
  ) {
    this.activeHome = path.resolve(initialHome);
  }

  static async create(options: RegistryOptions = {}): Promise<CodexProfileRegistry> {
    const userHome = options.userHome ?? homedir();
    const relayDirectory = options.relayDirectory ?? path.join(userHome, ".relay");
    const cockpitDirectory = options.cockpitDirectory ?? path.join(userHome, ".antigravity_cockpit");
    const environment = options.environment ?? process.env;
    const configured = environment.RELAY_CODEX_HOME?.trim() || environment.CODEX_HOME?.trim();
    const saved = configured ? undefined : await readSavedHome(relayDirectory);
    return new CodexProfileRegistry(
      userHome,
      relayDirectory,
      cockpitDirectory,
      options.detectRunning ?? options.userHome === undefined,
      configured || saved || path.join(userHome, ".codex"),
    );
  }

  get activeCodexHome(): string {
    return this.activeHome;
  }

  async list(): Promise<CodexProfile[]> {
    const candidates: Omit<CodexProfile, "active">[] = [{
      id: "default",
      name: "默认 Codex",
      codexHome: path.join(this.userHome, ".codex"),
      source: "default",
      running: this.detectRunning ? await isDefaultCodexRunning() : false,
    }];

    try {
      const file = await readFile(path.join(this.cockpitDirectory, "codex_instances.json"), "utf8");
      const parsed = JSON.parse(file) as { instances?: CockpitInstance[] };
      for (const instance of parsed.instances ?? []) {
        if (typeof instance.id !== "string" || typeof instance.userDataDir !== "string") continue;
        const codexHome = path.resolve(instance.userDataDir);
        if (!(await hasCodexHome(codexHome))) continue;
        candidates.push({
          id: `cockpit:${instance.id}`,
          name: typeof instance.name === "string" && instance.name.trim() ? instance.name.trim() : "Cockpit Codex",
          codexHome,
          source: "cockpit",
          running: this.detectRunning && typeof instance.lastPid === "number" ? isPidRunning(instance.lastPid) : false,
        });
      }
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") {
        console.warn(`[profiles] Could not read Cockpit instances: ${error instanceof Error ? error.message : error}`);
      }
    }

    if (!candidates.some((profile) => samePath(profile.codexHome, this.activeHome))) {
      candidates.push({ id: "custom", name: "自定义 Codex", codexHome: this.activeHome, source: "custom", running: true });
    }

    const unique = new Map<string, Omit<CodexProfile, "active">>();
    for (const candidate of candidates) {
      const key = normalizedPath(candidate.codexHome);
      if (!unique.has(key)) unique.set(key, candidate);
    }
    return [...unique.values()].map((profile) => ({
      ...profile,
      active: samePath(profile.codexHome, this.activeHome),
    }));
  }

  async select(profileId: unknown): Promise<CodexProfile> {
    if (typeof profileId !== "string" || !profileId) throw new Error("请选择一个 Codex 实例。");
    const profile = (await this.list()).find((candidate) => candidate.id === profileId);
    if (!profile) throw new Error("找不到所选 Codex 实例，请刷新后重试。");
    if (!(await hasCodexHome(profile.codexHome))) throw new Error("所选 Codex 配置目录不存在。");
    this.activeHome = path.resolve(profile.codexHome);
    await mkdir(this.relayDirectory, { recursive: true });
    await writeFile(
      path.join(this.relayDirectory, "codex-profile.json"),
      `${JSON.stringify({ codexHome: this.activeHome }, null, 2)}\n`,
      "utf8",
    );
    return { ...profile, codexHome: this.activeHome, active: true };
  }
}

async function readSavedHome(relayDirectory: string): Promise<string | undefined> {
  try {
    const value = JSON.parse(await readFile(path.join(relayDirectory, "codex-profile.json"), "utf8")) as { codexHome?: unknown };
    return typeof value.codexHome === "string" && value.codexHome.trim() ? value.codexHome.trim() : undefined;
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "ENOENT") {
      console.warn(`[profiles] Could not read the saved Codex profile: ${error instanceof Error ? error.message : error}`);
    }
    return undefined;
  }
}

async function hasCodexHome(codexHome: string): Promise<boolean> {
  try {
    await access(codexHome);
    return true;
  } catch {
    return false;
  }
}

function samePath(left: string, right: string): boolean {
  return normalizedPath(left) === normalizedPath(right);
}

function normalizedPath(value: string): string {
  const resolved = path.resolve(value);
  return process.platform === "win32" ? resolved.toLowerCase() : resolved;
}

function isPidRunning(pid: number): boolean {
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

async function isDefaultCodexRunning(): Promise<boolean> {
  if (process.platform !== "win32") return false;
  try {
    const command = "$items=Get-CimInstance Win32_Process -Filter \"Name='ChatGPT.exe'\"; if($items | Where-Object { $_.CommandLine -notmatch '--type=' -and $_.CommandLine -notmatch '--user-data-dir=' }) { 'true' } else { 'false' }";
    const { stdout } = await execFileAsync("powershell.exe", ["-NoProfile", "-Command", command], { windowsHide: true, timeout: 4_000 });
    return stdout.trim().toLowerCase() === "true";
  } catch {
    return false;
  }
}
