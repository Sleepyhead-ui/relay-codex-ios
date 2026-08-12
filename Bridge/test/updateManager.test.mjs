import test from "node:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { UpdateManager, compareVersions, releaseAssetUrls, selectDigestAsset, selectIPAAsset } from "../dist/updateManager.js";

test("compares semantic release versions numerically", () => {
  assert.equal(compareVersions("0.7.0", "v0.6.23"), 1);
  assert.equal(compareVersions("v0.6.23", "0.6.23"), 0);
  assert.equal(compareVersions("0.6.9", "0.6.10"), -1);
});

test("accepts only the fixed repository IPA asset", () => {
  const valid = { name: "Relay.ipa", size: 1, browser_download_url: "https://github.com/Sleepyhead-ui/relay-codex-ios/releases/download/v1/Relay.ipa" };
  const foreign = { name: "Relay.ipa", size: 1, browser_download_url: "https://example.com/Relay.ipa" };
  assert.equal(selectIPAAsset([foreign, valid]), valid);
  assert.equal(selectIPAAsset([foreign]), undefined);
});

test("accepts only a small digest asset from the fixed repository", () => {
  const valid = { name: "Relay.ipa.sha256", size: 76, browser_download_url: "https://github.com/Sleepyhead-ui/relay-codex-ios/releases/download/v1/Relay.ipa.sha256" };
  const oversized = { ...valid, size: 1024 };
  const foreign = { ...valid, browser_download_url: "https://example.com/Relay.ipa.sha256" };
  assert.equal(selectDigestAsset([foreign, oversized, valid]), valid);
  assert.equal(selectDigestAsset([foreign, oversized]), undefined);
});

test("prefers the fixed GitHub API asset endpoint before the browser download", () => {
  const asset = { id: 123, name: "Relay.ipa", size: 1, browser_download_url: "https://github.com/Sleepyhead-ui/relay-codex-ios/releases/download/v1/Relay.ipa" };
  assert.deepEqual(releaseAssetUrls(asset), [
    "https://api.github.com/repos/Sleepyhead-ui/relay-codex-ios/releases/assets/123",
    asset.browser_download_url,
  ]);
  assert.deepEqual(releaseAssetUrls({ ...asset, id: undefined, browser_download_url: "https://example.com/Relay.ipa" }), []);
});

test("shares one in-flight IPA download between concurrent callers", async (t) => {
  const root = await mkdtemp(path.join(tmpdir(), "relay-update-"));
  t.after(() => rm(root, { recursive: true, force: true }));
  const bytes = Buffer.from("relay-test-ipa");
  const digest = createHash("sha256").update(bytes).digest("hex");
  const ipaUrl = "https://github.com/Sleepyhead-ui/relay-codex-ios/releases/download/v9.9.9/Relay.ipa";
  const digestUrl = "https://github.com/Sleepyhead-ui/relay-codex-ios/releases/download/v9.9.9/Relay.ipa.sha256";
  const release = {
    tag_name: "v9.9.9",
    html_url: "https://github.com/Sleepyhead-ui/relay-codex-ios/releases/tag/v9.9.9",
    published_at: new Date().toISOString(),
    assets: [
      { id: 1, name: "Relay.ipa", size: bytes.length, browser_download_url: ipaUrl },
      { id: 2, name: "Relay.ipa.sha256", size: 75, browser_download_url: digestUrl },
    ],
  };
  const originalFetch = globalThis.fetch;
  let releaseCalls = 0;
  let ipaCalls = 0;
  globalThis.fetch = async (input) => {
    const url = String(input);
    if (url.endsWith("/releases/latest")) {
      releaseCalls += 1;
      await new Promise((resolve) => setTimeout(resolve, 10));
      return new Response(JSON.stringify(release), { status: 200 });
    }
    if (url.includes("/releases/assets/2")) return new Response(`${digest}  Relay.ipa\n`, { status: 200 });
    if (url.includes("/releases/assets/1")) {
      ipaCalls += 1;
      await new Promise((resolve) => setTimeout(resolve, 20));
      return new Response(bytes, { status: 200 });
    }
    throw new Error(`Unexpected fetch: ${url}`);
  };
  t.after(() => { globalThis.fetch = originalFetch; });

  const manager = new UpdateManager(root);
  const [first, second] = await Promise.all([manager.downloadIOS(), manager.downloadIOS()]);
  assert.deepEqual(first, second);
  assert.equal(releaseCalls, 1);
  assert.equal(ipaCalls, 1);
});
