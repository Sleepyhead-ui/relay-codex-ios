import { spawn } from "node:child_process";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import WebSocket from "ws";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const token = "relay-integration-test-token-00000000";
const endpoint = "ws://127.0.0.1:8876";
const filesRoot = await mkdtemp(path.join(tmpdir(), "relay-e2e-"));
const bridge = spawn(process.execPath, [path.join(root, "dist", "index.js")], {
  cwd: root,
  windowsHide: true,
  env: {
    ...process.env,
    RELAY_HOST: "127.0.0.1",
    RELAY_PORT: "8876",
    RELAY_ADVERTISE_URL: endpoint,
    RELAY_TOKEN: token,
    RELAY_FILES_ROOT: filesRoot,
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
  const models = await listModels();
  if (!Array.isArray(models.data) || models.data.length === 0) throw new Error("model/list returned an unexpected payload.");
  const firstModel = models.data[0];
  if (!firstModel.model || !Array.isArray(firstModel.supportedReasoningEfforts)) {
    throw new Error("model/list did not include model or reasoning effort metadata.");
  }
  const upload = await rpc("e2e.upload.start", "relay/file/upload/start", { name: "e2e.txt", size: 9 });
  await rpc("e2e.upload.chunk", "relay/file/upload/chunk", { uploadId: upload.uploadId, index: 0, data: Buffer.from("relay-e2e").toString("base64") });
  const uploaded = await rpc("e2e.upload.finish", "relay/file/upload/finish", { uploadId: upload.uploadId });
  const download = await rpc("e2e.download.start", "relay/file/download/start", { path: uploaded.path });
  const downloaded = await rpc("e2e.download.chunk", "relay/file/download/chunk", { downloadId: download.downloadId, index: 0 });
  if (Buffer.from(downloaded.data, "base64").toString("utf8") !== "relay-e2e") throw new Error("file transfer content mismatch");
  console.log(`Relay integration OK; received ${result.data.length} thread(s), ${models.data.length} model(s), and transferred a file.`);
} catch (error) {
  console.error(output);
  throw error;
} finally {
  bridge.kill();
  await rm(filesRoot, { recursive: true, force: true });
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
  return rpc("e2e.list", "thread/list", { limit: 1 });
}

function listModels() {
  return rpc("e2e.models", "model/list", { limit: 100, includeHidden: false });
}

function rpc(id, method, params) {
  return new Promise((resolve, reject) => {
    const socket = new WebSocket(endpoint, { headers: { Authorization: `Bearer ${token}` } });
    let accepted = false;
    const timer = setTimeout(() => reject(new Error(`Timed out waiting for ${method}.`)), 15_000);
    socket.on("message", (data) => {
      const message = JSON.parse(data.toString("utf8"));
      if (message.type === "bridgeStatus" && message.status === "ready") {
        socket.send(JSON.stringify({ type: "rpc", id, method, params }));
      }
      if (message.type === "rpcAccepted" && message.id === id && message.method === method) {
        accepted = true;
      }
      if (message.type === "rpcResult" && message.id === id) {
        clearTimeout(timer);
        socket.close();
        if (!accepted) {
          reject(new Error(`${method} completed without an rpcAccepted acknowledgement.`));
          return;
        }
        if (message.error) reject(new Error(message.error.message ?? `${method} failed`));
        else resolve(message.result);
      }
    });
    socket.on("error", (error) => {
      clearTimeout(timer);
      reject(error);
    });
  });
}
