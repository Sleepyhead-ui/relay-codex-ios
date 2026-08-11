import assert from "node:assert/strict";
import test from "node:test";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { ClientPreferencesStore } from "../dist/clientPreferences.js";

test("persists shared sidebar organization and sort choices", async () => {
  const directory = await mkdtemp(path.join(tmpdir(), "relay-client-preferences-"));
  const storage = path.join(directory, "preferences.json");
  try {
    const preferences = await ClientPreferencesStore.create(storage);
    assert.deepEqual(preferences.get(), { sidebar: { organization: "byProject", sort: "priority" } });
    await preferences.update({ sidebar: { organization: "singleList", sort: "recent" } });
    assert.deepEqual((await ClientPreferencesStore.create(storage)).get(), {
      sidebar: { organization: "singleList", sort: "recent" },
    });
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("normalizes invalid or corrupt preference files", async () => {
  const directory = await mkdtemp(path.join(tmpdir(), "relay-client-preferences-invalid-"));
  const storage = path.join(directory, "preferences.json");
  try {
    await writeFile(storage, JSON.stringify({ sidebar: { organization: "tiles", sort: "alphabetical" } }));
    const preferences = await ClientPreferencesStore.create(storage);
    assert.deepEqual(preferences.get(), { sidebar: { organization: "byProject", sort: "priority" } });
    await writeFile(storage, "not-json");
    assert.deepEqual((await ClientPreferencesStore.create(storage)).get(), {
      sidebar: { organization: "byProject", sort: "priority" },
    });
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("serializes concurrent preference updates without corrupting the file", async () => {
  const directory = await mkdtemp(path.join(tmpdir(), "relay-client-preferences-concurrent-"));
  const storage = path.join(directory, "preferences.json");
  try {
    const preferences = await ClientPreferencesStore.create(storage);
    await Promise.all([
      preferences.update({ sidebar: { organization: "singleList" } }),
      preferences.update({ sidebar: { sort: "recent" } }),
      preferences.update({ sidebar: { organization: "byProject" } }),
    ]);
    assert.deepEqual((await ClientPreferencesStore.create(storage)).get(), {
      sidebar: { organization: "byProject", sort: "recent" },
    });
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});
