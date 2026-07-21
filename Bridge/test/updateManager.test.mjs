import test from "node:test";
import assert from "node:assert/strict";
import { compareVersions, selectIPAAsset } from "../dist/updateManager.js";

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
