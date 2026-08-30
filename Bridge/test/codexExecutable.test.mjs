import assert from "node:assert/strict";
import { mkdtemp, mkdir, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import { codexRuntimeCompatibility, parseCodexVersion, resolveCodexExecutable } from "../dist/codexExecutable.js";

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

test("parses Codex versions and classifies the supported range", () => {
  assert.equal(parseCodexVersion("codex-cli 0.148.0-alpha.9"), "0.148.0-alpha.9");
  assert.equal(parseCodexVersion("codex-cli 0.151.0-alpha.7.2"), "0.151.0-alpha.7.2");
  assert.equal(parseCodexVersion("unexpected output"), null);
  assert.equal(codexRuntimeCompatibility("0.144.5"), "compatible");
  assert.equal(codexRuntimeCompatibility("0.151.0-alpha.7.2"), "compatible");
  assert.equal(codexRuntimeCompatibility("0.151.9"), "compatible");
  assert.equal(codexRuntimeCompatibility("0.152.0"), "untested");
  assert.equal(codexRuntimeCompatibility("0.143.9"), "outdated");
  assert.equal(codexRuntimeCompatibility("0.149.0"), "compatible");
});
