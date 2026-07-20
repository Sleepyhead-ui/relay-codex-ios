import { createServer } from "node:http";
import { WebSocketServer, WebSocket } from "ws";
import qrcode from "qrcode-terminal";
import { CodexAppServer } from "./codexAppServer.js";
import { CodexProfileRegistry, type CodexProfile } from "./codexProfiles.js";
import { loadConfig } from "./config.js";
import { DesktopSync } from "./desktopSync.js";
import { FileTransferManager } from "./fileTransfer.js";
import { isAuthorized, isObject, parseClientMessage, type JsonObject } from "./protocol.js";
import { RuntimeStateTracker } from "./runtimeState.js";
import { SessionActivityTracker } from "./sessionActivity.js";

interface PendingClientRequest {
  socket: WebSocket;
  clientId: string;
  method: string;
  params: JsonObject;
}

async function main(): Promise<void> {
const codexProfiles = await CodexProfileRegistry.create();
const config = await loadConfig(codexProfiles.activeCodexHome);
const clients = new Set<WebSocket>();
const clientLiveness = new WeakMap<WebSocket, boolean>();
const sessionSubscriptions = new WeakMap<WebSocket, Map<string, () => void>>();
const socketDiagnostics = {
  lastConnectedAt: null as string | null,
  lastDisconnectedAt: null as string | null,
  lastRejectedAt: null as string | null,
  lastErrorAt: null as string | null,
  lastRemoteAddress: null as string | null,
  lastClose: null as string | null,
  lastError: null as string | null,
};
const rpcDiagnostics = {
  lastReceivedAt: null as string | null,
  lastAcceptedAt: null as string | null,
  lastCompletedAt: null as string | null,
  lastMethod: null as string | null,
  lastCompletedMethod: null as string | null,
  lastErrorAt: null as string | null,
  lastError: null as string | null,
};
const pendingClientRequests = new Map<string, PendingClientRequest>();
const pendingServerRequests = new Map<string, JsonObject>();
let nextRequestId = 1;
let codexReady = false;
let codexGeneration = 1;
let activeCodexProfile = (await codexProfiles.list()).find((profile) => profile.active)!;
const desktopSync = new DesktopSync(
  config.desktopSync,
  config.desktopCdpPort,
  config.desktopAppPath,
  (message) => console.log(`[desktop] ${message}`),
  (status) => broadcast(bridgeStatus(codexReady ? "ready" : "starting", status)),
);
const fileTransfer = new FileTransferManager(config.defaultCwd, config.filesRoot);
let runtimeState = new RuntimeStateTracker();
let sessionActivity = new SessionActivityTracker();

let codex = createCodexAppServer(codexGeneration);

await codex.start();

const httpServer = createServer((request, response) => {
  if (request.url === "/health") {
    response.writeHead(codexReady ? 200 : 503, { "content-type": "application/json" });
    response.end(JSON.stringify({
      status: codexReady ? "ready" : "starting",
      clients: clients.size,
      uptimeSeconds: Math.floor(process.uptime()),
      activeTurns: runtimeState.activeCount,
      pendingRpcCount: pendingClientRequests.size,
      socket: socketDiagnostics,
      rpc: rpcDiagnostics,
      desktopSync: desktopSync.status,
      codexProfile: activeCodexProfile,
    }));
    return;
  }
  response.writeHead(404).end();
});

const webSocketServer = new WebSocketServer({ noServer: true, maxPayload: 2 * 1024 * 1024 });

httpServer.on("upgrade", (request, socket, head) => {
  socketDiagnostics.lastRemoteAddress = request.socket.remoteAddress ?? null;
  if (request.headers.origin) {
    socketDiagnostics.lastRejectedAt = new Date().toISOString();
    socketDiagnostics.lastError = "WebSocket origin header was rejected.";
    socket.write("HTTP/1.1 403 Forbidden\r\nConnection: close\r\n\r\n");
    socket.destroy();
    return;
  }
  if (!isAuthorized(request.headers.authorization, config.token)) {
    socketDiagnostics.lastRejectedAt = new Date().toISOString();
    socketDiagnostics.lastError = "WebSocket authorization failed.";
    socket.write("HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n");
    socket.destroy();
    return;
  }
  webSocketServer.handleUpgrade(request, socket, head, (webSocket) => {
    webSocketServer.emit("connection", webSocket, request);
  });
});

webSocketServer.on("connection", (socket) => {
  clients.add(socket);
  clientLiveness.set(socket, true);
  sessionSubscriptions.set(socket, new Map());
  socketDiagnostics.lastConnectedAt = new Date().toISOString();
  socketDiagnostics.lastError = null;
  console.log(`[socket] mobile client connected (${clients.size} total)`);
  send(socket, bridgeStatus(codexReady ? "ready" : "starting"));
  for (const request of pendingServerRequests.values()) {
    send(socket, { type: "serverRequest", ...request });
  }

  socket.on("message", (data, isBinary) => {
    if (isBinary) {
      sendError(socket, "Binary messages are not supported.");
      return;
    }
    try {
      void handleClientMessage(socket, data.toString("utf8")).catch((error) => {
        sendError(socket, error instanceof Error ? error.message : "Invalid message.");
      });
    } catch (error) {
      sendError(socket, error instanceof Error ? error.message : "Invalid message.");
    }
  });
  socket.on("pong", () => clientLiveness.set(socket, true));
  socket.on("close", (code, reason) => {
    for (const stop of sessionSubscriptions.get(socket)?.values() ?? []) stop();
    sessionSubscriptions.delete(socket);
    clients.delete(socket);
    clientLiveness.delete(socket);
    socketDiagnostics.lastDisconnectedAt = new Date().toISOString();
    socketDiagnostics.lastClose = `${code}${reason.length ? `: ${reason.toString("utf8")}` : ""}`;
    console.log(`[socket] mobile client disconnected (${clients.size} total)`);
  });
  socket.on("error", (error) => {
    socketDiagnostics.lastErrorAt = new Date().toISOString();
    socketDiagnostics.lastError = error.message;
    console.error(`[socket] ${error.message}`);
  });
});

const heartbeatInterval = setInterval(() => {
  for (const client of clients) {
    if (clientLiveness.get(client) === false) {
      client.terminate();
      continue;
    }
    clientLiveness.set(client, false);
    client.ping();
  }
}, 30_000);

httpServer.listen(config.port, config.host, () => {
  const pairingUrl = new URL("relay://connect");
  pairingUrl.searchParams.set("url", config.advertiseUrl);
  pairingUrl.searchParams.set("token", config.token);

  console.log(`Relay Bridge listening on ${config.host}:${config.port}`);
  console.log(`Advertised mobile URL: ${config.advertiseUrl}`);
  console.log(`Desktop sync: ${desktopSync.enabled ? "enabled" : "disabled"}`);
  console.log("Scan this QR code with the iPhone Camera after installing Relay:");
  qrcode.generate(pairingUrl.toString(), { small: true });
  console.log(`Manual token: ${config.token}`);
});

async function handleClientMessage(socket: WebSocket, raw: string): Promise<void> {
  const message = parseClientMessage(raw);
  if (message.type === "rpc") {
    rpcDiagnostics.lastReceivedAt = new Date().toISOString();
    rpcDiagnostics.lastMethod = message.method;
    if (message.method === "relay/thread/runtime") {
      send(socket, { type: "rpcAccepted", id: message.id, method: message.method });
      rpcDiagnostics.lastAcceptedAt = new Date().toISOString();
      const result = await runtimeState.snapshotWithExternal(message.params.threadId, sessionActivity);
      send(socket, { type: "rpcResult", id: message.id, result });
      rpcDiagnostics.lastCompletedAt = new Date().toISOString();
      rpcDiagnostics.lastCompletedMethod = message.method;
      return;
    }
    if (message.method === "relay/codex/profiles/list") {
      send(socket, { type: "rpcAccepted", id: message.id, method: message.method });
      rpcDiagnostics.lastAcceptedAt = new Date().toISOString();
      const profiles = await codexProfiles.list();
      activeCodexProfile = profiles.find((profile) => profile.active) ?? activeCodexProfile;
      send(socket, { type: "rpcResult", id: message.id, result: { profiles, activeProfileId: activeCodexProfile.id } });
      rpcDiagnostics.lastCompletedAt = new Date().toISOString();
      rpcDiagnostics.lastCompletedMethod = message.method;
      return;
    }
    if (message.method === "relay/codex/profiles/switch") {
      send(socket, { type: "rpcAccepted", id: message.id, method: message.method });
      rpcDiagnostics.lastAcceptedAt = new Date().toISOString();
      try {
        const profile = await switchCodexProfile(message.params.profileId);
        send(socket, { type: "rpcResult", id: message.id, result: { profile } });
        rpcDiagnostics.lastCompletedAt = new Date().toISOString();
        rpcDiagnostics.lastCompletedMethod = message.method;
      } catch (error) {
        rpcDiagnostics.lastErrorAt = new Date().toISOString();
        rpcDiagnostics.lastError = error instanceof Error ? error.message : "Could not switch Codex instances.";
        send(socket, { type: "rpcResult", id: message.id, error: { message: rpcDiagnostics.lastError } });
      }
      return;
    }
    if (message.method === "relay/thread/session/snapshot") {
      send(socket, { type: "rpcAccepted", id: message.id, method: message.method });
      rpcDiagnostics.lastAcceptedAt = new Date().toISOString();
      const result = await sessionActivity.turnSnapshot(message.params.threadId);
      send(socket, { type: "rpcResult", id: message.id, result });
      rpcDiagnostics.lastCompletedAt = new Date().toISOString();
      rpcDiagnostics.lastCompletedMethod = message.method;
      return;
    }
    if (message.method === "relay/thread/session/subscribe") {
      send(socket, { type: "rpcAccepted", id: message.id, method: message.method });
      rpcDiagnostics.lastAcceptedAt = new Date().toISOString();
      try {
        const threadId = String(message.params.threadId ?? "");
        const subscriptions = sessionSubscriptions.get(socket);
        subscriptions?.get(threadId)?.();
        const stop = sessionActivity.subscribe(threadId, (snapshot) => {
          send(socket, { type: "sessionSnapshot", threadId, snapshot });
        });
        subscriptions?.set(threadId, stop);
        const result = await sessionActivity.turnSnapshot(threadId);
        send(socket, { type: "rpcResult", id: message.id, result });
        rpcDiagnostics.lastCompletedAt = new Date().toISOString();
        rpcDiagnostics.lastCompletedMethod = message.method;
      } catch (error) {
        send(socket, { type: "rpcResult", id: message.id, error: { message: error instanceof Error ? error.message : "Could not watch the session." } });
      }
      return;
    }
    if (message.method === "relay/thread/session/unsubscribe") {
      send(socket, { type: "rpcAccepted", id: message.id, method: message.method });
      rpcDiagnostics.lastAcceptedAt = new Date().toISOString();
      const threadId = String(message.params.threadId ?? "");
      const subscriptions = sessionSubscriptions.get(socket);
      subscriptions?.get(threadId)?.();
      subscriptions?.delete(threadId);
      send(socket, { type: "rpcResult", id: message.id, result: {} });
      rpcDiagnostics.lastCompletedAt = new Date().toISOString();
      rpcDiagnostics.lastCompletedMethod = message.method;
      return;
    }
    if (message.method.startsWith("relay/")) {
      send(socket, { type: "rpcAccepted", id: message.id, method: message.method });
      rpcDiagnostics.lastAcceptedAt = new Date().toISOString();
      try {
        const result = await fileTransfer.handle(message.method, message.params);
        send(socket, { type: "rpcResult", id: message.id, result });
        rpcDiagnostics.lastCompletedAt = new Date().toISOString();
        rpcDiagnostics.lastCompletedMethod = message.method;
      } catch (error) {
        rpcDiagnostics.lastErrorAt = new Date().toISOString();
        rpcDiagnostics.lastError = error instanceof Error ? error.message : "File transfer failed.";
        send(socket, {
          type: "rpcResult",
          id: message.id,
          error: { message: error instanceof Error ? error.message : "File transfer failed." },
        });
      }
      return;
    }
    if (!codexReady) {
      rpcDiagnostics.lastErrorAt = new Date().toISOString();
      rpcDiagnostics.lastError = "Codex is still starting.";
      send(socket, {
        type: "rpcResult",
        id: message.id,
        error: { message: "Codex is still starting." },
      });
      return;
    }
    const bridgeId = `relay.${nextRequestId++}`;
    const params = { ...message.params };
    if (message.method === "thread/start" && config.defaultCwd && !("cwd" in params)) {
      params.cwd = config.defaultCwd;
    }
    pendingClientRequests.set(bridgeId, { socket, clientId: message.id, method: message.method, params });
    try {
      codex.send({ method: message.method, id: bridgeId, params });
      send(socket, { type: "rpcAccepted", id: message.id, method: message.method });
      rpcDiagnostics.lastAcceptedAt = new Date().toISOString();
    } catch (error) {
      pendingClientRequests.delete(bridgeId);
      rpcDiagnostics.lastErrorAt = new Date().toISOString();
      rpcDiagnostics.lastError = error instanceof Error ? error.message : "Could not forward RPC to Codex.";
      send(socket, {
        type: "rpcResult",
        id: message.id,
        error: { message: rpcDiagnostics.lastError },
      });
    }
    return;
  }

  const serverId = String(message.id);
  if (!pendingServerRequests.has(serverId)) return;
  pendingServerRequests.delete(serverId);
  const response: JsonObject = { id: message.id };
  if (message.error) response.error = message.error;
  else response.result = message.result ?? {};
  codex.send(response);
  broadcast({ type: "serverRequestResolved", id: message.id });
}

function handleCodexResponse(message: JsonObject): void {
  const id = String(message.id);
  const pending = pendingClientRequests.get(id);
  if (!pending) return;
  pendingClientRequests.delete(id);
  rpcDiagnostics.lastCompletedAt = new Date().toISOString();
  rpcDiagnostics.lastCompletedMethod = pending.method;
  if ("error" in message) {
    rpcDiagnostics.lastErrorAt = rpcDiagnostics.lastCompletedAt;
    rpcDiagnostics.lastError = isObject(message.error) && typeof message.error.message === "string"
      ? message.error.message
      : "Codex RPC failed.";
  } else {
    rpcDiagnostics.lastError = null;
  }
  const payload: JsonObject = { type: "rpcResult", id: pending.clientId };
  if ("result" in message) payload.result = message.result;
  if ("error" in message) payload.error = message.error;
  send(pending.socket, payload);
  if (pending.method === "thread/list" && "result" in message) {
    sessionActivity.observeThreadList(message.result);
  } else if (pending.method === "thread/resume" && "result" in message) {
    sessionActivity.observeThreadResume(message.result);
  }
  if (pending.method === "turn/start" && !("error" in message)) {
    const result = isObject(message.result) ? message.result : {};
    runtimeState.observeTurnStart(pending.params.threadId, result.turn);
    desktopSync.activateThread(pending.params.threadId, "turn-started");
  }
  if (pending.method === "turn/steer" && !("error" in message)) {
    const result = isObject(message.result) ? message.result : {};
    runtimeState.observeTurnStart(pending.params.threadId, { id: result.turnId });
    desktopSync.activateThread(pending.params.threadId, "turn-steered");
  }
}

function handleCodexNotification(message: JsonObject): void {
  runtimeState.observeNotification(message);
  broadcast({ type: "event", ...message });
  if (message.method === "turn/completed" && isObject(message.params)) {
    desktopSync.activateThread(message.params.threadId, "turn-completed");
  }
}

function handleCodexRequest(message: JsonObject): void {
  const id = String(message.id);
  pendingServerRequests.set(id, message);
  broadcast({ type: "serverRequest", ...message });
}

function broadcast(message: JsonObject): void {
  for (const client of clients) send(client, message);
}

function send(socket: WebSocket, message: JsonObject): void {
  if (socket.readyState === WebSocket.OPEN) socket.send(JSON.stringify(message));
}

function sendError(socket: WebSocket, message: string): void {
  send(socket, { type: "bridgeError", message });
}

function bridgeStatus(status: string, sync = desktopSync.status): JsonObject {
  return { type: "bridgeStatus", status, desktopSync: sync, codexProfile: activeCodexProfile };
}

function createCodexAppServer(generation: number): CodexAppServer {
  return new CodexAppServer(config.codexBin, {
    onResponse: (message) => {
      if (generation === codexGeneration) handleCodexResponse(message);
    },
    onNotification: (message) => {
      if (generation === codexGeneration) handleCodexNotification(message);
    },
    onRequest: (message) => {
      if (generation === codexGeneration) handleCodexRequest(message);
    },
    onLog: (message) => {
      if (generation !== codexGeneration) return;
      if (message) console.log(`[codex] ${message}`);
      if (message.includes("initialized")) {
        codexReady = true;
        broadcast(bridgeStatus("ready"));
      }
    },
    onExit: (code, signal) => {
      if (generation !== codexGeneration) return;
      codexReady = false;
      broadcast({ ...bridgeStatus("codexExited"), code, signal });
      console.error(`Codex App Server exited (code=${code}, signal=${signal}). Restart Relay Bridge.`);
    },
  }, { CODEX_HOME: codexProfiles.activeCodexHome });
}

async function switchCodexProfile(profileId: unknown): Promise<CodexProfile> {
  if (runtimeState.activeCount > 0) throw new Error("任务运行期间不能切换 Codex 实例，请先等待完成或停止任务。");
  if (pendingClientRequests.size > 0) throw new Error("仍有请求正在处理，请稍后再切换 Codex 实例。");
  if (pendingServerRequests.size > 0) throw new Error("请先处理当前审批，再切换 Codex 实例。");

  const available = await codexProfiles.list();
  const requested = available.find((profile) => profile.id === profileId);
  if (!requested) throw new Error("找不到所选 Codex 实例，请刷新后重试。");
  if (requested.active) return requested;

  activeCodexProfile = await codexProfiles.select(profileId);
  codexReady = false;
  broadcast(bridgeStatus("switching"));
  for (const client of clients) {
    for (const stop of sessionSubscriptions.get(client)?.values() ?? []) stop();
    sessionSubscriptions.set(client, new Map());
  }
  sessionActivity.dispose();
  sessionActivity = new SessionActivityTracker();
  runtimeState = new RuntimeStateTracker();

  const previous = codex;
  codexGeneration += 1;
  await previous.stop();
  codex = createCodexAppServer(codexGeneration);
  await codex.start();
  return activeCodexProfile;
}

function shutdown(): void {
  clearInterval(heartbeatInterval);
  for (const client of clients) client.close(1001, "Bridge shutting down");
  sessionActivity.dispose();
  void codex.stop();
  httpServer.close(() => process.exit(0));
}

process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);
}

void main().catch((error) => {
  console.error(error instanceof Error ? error.stack ?? error.message : error);
  process.exit(1);
});
