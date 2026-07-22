import { existsSync, readFileSync } from "node:fs";
import path from "node:path";

/**
 * Cockpit profiles record the Codex binary that owns their local API proxy.
 * Using that binary keeps Relay's App Server protocol aligned with the active
 * desktop instance while retaining the bundled binary as an offline fallback.
 */
export function resolveCodexExecutable(codexHome: string, fallback: string): string {
  const configured = readConfiguredCodexPath(path.join(codexHome, "config.toml"));
  if (!configured) return fallback;

  const candidate = path.isAbsolute(configured)
    ? path.normalize(configured)
    : path.resolve(codexHome, configured);
  return existsSync(candidate) ? candidate : fallback;
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
