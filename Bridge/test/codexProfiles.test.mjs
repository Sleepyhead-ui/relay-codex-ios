import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, mkdir, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { CodexProfileRegistry } from "../dist/codexProfiles.js";

test("discovers default and Cockpit Codex instances", async () => {
  const root = await mkdtemp(path.join(tmpdir(), "relay-profiles-"));
  const relayDirectory = path.join(root, ".relay");
  const cockpitDirectory = path.join(root, ".antigravity_cockpit");
  const cockpitHome = path.join(root, "instances", "user2");
  await mkdir(path.join(root, ".codex"), { recursive: true });
  await mkdir(cockpitHome, { recursive: true });
  await mkdir(cockpitDirectory, { recursive: true });
  await writeFile(path.join(cockpitDirectory, "codex_instances.json"), JSON.stringify({
    instances: [{ id: "user2-id", name: "user2", userDataDir: cockpitHome }],
  }));

  const registry = await CodexProfileRegistry.create({
    userHome: root,
    relayDirectory,
    cockpitDirectory,
    environment: {},
  });
  const profiles = await registry.list();
  assert.deepEqual(profiles.map(({ id, name, source, active }) => ({ id, name, source, active })), [
    { id: "default", name: "默认 Codex", source: "default", active: true },
    { id: "cockpit:user2-id", name: "user2", source: "cockpit", active: false },
  ]);
});

test("persists the selected Codex instance across Bridge restarts", async () => {
  const root = await mkdtemp(path.join(tmpdir(), "relay-profile-save-"));
  const relayDirectory = path.join(root, ".relay");
  const cockpitDirectory = path.join(root, ".antigravity_cockpit");
  const cockpitHome = path.join(root, "instances", "api");
  await mkdir(path.join(root, ".codex"), { recursive: true });
  await mkdir(cockpitHome, { recursive: true });
  await mkdir(cockpitDirectory, { recursive: true });
  await writeFile(path.join(cockpitDirectory, "codex_instances.json"), JSON.stringify({
    instances: [{ id: "api-id", name: "API", userDataDir: cockpitHome }],
  }));

  const registry = await CodexProfileRegistry.create({ userHome: root, relayDirectory, cockpitDirectory, environment: {} });
  const selected = await registry.select("cockpit:api-id");
  assert.equal(selected.active, true);
  assert.equal(selected.codexHome, path.resolve(cockpitHome));
  assert.deepEqual(JSON.parse(await readFile(path.join(relayDirectory, "codex-profile.json"), "utf8")), {
    codexHome: path.resolve(cockpitHome),
  });

  const restored = await CodexProfileRegistry.create({ userHome: root, relayDirectory, cockpitDirectory, environment: {} });
  assert.equal(restored.activeCodexHome, path.resolve(cockpitHome));
  assert.equal((await restored.list()).find((profile) => profile.active)?.id, "cockpit:api-id");
});

test("an explicit environment home overrides the saved instance", async () => {
  const root = await mkdtemp(path.join(tmpdir(), "relay-profile-env-"));
  const relayDirectory = path.join(root, ".relay");
  const explicitHome = path.join(root, "managed-home");
  await mkdir(relayDirectory, { recursive: true });
  await mkdir(explicitHome, { recursive: true });
  await writeFile(path.join(relayDirectory, "codex-profile.json"), JSON.stringify({ codexHome: path.join(root, ".codex") }));

  const registry = await CodexProfileRegistry.create({
    userHome: root,
    relayDirectory,
    cockpitDirectory: path.join(root, "missing"),
    environment: { RELAY_CODEX_HOME: explicitHome },
  });
  assert.equal(registry.activeCodexHome, path.resolve(explicitHome));
  const active = (await registry.list()).find((profile) => profile.active);
  assert.equal(active?.source, "custom");
});
