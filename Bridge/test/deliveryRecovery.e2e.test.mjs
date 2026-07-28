import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createServer } from "node:net";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import WebSocket from "ws";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

test("recovers an accepted delivery exactly once after Bridge and Codex process crashes", { timeout: 45_000 }, async () => {
  const directory = await mkdtemp(path.join(tmpdir(), "relay-delivery-e2e-"));
  const port = await availablePort();
  const endpoint = `ws://127.0.0.1:${port}`;
  const token = "relay-delivery-recovery-test-token";
  const rollout = path.join(directory, "rollout.jsonl");
  const counter = path.join(directory, "count.txt");
  const codexPid = path.join(directory, "codex.pid");
  await Promise.all([writeFile(rollout, "", "utf8"), writeFile(counter, "0", "utf8")]);
  const environment = {
    ...process.env,
    RELAY_HOST: "127.0.0.1",
    RELAY_PORT: String(port),
    RELAY_ADVERTISE_URL: endpoint,
    RELAY_TOKEN: token,
    RELAY_SERVICE_VERSION: "delivery-e2e",
    RELAY_FILES_ROOT: path.join(directory, "files"),
    RELAY_DELIVERY_STORE: path.join(directory, "delivery-registry.json"),
    RELAY_DIAGNOSTICS_STORE: path.join(directory, "diagnostics.json"),
    CODEX_HOME: path.join(directory, "codex-home"),
    CODEX_BIN: path.join(root, "test", "fixtures", "fake-codex.js"),
    FAKE_CODEX_ROLLOUT: rollout,
    FAKE_CODEX_COUNTER: counter,
    FAKE_CODEX_PID: codexPid,
  };
  let bridge;
  try {
    bridge = startBridge(environment);
    await waitForHealth(port, bridge);
    const firstId = "message.bridge-crash";
    const first = sendDurable(endpoint, token, "rpc.bridge-crash", firstId).then(
      () => undefined,
      (error) => error,
    );
    await waitForCount(counter, 1);
    await killProcessTree(bridge);
    assert.ok(await first instanceof Error);

    bridge = startBridge(environment);
    await waitForHealth(port, bridge);
    await waitForDelivery(endpoint, token, firstId);
    assert.equal(await count(counter), 1, "Bridge recovery forwarded the accepted prompt twice");
    await replayDurable(endpoint, token, "rpc.bridge-replay", firstId);
    assert.equal(await count(counter), 1, "a replayed client request reached Codex twice");

    const secondId = "message.codex-crash";
    const second = sendDurable(endpoint, token, "rpc.codex-crash", secondId).then(
      () => undefined,
      (error) => error,
    );
    await waitForCount(counter, 2);
    await killPid(Number.parseInt(await readFile(codexPid, "utf8"), 10));
    assert.ok(await second instanceof Error);
    await waitForDelivery(endpoint, token, secondId);
    assert.equal(await count(counter), 2, "Codex restart recovery forwarded the accepted prompt twice");
  } finally {
    if (bridge) await killProcessTree(bridge);
    await rm(directory, { recursive: true, force: true });
  }
});

function startBridge(environment) {
  const child = spawn(process.execPath, [path.join(root, "dist", "index.js")], {
    cwd: root,
    windowsHide: true,
    detached: process.platform !== "win32",
    env: environment,
    stdio: ["ignore", "pipe", "pipe"],
  });
  child.output = "";
  child.stdout.on("data", (chunk) => { child.output += chunk.toString("utf8"); });
  child.stderr.on("data", (chunk) => { child.output += chunk.toString("utf8"); });
  return child;
}

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

function sendDurable(endpoint, token, rpcId, clientUserMessageId) {
  return rpc(endpoint, token, rpcId, "turn/start", {
    threadId: "thread.delivery-recovery",
    clientUserMessageId,
    input: [{ type: "text", text: clientUserMessageId }],
  }, 20_000);
}

async function replayDurable(endpoint, token, rpcId, clientUserMessageId) {
  const result = await sendDurable(endpoint, token, rpcId, clientUserMessageId);
  assert.equal(result.turn.id, `turn.${clientUserMessageId}`);
}

async function waitForDelivery(endpoint, token, clientUserMessageId) {
  const deadline = Date.now() + 15_000;
  while (Date.now() < deadline) {
    try {
      const status = await rpc(endpoint, token, `status.${Date.now()}`, "relay/delivery/status", {
        threadId: "thread.delivery-recovery",
        clientUserMessageId,
      }, 3_000);
      if (status.status === "completed") return;
    } catch {}
    await delay(150);
  }
  throw new Error(`Delivery ${clientUserMessageId} did not recover.`);
}

function rpc(endpoint, token, id, method, params, timeoutMs) {
  return new Promise((resolve, reject) => {
    const socket = new WebSocket(endpoint, { headers: { Authorization: `Bearer ${token}` } });
    let sent = false;
    const timer = setTimeout(() => finish(new Error(`Timed out waiting for ${method}.`)), timeoutMs);
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
    socket.on("close", () => finish(new Error(`${method} connection closed before completion.`)));
  });
}

async function waitForCount(file, expected) {
  const deadline = Date.now() + 10_000;
  while (Date.now() < deadline) {
    if (await count(file) >= expected) return;
    await delay(50);
  }
  throw new Error(`Fake Codex did not receive delivery ${expected}.`);
}

async function count(file) {
  return Number.parseInt(await readFile(file, "utf8"), 10) || 0;
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
    await runKiller("taskkill", ["/pid", String(child.pid), "/T", "/F"]);
  } else {
    try { process.kill(-child.pid, "SIGKILL"); } catch {}
  }
  await Promise.race([new Promise((resolve) => child.once("exit", resolve)), delay(3_000)]);
}

async function killPid(pid) {
  if (process.platform === "win32") await runKiller("taskkill", ["/pid", String(pid), "/F"]);
  else { try { process.kill(pid, "SIGKILL"); } catch {} }
}

function runKiller(command, args) {
  return new Promise((resolve) => {
    const killer = spawn(command, args, { windowsHide: true, stdio: "ignore" });
    killer.once("exit", resolve);
  });
}

function delay(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}
