import assert from "node:assert/strict";
import { mkdtemp, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { BarkPushNotifier, cleanPreview, ExternalCompletionTracker, normalizeBarkEndpoint } from "../dist/pushNotifications.js";

test("normalizes a copied public Bark test URL to its device endpoint", () => {
  assert.equal(
    normalizeBarkEndpoint("https://api.day.app/device-key/测试内容?group=old").toString(),
    "https://api.day.app/device-key",
  );
});

test("keeps task content private by default and includes a Relay deep link", async () => {
  const directory = await mkdtemp(path.join(os.tmpdir(), "relay-push-"));
  const preferencesPath = path.join(directory, "preferences.json");
  await writeFile(preferencesPath, JSON.stringify({
    remoteNotifications: true,
    barkUrl: "https://api.day.app/device-key",
    pushIncludePreview: false,
  }));
  const requests = [];
  const notifier = new BarkPushNotifier(preferencesPath, undefined, async (url, init) => {
    requests.push({ url: String(url), body: JSON.parse(String(init?.body)) });
    return new Response(JSON.stringify({ code: 200 }), { status: 200 });
  });

  assert.equal(await notifier.sendTaskCompletion({
    turnId: "turn.1",
    threadId: "thread.1",
    failed: false,
    taskTitle: "Sensitive project",
    preview: "Sensitive final answer",
  }), true);
  assert.equal(await notifier.sendTaskCompletion({
    turnId: "turn.1",
    threadId: "thread.1",
    failed: false,
  }), false);
  assert.equal(requests.length, 1);
  assert.equal(requests[0].url, "https://api.day.app/device-key");
  assert.equal(requests[0].body.body, "任务已处理完毕");
  assert.match(requests[0].body.url, /^relay:\/\/thread\?threadId=thread\.1$/);
});

test("preview cleanup removes thinking and markdown", () => {
  assert.equal(
    cleanPreview("<thinking>hidden</thinking> **完成** [`file.ts`](https://example.com)"),
    "完成 file.ts",
  );
});

test("detects observed and skipped running-to-terminal external transitions", () => {
  const tracker = new ExternalCompletionTracker(1_000);
  assert.equal(tracker.observe("thread.1", { known: true, turnId: "old", isRunning: false }), false);
  assert.equal(tracker.observe("thread.1", { known: true, turnId: "current", isRunning: true }), false);
  assert.equal(tracker.observe("thread.1", { known: true, turnId: "other", isRunning: false }), true);
  assert.equal(tracker.observe("thread.1", { known: true, turnId: "next", isRunning: true }), false);
  assert.equal(tracker.observe("thread.1", { known: true, turnId: "next", isRunning: false }), true);
  assert.equal(tracker.observe("thread.1", { known: true, turnId: "next", isRunning: false }), false);
});

test("detects a short external turn completed between polls", () => {
  const tracker = new ExternalCompletionTracker(1_000);
  assert.equal(tracker.observe("thread.1", {
    known: true,
    turnId: "current",
    isRunning: false,
    completedAt: 1_001,
  }), true);
  assert.equal(tracker.observe("thread.2", {
    known: true,
    turnId: "historical",
    isRunning: false,
    completedAt: 999,
  }), false);
});

test("retries a failed external completion transition", () => {
  const tracker = new ExternalCompletionTracker(1_000);
  assert.equal(tracker.observe("thread.1", { known: true, turnId: "current", isRunning: true }), false);
  assert.equal(tracker.observe("thread.1", { known: true, turnId: "current", isRunning: false }), true);
  tracker.retry("thread.1", "current");
  assert.equal(tracker.observe("thread.1", { known: true, turnId: "current", isRunning: false }), true);
});

test("coalesces concurrent notifications for the same turn", async () => {
  const directory = await mkdtemp(path.join(os.tmpdir(), "relay-push-"));
  const preferencesPath = path.join(directory, "preferences.json");
  await writeFile(preferencesPath, JSON.stringify({
    remoteNotifications: true,
    barkUrl: "https://api.day.app/device-key",
    pushIncludePreview: false,
  }));
  let requestCount = 0;
  let releaseRequest;
  const waitForRelease = new Promise((resolve) => { releaseRequest = resolve; });
  const notifier = new BarkPushNotifier(preferencesPath, undefined, async () => {
    requestCount += 1;
    await waitForRelease;
    return new Response(JSON.stringify({ code: 200 }), { status: 200 });
  });
  const message = { turnId: "turn.1", threadId: "thread.1", failed: false };
  const first = notifier.sendTaskCompletion(message);
  const second = notifier.sendTaskCompletion(message);
  releaseRequest();
  assert.deepEqual(await Promise.all([first, second]), [true, false]);
  assert.equal(requestCount, 1);
});
