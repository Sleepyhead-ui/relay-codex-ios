import { randomBytes } from "node:crypto";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

export interface RelayConfig {
  host: string;
  port: number;
  token: string;
  advertiseUrl: string;
  codexBin: string;
  defaultCwd?: string;
  filesRoot?: string;
  desktopSync: boolean;
  desktopCdpPort: number;
  desktopAppPath: string | undefined;
}

export async function loadConfig(): Promise<RelayConfig> {
  const host = process.env.RELAY_HOST ?? "127.0.0.1";
  const port = parsePort(process.env.RELAY_PORT ?? "8765");
  const token = process.env.RELAY_TOKEN ?? (await loadOrCreateToken());
  const advertiseUrl = process.env.RELAY_ADVERTISE_URL ?? `ws://${host}:${port}`;
  const bridgeRoot = fileURLToPath(new URL("../", import.meta.url));
  const bundledCodex = path.join(bridgeRoot, "node_modules", "@openai", "codex", "bin", "codex.js");
  const codexBin = process.env.CODEX_BIN ?? bundledCodex;
  const defaultCwd = process.env.RELAY_DEFAULT_CWD?.trim();
  const filesRoot = process.env.RELAY_FILES_ROOT?.trim();
  const desktopSync = parseBoolean(process.env.RELAY_DESKTOP_SYNC ?? "false");
  const desktopCdpPort = parsePort(process.env.RELAY_DESKTOP_CDP_PORT ?? "9223");
  const desktopAppPath = process.env.RELAY_DESKTOP_APP_PATH?.trim() || undefined;

  return {
    host,
    port,
    token,
    advertiseUrl,
    codexBin,
    desktopSync,
    desktopCdpPort,
    desktopAppPath,
    ...(defaultCwd ? { defaultCwd } : {}),
    ...(filesRoot ? { filesRoot } : {}),
  };
}

function parseBoolean(raw: string): boolean {
  return ["1", "true", "yes", "on"].includes(raw.trim().toLowerCase());
}

function parsePort(raw: string): number {
  const port = Number.parseInt(raw, 10);
  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    throw new Error(`Invalid RELAY_PORT: ${raw}`);
  }
  return port;
}

async function loadOrCreateToken(): Promise<string> {
  const directory = path.join(homedir(), ".relay");
  const tokenPath = path.join(directory, "token");
  await mkdir(directory, { recursive: true });

  try {
    const token = (await readFile(tokenPath, "utf8")).trim();
    if (token.length >= 32) return token;
  } catch (error) {
    const code = (error as NodeJS.ErrnoException).code;
    if (code !== "ENOENT") throw error;
  }

  const token = randomBytes(32).toString("base64url");
  await writeFile(tokenPath, `${token}\n`, { encoding: "utf8", mode: 0o600 });
  return token;
}
