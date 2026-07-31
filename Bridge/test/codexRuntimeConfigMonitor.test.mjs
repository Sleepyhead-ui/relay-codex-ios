import assert from "node:assert/strict";
import { mkdtemp, rm, unlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import { CodexRuntimeConfigMonitor } from "../dist/codexRuntimeConfigMonitor.js";

test("detects Codex API configuration and credential changes", async (context) => {
  const home = await mkdtemp(path.join(tmpdir(), "relay-codex-config-"));
  context.after(() => rm(home, { recursive: true, force: true }));
  await writeFile(path.join(home, "config.toml"), 'base_url = "https://old.example/v1"\n');
  const changes = [];
  const monitor = new CodexRuntimeConfigMonitor((files) => changes.push(files), 0);
  await monitor.start(home);

  await writeFile(path.join(home, "config.toml"), 'base_url = "https://new.example/v1"\n');
  assert.equal(await monitor.checkNow(), true);
  assert.deepEqual(changes, [["config.toml"]]);

  await writeFile(path.join(home, "auth.json"), '{"OPENAI_API_KEY":"new"}\n');
  assert.equal(await monitor.checkNow(), true);
  assert.deepEqual(changes.at(-1), ["auth.json"]);

  await unlink(path.join(home, "auth.json"));
  assert.equal(await monitor.checkNow(), true);
  assert.deepEqual(changes.at(-1), ["auth.json"]);
  assert.equal(await monitor.checkNow(), false);
});

test("resets its baseline when the active Codex home changes", async (context) => {
  const first = await mkdtemp(path.join(tmpdir(), "relay-codex-first-"));
  const second = await mkdtemp(path.join(tmpdir(), "relay-codex-second-"));
  context.after(() => Promise.all([
    rm(first, { recursive: true, force: true }),
    rm(second, { recursive: true, force: true }),
  ]));
  await writeFile(path.join(first, "config.toml"), "first\n");
  await writeFile(path.join(second, "config.toml"), "second\n");
  let calls = 0;
  const monitor = new CodexRuntimeConfigMonitor(() => { calls += 1; }, 0);
  await monitor.start(first);
  await monitor.setCodexHome(second);

  assert.equal(await monitor.checkNow(), false);
  assert.equal(calls, 0);
  await writeFile(path.join(first, "config.toml"), "ignored\n");
  assert.equal(await monitor.checkNow(), false);
  await writeFile(path.join(second, "config.toml"), "changed\n");
  assert.equal(await monitor.checkNow(), true);
  assert.equal(calls, 1);
});
