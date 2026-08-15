import { existsSync, readFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import path from "node:path";

export type CodexRuntimeSource = "codexDesktop" | "configured" | "relayBundled";
export type CodexRuntimeCompatibility = "compatible" | "outdated" | "untested" | "unavailable";

export interface CodexRuntimeInfo {
  executable: string;
  source: CodexRuntimeSource;
  version: string | null;
  compatibility: CodexRuntimeCompatibility;
  minimumSupportedVersion: string;
  maximumTestedVersion: string;
}

const minimumSupportedVersion = "0.144.5";
const maximumTestedVersion = "0.148.x";

/**
 * Cockpit profiles record the Codex binary that owns their local API proxy.
 * Using that binary keeps Relay's App Server protocol aligned with the active
 * desktop instance while retaining the bundled binary as an offline fallback.
 */
export function resolveCodexExecutable(codexHome: string, fallback: string): string {
  return resolveCodexRuntimeExecutable(codexHome, fallback).executable;
}

export function inspectCodexRuntime(codexHome: string, fallback: string): CodexRuntimeInfo {
  const resolved = resolveCodexRuntimeExecutable(codexHome, fallback);
  const result = spawnSync(resolved.executable, ["--version"], {
    encoding: "utf8",
    timeout: 5_000,
    windowsHide: true,
  });
  const version = parseCodexVersion(`${result.stdout ?? ""}\n${result.stderr ?? ""}`);
  return {
    ...resolved,
    version,
    compatibility: result.error || result.status !== 0 || !version
      ? "unavailable"
      : codexRuntimeCompatibility(version),
    minimumSupportedVersion,
    maximumTestedVersion,
  };
}

export function parseCodexVersion(output: string): string | null {
  return output.match(/(?:codex-cli\s+)?(\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?)/i)?.[1] ?? null;
}

export function codexRuntimeCompatibility(version: string): CodexRuntimeCompatibility {
  const parsed = semanticVersion(version);
  const minimum = semanticVersion(minimumSupportedVersion)!;
  if (!parsed) return "unavailable";
  if (compareVersion(parsed, minimum) < 0) return "outdated";
  if (parsed[0] > 0 || parsed[1] > 148) return "untested";
  return "compatible";
}

function resolveCodexRuntimeExecutable(codexHome: string, fallback: string): { executable: string; source: CodexRuntimeSource } {
  const configured = readConfiguredCodexPath(path.join(codexHome, "config.toml"));
  if (!configured) return { executable: fallback, source: "relayBundled" };

  const candidate = path.isAbsolute(configured)
    ? path.normalize(configured)
    : path.resolve(codexHome, configured);
  if (!existsSync(candidate)) return { executable: fallback, source: "relayBundled" };
  const normalized = candidate.replace(/\\/g, "/").toLowerCase();
  return {
    executable: candidate,
    source: normalized.includes("/openai/codex/bin/") ? "codexDesktop" : "configured",
  };
}

function semanticVersion(value: string): [number, number, number] | null {
  const match = value.match(/^(\d+)\.(\d+)\.(\d+)/);
  return match ? [Number(match[1]), Number(match[2]), Number(match[3])] : null;
}

function compareVersion(left: [number, number, number], right: [number, number, number]): number {
  for (let index = 0; index < 3; index += 1) {
    if (left[index] !== right[index]) return left[index]! - right[index]!;
  }
  return 0;
}

function readConfiguredCodexPath(configPath: string): string | undefined {
  let config: string;
  try {
    config = readFileSync(configPath, "utf8");
  } catch {
    return undefined;
  }

  const match = config.match(/^\s*CODEX_CLI_PATH\s*=\s*(?:'([^']+)'|"((?:\\.|[^"])*)")\s*$/m);
  if (!match) return undefined;
  if (match[1]) return match[1].trim() || undefined;
  if (!match[2]) return undefined;

  try {
    return JSON.parse(`"${match[2]}"`) || undefined;
  } catch {
    return match[2].trim() || undefined;
  }
}
