import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createServer } from "node:net";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import WebSocket from "ws";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

test("falls back to read-only history when another Codex instance owns the thread writer", { timeout: 30_000 }, async () => {
  const directory = await mkdtemp(path.join(tmpdir(), "relay-active-writer-"));
  const rollout = path.join(directory, "rollout.jsonl");
  await writeFile(rollout, "", "utf8");
  const port = await availablePort();
  const endpoint = `ws://127.0.0.1:${port}`;
  const token = "relay-active-writer-test-token";
  const bridge = spawn(process.execPath, [path.join(root, "dist", "index.js")], {
    cwd: root,
    windowsHide: true,
    detached: process.platform !== "win32",
    env: {
      ...process.env,
      RELAY_HOST: "127.0.0.1",
      RELAY_PORT: String(port),
      RELAY_ADVERTISE_URL: endpoint,
      RELAY_TOKEN: token,
      RELAY_SERVICE_VERSION: "active-writer-test",
      RELAY_FILES_ROOT: path.join(directory, "files"),
      RELAY_DELIVERY_STORE: path.join(directory, "delivery-registry.json"),
      RELAY_DIAGNOSTICS_STORE: path.join(directory, "diagnostics.json"),
      RELAY_PROMPT_QUEUE_STORE: path.join(directory, "prompt-queue.json"),
      CODEX_HOME: path.join(directory, "codex-home"),
      CODEX_BIN: path.join(root, "test", "fixtures", "fake-active-writer-codex.js"),
      FAKE_CODEX_ROLLOUT: rollout,
    },
    stdio: ["ignore", "pipe", "pipe"],
  });
  bridge.output = "";
  bridge.stdout.on("data", (chunk) => { bridge.output += chunk.toString("utf8"); });
  bridge.stderr.on("data", (chunk) => { bridge.output += chunk.toString("utf8"); });

  try {
    await waitForHealth(port, bridge);
    const result = await rpc(endpoint, token, "resume", "thread/resume", {
      threadId: "thread.active-writer",
      excludeTurns: true,
      initialTurnsPage: { limit: 8, sortDirection: "desc", itemsView: "full" },
    });
    assert.equal(result.relayThreadAccess?.mode, "external-read-only");
    assert.equal(result.relayThreadAccess?.reason, "active-writer");
    assert.equal(result.thread?.id, "thread.active-writer");
    assert.equal(result.initialTurnsPage?.data?.[0]?.id, "turn.active-writer");
    assert.equal(result.initialTurnsPage?.nextCursor, "older.cursor");
  } finally {
    await killProcessTree(bridge);
    await rm(directory, { recursive: true, force: true });
  }
});

async function waitForHealth(port, bridge) {
  const deadline = Date.now() + 15_000;
  while (Date.now() < deadline) {
    if (bridge.exitCode !== null) throw new Error(`Bridge exited unexpectedly:\n${bridge.output}`);
    try {
      const response = await fetch(`http://127.0.0.1:${port}/health`);
      if (response.ok) return;
    } catch {}
    await delay(100);
  }
  throw new Error(`Bridge did not become ready:\n${bridge.output}`);
}

function rpc(endpoint, token, id, method, params) {
  return new Promise((resolve, reject) => {
    const socket = new WebSocket(endpoint, { headers: { Authorization: `Bearer ${token}` } });
    let sent = false;
    const timer = setTimeout(() => finish(new Error(`Timed out waiting for ${method}.`)), 15_000);
    const finish = (error, result) => {
      clearTimeout(timer);
      socket.close();
      if (error) reject(error); else resolve(result);
    };
    socket.on("message", (data) => {
      const message = JSON.parse(data.toString("utf8"));
      if (!sent && message.type === "bridgeStatus" && message.status === "ready") {
        sent = true;
        socket.send(JSON.stringify({ type: "rpc", id, method, params }));
      } else if (message.type === "rpcResult" && message.id === id) {
        if (message.error) finish(new Error(message.error.message ?? `${method} failed`));
        else finish(undefined, message.result);
      }
    });
    socket.on("error", finish);
  });
}

async function availablePort() {
  const server = createServer();
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const address = server.address();
  const port = typeof address === "object" && address ? address.port : 0;
  await new Promise((resolve) => server.close(resolve));
  return port;
}

async function killProcessTree(child) {
  if (!child.pid || child.exitCode !== null) return;
  if (process.platform === "win32") {
    await new Promise((resolve) => {
      const killer = spawn("taskkill", ["/pid", String(child.pid), "/T", "/F"], { windowsHide: true, stdio: "ignore" });
      killer.once("exit", resolve);
    });
  } else {
    try { process.kill(-child.pid, "SIGKILL"); } catch {}
  }
  await Promise.race([new Promise((resolve) => child.once("exit", resolve)), delay(3_000)]);
}

function delay(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}
