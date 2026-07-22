import assert from "node:assert/strict";
import { mkdtemp, mkdir, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import { resolveCodexExecutable } from "../dist/codexExecutable.js";

test("uses the CLI path configured by the selected Codex profile", async () => {
  const root = await mkdtemp(path.join(tmpdir(), "relay-codex-bin-"));
  const profile = path.join(root, "profile");
  const executable = path.join(root, "current", "codex.exe");
  await mkdir(profile, { recursive: true });
  await mkdir(path.dirname(executable), { recursive: true });
  await writeFile(executable, "placeholder");
  await writeFile(path.join(profile, "config.toml"), `[shell_environment_policy.set]\nCODEX_CLI_PATH = '${executable}'\n`);

  assert.equal(resolveCodexExecutable(profile, "bundled-codex.exe"), executable);
});

test("falls back when a profile CLI path is missing or stale", async () => {
  const root = await mkdtemp(path.join(tmpdir(), "relay-codex-bin-"));
  await writeFile(path.join(root, "config.toml"), "CODEX_CLI_PATH = 'C:\\\\missing\\\\codex.exe'\n");

  assert.equal(resolveCodexExecutable(root, "bundled-codex.exe"), "bundled-codex.exe");
  assert.equal(resolveCodexExecutable(path.join(root, "absent"), "bundled-codex.exe"), "bundled-codex.exe");
});
