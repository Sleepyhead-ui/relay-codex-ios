import { spawn } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";
import WebSocket from "ws";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const token = "relay-integration-test-token-00000000";
const endpoint = "ws://127.0.0.1:8876";
const bridge = spawn(process.execPath, [path.join(root, "dist", "index.js")], {
  cwd: root,
  windowsHide: true,
  env: {
    ...process.env,
    RELAY_HOST: "127.0.0.1",
    RELAY_PORT: "8876",
    RELAY_ADVERTISE_URL: endpoint,
    RELAY_TOKEN: token,
  },
  stdio: ["ignore", "pipe", "pipe"],
});

let output = "";
bridge.stdout.on("data", (chunk) => { output += chunk.toString("utf8"); });
bridge.stderr.on("data", (chunk) => { output += chunk.toString("utf8"); });

try {
  await waitForHealth();
  const result = await listThreads();
  if (!Array.isArray(result.data)) throw new Error("thread/list returned an unexpected payload.");
  console.log(`Relay integration OK; received ${result.data.length} thread(s).`);
} catch (error) {
  console.error(output);
  throw error;
} finally {
  bridge.kill();
}

async function waitForHealth() {
  const deadline = Date.now() + 25_000;
  while (Date.now() < deadline) {
    if (bridge.exitCode !== null) throw new Error(`Bridge exited with code ${bridge.exitCode}.`);
    try {
      const response = await fetch("http://127.0.0.1:8876/health");
      if (response.ok) return;
    } catch {}
    await new Promise((resolve) => setTimeout(resolve, 350));
  }
  throw new Error("Timed out waiting for Relay Bridge.");
}

function listThreads() {
  return new Promise((resolve, reject) => {
    const socket = new WebSocket(endpoint, { headers: { Authorization: `Bearer ${token}` } });
    const timer = setTimeout(() => reject(new Error("Timed out waiting for thread/list.")), 15_000);
    socket.on("message", (data) => {
      const message = JSON.parse(data.toString("utf8"));
      if (message.type === "bridgeStatus" && message.status === "ready") {
        socket.send(JSON.stringify({ type: "rpc", id: "e2e.list", method: "thread/list", params: { limit: 1 } }));
      }
      if (message.type === "rpcResult" && message.id === "e2e.list") {
        clearTimeout(timer);
        socket.close();
        if (message.error) reject(new Error(message.error.message ?? "thread/list failed"));
        else resolve(message.result);
      }
    });
    socket.on("error", (error) => {
      clearTimeout(timer);
      reject(error);
    });
  });
}

