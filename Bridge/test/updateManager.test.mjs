import test from "node:test";
import assert from "node:assert/strict";
import { compareVersions, selectDigestAsset, selectIPAAsset } from "../dist/updateManager.js";

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
