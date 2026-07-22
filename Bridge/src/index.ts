import { createServer } from "node:http";
import { WebSocketServer, WebSocket } from "ws";
import qrcode from "qrcode-terminal";
import { CodexAppServer } from "./codexAppServer.js";
import { resolveCodexExecutable } from "./codexExecutable.js";
import { CodexProfileRegistry, type CodexProfile } from "./codexProfiles.js";
import { loadConfig } from "./config.js";
import { DesktopSync } from "./desktopSync.js";
import { DiagnosticsLog } from "./diagnostics.js";
import { FileTransferManager } from "./fileTransfer.js";
import { GoalStore } from "./goalStore.js";
import { PerformanceMetrics } from "./performanceMetrics.js";
import { isAuthorized, isObject, parseClientMessage, type JsonObject } from "./protocol.js";
import { PromptQueue } from "./promptQueue.js";
import { RequestLifecycle } from "./requestLifecycle.js";
import { RuntimeStateTracker } from "./runtimeState.js";
import { SessionActivityTracker } from "./sessionActivity.js";
import { SessionPatchCursor } from "./sessionPatch.js";
import { UpdateManager } from "./updateManager.js";

interface PendingServerRequest {
  request: JsonObject;
  timeout: NodeJS.Timeout;
}

interface PendingInternalRequest {
  method: string;
  resolve: (value: JsonObject) => void;
  reject: (error: Error) => void;
  timeout: NodeJS.Timeout;
}

const defaultRpcTimeoutMs = 2 * 60_000;
const historyRpcTimeoutMs = 10 * 60_000;
const approvalTimeoutMs = 30 * 60_000;

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
const diagnostics = new DiagnosticsLog();
const performanceMetrics = new PerformanceMetrics();
const rpcStartedAt = new Map<string, number>();
diagnostics.record("info", "bridge", "Relay Bridge started.");
const pendingClientRequests = new RequestLifecycle<WebSocket, JsonObject>((bridgeId, request) => {
  const startedAt = rpcStartedAt.get(bridgeId);
  if (startedAt !== undefined) performanceMetrics.recordRpcLatency(performance.now() - startedAt);
  rpcStartedAt.delete(bridgeId);
  rpcDiagnostics.lastErrorAt = new Date().toISOString();
  rpcDiagnostics.lastError = `Codex request timed out: ${request.method}`;
  diagnostics.record("error", "rpc", `Request timed out: ${request.method}`, { bridgeId });
  send(request.socket, {
    type: "rpcResult",
    id: request.clientId,
    error: { message: "Codex 长时间没有完成请求，Relay 已释放该请求。" },
  });
  cancelForwardedRequest(bridgeId);
});
const pendingServerRequests = new Map<string, PendingServerRequest>();
let nextRequestId = 1;
let codexReady = false;
let codexGeneration = 1;
let codexRestartAttempt = 0;
let codexRestartTimer: NodeJS.Timeout | undefined;
let codexStartupTimer: NodeJS.Timeout | undefined;
let shuttingDown = false;
let activeCodexProfile = (await codexProfiles.list()).find((profile) => profile.active)!;
const desktopSync = new DesktopSync(
  config.desktopSync,
  config.desktopCdpPort,
  config.desktopAppPath,
  (message) => console.log(`[desktop] ${message}`),
  (status) => broadcast(bridgeStatus(codexReady ? "ready" : "starting", status)),
);
const fileTransfer = new FileTransferManager(config.defaultCwd, config.filesRoot);
const updateManager = new UpdateManager(fileTransfer.filesRoot);
const promptQueue = await PromptQueue.create();
const dispatchingQueueThreads = new Set<string>();
const queueRetryTimers = new Map<string, NodeJS.Timeout>();
const pendingInternalRequests = new Map<string, PendingInternalRequest>();
let nextInternalRequestId = 1;
let runtimeState = new RuntimeStateTracker();
let sessionActivity = new SessionActivityTracker();

let codex = createCodexAppServer(codexGeneration);

await codex.start();
armCodexStartupWatchdog(codexGeneration);

const httpServer = createServer((request, response) => {
  if (request.url === "/health") {
    response.writeHead(codexReady ? 200 : 503, { "content-type": "application/json" });
    response.end(JSON.stringify({
      status: codexReady ? "ready" : "starting",
      clients: clients.size,
      uptimeSeconds: Math.floor(process.uptime()),
      activeTurns: runtimeState.activeCount,
      pendingRpcCount: pendingClientRequests.size,
      pendingApprovalCount: pendingServerRequests.size,
      queuedPromptCount: promptQueue.list(activeCodexProfile.id).length,
      codexRestartAttempt,
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
    diagnostics.record("warning", "socket", "Rejected a WebSocket origin header.", { remoteAddress: request.socket.remoteAddress });
    socket.write("HTTP/1.1 403 Forbidden\r\nConnection: close\r\n\r\n");
    socket.destroy();
    return;
  }
  if (!isAuthorized(request.headers.authorization, config.token)) {
    socketDiagnostics.lastRejectedAt = new Date().toISOString();
    socketDiagnostics.lastError = "WebSocket authorization failed.";
    diagnostics.record("warning", "socket", "Rejected an unauthorized WebSocket connection.", { remoteAddress: request.socket.remoteAddress });
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
  diagnostics.record("info", "socket", "Remote client connected.", { clients: clients.size });
  console.log(`[socket] mobile client connected (${clients.size} total)`);
  send(socket, bridgeStatus(codexReady ? "ready" : "starting"));
  for (const pending of pendingServerRequests.values()) {
    send(socket, { type: "serverRequest", ...pending.request });
  }

  socket.on("message", (data, isBinary) => {
    if (isBinary) {
      sendError(socket, "Binary messages are not supported.");
      return;
    }
    try {
      const raw = data.toString("utf8");
      performanceMetrics.recordInbound(Buffer.byteLength(raw));
      void handleClientMessage(socket, raw).catch((error) => {
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
    for (const [bridgeId] of pendingClientRequests.removeSocket(socket)) {
      rpcStartedAt.delete(bridgeId);
      cancelForwardedRequest(bridgeId);
    }
    socketDiagnostics.lastDisconnectedAt = new Date().toISOString();
    socketDiagnostics.lastClose = `${code}${reason.length ? `: ${reason.toString("utf8")}` : ""}`;
    diagnostics.record(code === 1000 ? "info" : "warning", "socket", "Remote client disconnected.", { code, clients: clients.size });
    console.log(`[socket] mobile client disconnected (${clients.size} total)`);
  });
  socket.on("error", (error) => {
    socketDiagnostics.lastErrorAt = new Date().toISOString();
    socketDiagnostics.lastError = error.message;
    diagnostics.record("error", "socket", error.message);
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
  pairingUrl.searchParams.set("name", process.env.COMPUTERNAME ?? process.env.HOSTNAME ?? "Windows PC");

  console.log(`Relay Bridge listening on ${config.host}:${config.port}`);
  console.log(`Advertised mobile URL: ${config.advertiseUrl}`);
  console.log(`Desktop sync: ${desktopSync.enabled ? "enabled" : "disabled"}`);
  console.log("Scan this QR code with the iPhone Camera after installing Relay:");
  qrcode.generate(pairingUrl.toString(), { small: true });
  console.log(`Manual token: ${config.token}`);
});

async function handleClientMessage(socket: WebSocket, raw: string): Promise<void> {
  const message = parseClientMessage(raw);
  if (message.type === "rpcCancel") {
    const cancelled = pendingClientRequests.cancelClient(socket, message.id);
    if (cancelled) {
      rpcStartedAt.delete(cancelled[0]);
      diagnostics.record("info", "rpc", `Client cancelled ${cancelled[1].method}.`);
      cancelForwardedRequest(cancelled[0]);
    }
    return;
  }
  if (message.type === "rpc") {
    rpcDiagnostics.lastReceivedAt = new Date().toISOString();
    rpcDiagnostics.lastMethod = message.method;
    if (message.method === "relay/diagnostics/report") {
      send(socket, { type: "rpcAccepted", id: message.id, method: message.method });
      rpcDiagnostics.lastAcceptedAt = new Date().toISOString();
      send(socket, { type: "rpcResult", id: message.id, result: diagnosticsReport() });
      rpcDiagnostics.lastCompletedAt = new Date().toISOString();
      rpcDiagnostics.lastCompletedMethod = message.method;
      return;
    }
    if (message.method === "relay/update/check" || message.method === "relay/update/download-ios") {
      send(socket, { type: "rpcAccepted", id: message.id, method: message.method });
      rpcDiagnostics.lastAcceptedAt = new Date().toISOString();
      try {
        const result = message.method === "relay/update/check"
          ? await updateManager.check(typeof message.params.currentVersion === "string" ? message.params.currentVersion : "0.0.0")
          : await updateManager.downloadIOS((progress) => send(socket, { type: "updateProgress", ...progress }));
        send(socket, { type: "rpcResult", id: message.id, result });
        rpcDiagnostics.lastCompletedAt = new Date().toISOString();
        rpcDiagnostics.lastCompletedMethod = message.method;
        rpcDiagnostics.lastError = null;
      } catch (error) {
        const detail = error instanceof Error ? error.message : String(error);
        rpcDiagnostics.lastCompletedAt = new Date().toISOString();
        rpcDiagnostics.lastCompletedMethod = message.method;
        rpcDiagnostics.lastErrorAt = rpcDiagnostics.lastCompletedAt;
        rpcDiagnostics.lastError = detail;
        diagnostics.record("error", "update", detail, { method: message.method });
        send(socket, { type: "rpcResult", id: message.id, error: { code: -32000, message: detail } });
      }
      return;
    }
    if (message.method === "relay/thread/runtime") {
      send(socket, { type: "rpcAccepted", id: message.id, method: message.method });
      rpcDiagnostics.lastAcceptedAt = new Date().toISOString();
      const result = await runtimeState.snapshotWithExternal(message.params.threadId, sessionActivity);
      send(socket, { type: "rpcResult", id: message.id, result });
      rpcDiagnostics.lastCompletedAt = new Date().toISOString();
      rpcDiagnostics.lastCompletedMethod = message.method;
      return;
    }
    if (message.method === "relay/thread/goal") {
      send(socket, { type: "rpcAccepted", id: message.id, method: message.method });
      rpcDiagnostics.lastAcceptedAt = new Date().toISOString();
      try {
        const goal = await new GoalStore(codexProfiles.activeCodexHome).read(message.params.threadId);
        send(socket, { type: "rpcResult", id: message.id, result: { goal: goal ?? null } });
        rpcDiagnostics.lastCompletedAt = new Date().toISOString();
        rpcDiagnostics.lastCompletedMethod = message.method;
      } catch (error) {
        const detail = error instanceof Error ? error.message : "Could not read the Goal state.";
        rpcDiagnostics.lastErrorAt = new Date().toISOString();
        rpcDiagnostics.lastError = detail;
        diagnostics.record("error", "goal", detail, { threadId: message.params.threadId });
        send(socket, { type: "rpcResult", id: message.id, error: { code: -32000, message: detail } });
      }
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
        const incremental = message.params.incremental === true;
        const subscriptions = sessionSubscriptions.get(socket);
        subscriptions?.get(threadId)?.();
        const cursor = incremental ? new SessionPatchCursor() : undefined;
        let ready = false;
        let queuedSnapshot: Awaited<ReturnType<typeof sessionActivity.turnSnapshot>> | undefined;
        const stop = sessionActivity.subscribe(threadId, (snapshot) => {
          if (!ready) {
            queuedSnapshot = snapshot;
            return;
          }
          if (!cursor) {
            send(socket, { type: "sessionSnapshot", threadId, snapshot });
            return;
          }
          const update = cursor.update(snapshot);
          if (update?.type === "sessionPatch") send(socket, { type: "sessionPatch", threadId, patch: update.patch });
          else if (update?.type === "sessionSnapshot") send(socket, { type: "sessionSnapshot", threadId, snapshot: update.snapshot });
          else performanceMetrics.recordSuppressedSessionUpdate();
        });
        subscriptions?.set(threadId, stop);
        const snapshot = await sessionActivity.turnSnapshot(threadId);
        const result = cursor ? cursor.reset(snapshot) : snapshot;
        send(socket, { type: "rpcResult", id: message.id, result });
        ready = true;
        if (queuedSnapshot) {
          const queued = queuedSnapshot;
          queuedSnapshot = undefined;
          if (!cursor) send(socket, { type: "sessionSnapshot", threadId, snapshot: queued });
          else {
            const update = cursor.update(queued);
            if (update?.type === "sessionPatch") send(socket, { type: "sessionPatch", threadId, patch: update.patch });
            else if (update?.type === "sessionSnapshot") send(socket, { type: "sessionSnapshot", threadId, snapshot: update.snapshot });
            else performanceMetrics.recordSuppressedSessionUpdate();
          }
        }
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
    if (message.method === "relay/prompt/queue/list") {
      send(socket, { type: "rpcAccepted", id: message.id, method: message.method });
      const threadId = typeof message.params.threadId === "string" ? message.params.threadId : undefined;
      send(socket, { type: "rpcResult", id: message.id, result: { items: promptQueue.list(activeCodexProfile.id, threadId) } });
      return;
    }
    if (message.method === "relay/prompt/queue/add") {
      send(socket, { type: "rpcAccepted", id: message.id, method: message.method });
      try {
        const item = await promptQueue.enqueue({ ...message.params, profileId: activeCodexProfile.id });
        send(socket, { type: "rpcResult", id: message.id, result: { item } });
        broadcastPromptQueue(item.threadId);
        void dispatchNextQueuedPrompt(item.threadId);
      } catch (error) {
        send(socket, { type: "rpcResult", id: message.id, error: { message: error instanceof Error ? error.message : "Could not queue the prompt." } });
      }
      return;
    }
    if (message.method === "relay/prompt/queue/remove") {
      send(socket, { type: "rpcAccepted", id: message.id, method: message.method });
      const id = typeof message.params.id === "string" ? message.params.id : "";
      const existing = promptQueue.list(activeCodexProfile.id).find((item) => item.id === id);
      const removed = id ? await promptQueue.remove(id) : false;
      send(socket, { type: "rpcResult", id: message.id, result: { removed } });
      if (existing) broadcastPromptQueue(existing.threadId);
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
    const timeoutMs = message.method === "thread/turns/list" ? historyRpcTimeoutMs : defaultRpcTimeoutMs;
    pendingClientRequests.add(bridgeId, { socket, clientId: message.id, method: message.method, params }, timeoutMs);
    rpcStartedAt.set(bridgeId, performance.now());
    try {
      codex.send({ method: message.method, id: bridgeId, params });
      send(socket, { type: "rpcAccepted", id: message.id, method: message.method });
      rpcDiagnostics.lastAcceptedAt = new Date().toISOString();
    } catch (error) {
      pendingClientRequests.delete(bridgeId);
      rpcStartedAt.delete(bridgeId);
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
  const pendingServer = pendingServerRequests.get(serverId);
  if (!pendingServer) return;
  clearTimeout(pendingServer.timeout);
  pendingServerRequests.delete(serverId);
  diagnostics.record("info", "approval", message.error ? "Approval was declined." : "Approval was resolved.", { id: serverId });
  const response: JsonObject = { id: message.id };
  if (message.error) response.error = message.error;
  else response.result = message.result ?? {};
  codex.send(response);
  broadcast({ type: "serverRequestResolved", id: message.id });
}

function handleCodexResponse(message: JsonObject): void {
  const id = String(message.id);
  const internal = pendingInternalRequests.get(id);
  if (internal) {
    clearTimeout(internal.timeout);
    pendingInternalRequests.delete(id);
    if ("error" in message) {
      const errorMessage = isObject(message.error) && typeof message.error.message === "string" ? message.error.message : `${internal.method} failed.`;
      internal.reject(new Error(errorMessage));
    } else {
      internal.resolve(isObject(message.result) ? message.result : {});
    }
    return;
  }
  const pending = pendingClientRequests.take(id);
  if (!pending) return;
  const startedAt = rpcStartedAt.get(id);
  if (startedAt !== undefined) performanceMetrics.recordRpcLatency(performance.now() - startedAt);
  rpcStartedAt.delete(id);
  rpcDiagnostics.lastCompletedAt = new Date().toISOString();
  rpcDiagnostics.lastCompletedMethod = pending.method;
  if ("error" in message) {
    rpcDiagnostics.lastErrorAt = rpcDiagnostics.lastCompletedAt;
    rpcDiagnostics.lastError = isObject(message.error) && typeof message.error.message === "string"
      ? message.error.message
      : "Codex RPC failed.";
    diagnostics.record("error", "rpc", rpcDiagnostics.lastError, { method: pending.method });
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
  if ("result" in message) observeFileTransferWorkspaces(pending.method, message.result);
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

function observeFileTransferWorkspaces(method: string, result: unknown): void {
  const object = isObject(result) ? result : {};
  if (method === "thread/list") {
    for (const thread of Array.isArray(object.data) ? object.data : []) {
      if (isObject(thread)) fileTransfer.allowWorkspace(thread.cwd);
    }
    return;
  }
  if (["thread/start", "thread/resume", "thread/read"].includes(method) && isObject(object.thread)) {
    fileTransfer.allowWorkspace(object.thread.cwd);
  }
}

function handleCodexNotification(message: JsonObject): void {
  if (typeof message.method === "string") performanceMetrics.recordCodexEvent(message.method);
  runtimeState.observeNotification(message);
  broadcast({ type: "event", ...message });
  if (["turn/completed", "turn/aborted", "turn/interrupted", "turn/failed"].includes(String(message.method))) {
    clearTerminalApprovals(message.params);
    const params = isObject(message.params) ? message.params : {};
    if (typeof params.threadId === "string") void dispatchNextQueuedPrompt(params.threadId);
  }
  if (message.method === "turn/completed" && isObject(message.params)) {
    desktopSync.activateThread(message.params.threadId, "turn-completed");
  }
}

function handleCodexRequest(message: JsonObject): void {
  const id = String(message.id);
  const existing = pendingServerRequests.get(id);
  if (existing) clearTimeout(existing.timeout);
  const timeout = setTimeout(() => {
    const pending = pendingServerRequests.get(id);
    if (!pending) return;
    pendingServerRequests.delete(id);
    diagnostics.record("warning", "approval", "Approval expired before a response was received.", { id });
    try {
      codex.send({ id: message.id, error: { code: -32000, message: "Relay approval timed out." } });
    } catch {}
    broadcast({ type: "serverRequestResolved", id: message.id, reason: "timeout" });
  }, approvalTimeoutMs);
  timeout.unref();
  pendingServerRequests.set(id, { request: message, timeout });
  diagnostics.record("warning", "approval", "Codex is waiting for approval.", {
    method: message.method,
    threadId: isObject(message.params) ? message.params.threadId : undefined,
  });
  broadcast({ type: "serverRequest", ...message });
}

function cancelForwardedRequest(bridgeId: string): void {
  if (!codexReady) return;
  try { codex.send({ method: "$/cancelRequest", params: { id: bridgeId } }); } catch {}
}

function clearTerminalApprovals(params: unknown): void {
  const terminal = isObject(params) ? params : {};
  const threadId = typeof terminal.threadId === "string" ? terminal.threadId : undefined;
  const turn = isObject(terminal.turn) ? terminal.turn : {};
  const turnId = typeof turn.id === "string" ? turn.id : typeof terminal.turnId === "string" ? terminal.turnId : undefined;
  for (const [id, pending] of pendingServerRequests) {
    const requestParams = isObject(pending.request.params) ? pending.request.params : {};
    const sameThread = !threadId || requestParams.threadId === threadId;
    const sameTurn = !turnId || requestParams.turnId === turnId;
    if (!sameThread || !sameTurn) continue;
    clearTimeout(pending.timeout);
    pendingServerRequests.delete(id);
    broadcast({ type: "serverRequestResolved", id: pending.request.id, reason: "turn-terminal" });
  }
}

function broadcast(message: JsonObject): void {
  for (const client of clients) send(client, message);
}

function send(socket: WebSocket, message: JsonObject): void {
  if (socket.readyState !== WebSocket.OPEN) return;
  const encoded = JSON.stringify(message);
  performanceMetrics.recordOutbound(message, Buffer.byteLength(encoded));
  socket.send(encoded);
}

function sendError(socket: WebSocket, message: string): void {
  send(socket, { type: "bridgeError", message });
}

function bridgeStatus(status: string, sync = desktopSync.status): JsonObject {
  return { type: "bridgeStatus", status, desktopSync: sync, codexProfile: activeCodexProfile };
}

function diagnosticsReport(): JsonObject {
  return diagnostics.report({
    codexReady,
    clients: clients.size,
    activeTurns: runtimeState.activeCount,
    pendingRpcCount: pendingClientRequests.size,
    pendingApprovalCount: pendingServerRequests.size,
    queuedPromptCount: promptQueue.list(activeCodexProfile.id).length,
    codexRestartAttempt,
    uptimeSeconds: Math.floor(process.uptime()),
    desktopSync: { ...desktopSync.status },
    socket: { ...socketDiagnostics },
    rpc: { ...rpcDiagnostics },
    codexProfile: { ...activeCodexProfile },
    performance: performanceMetrics.report(),
  });
}

function createCodexAppServer(generation: number): CodexAppServer {
  const executable = resolveCodexExecutable(codexProfiles.activeCodexHome, config.codexBin);
  console.log(`[codex] Starting App Server with ${executable}`);
  return new CodexAppServer(executable, {
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
        codexRestartAttempt = 0;
        if (codexStartupTimer) clearTimeout(codexStartupTimer);
        codexStartupTimer = undefined;
        diagnostics.record("info", "codex", "Codex App Server is ready.", { profileId: activeCodexProfile.id });
        broadcast(bridgeStatus("ready"));
        void dispatchAllQueuedPrompts();
      }
    },
    onExit: (code, signal) => {
      if (generation !== codexGeneration) return;
      handleCodexExit(generation, code, signal);
    },
  }, { CODEX_HOME: codexProfiles.activeCodexHome });
}

function handleCodexExit(generation: number, code: number | null, signal: NodeJS.Signals | null): void {
  if (generation !== codexGeneration || shuttingDown) return;
  codexReady = false;
  if (codexStartupTimer) clearTimeout(codexStartupTimer);
  codexStartupTimer = undefined;
  failPendingRequests("Codex App Server 已退出，Relay 正在自动恢复。", true);
  clearPendingApprovals("codex-exited");
  runtimeState.stopAll("Codex App Server exited.");
  diagnostics.record("error", "codex", "Codex App Server exited.", { code, signal });
  broadcast({ ...bridgeStatus("restarting"), code, signal });
  console.error(`Codex App Server exited (code=${code}, signal=${signal}). Scheduling restart.`);
  scheduleCodexRestart(generation);
}

function scheduleCodexRestart(generation: number): void {
  if (shuttingDown || generation !== codexGeneration || codexRestartTimer) return;
  codexRestartAttempt += 1;
  const delay = Math.min(1_000 * Math.pow(1.8, codexRestartAttempt - 1), 30_000);
  diagnostics.record("warning", "codex", "Scheduled Codex App Server restart.", { attempt: codexRestartAttempt, retryInMs: delay });
  broadcast({ ...bridgeStatus("restarting"), restartAttempt: codexRestartAttempt, retryInMs: delay });
  codexRestartTimer = setTimeout(() => {
    codexRestartTimer = undefined;
    void replaceCodex(false);
  }, delay);
  codexRestartTimer.unref();
}

async function replaceCodex(stopCurrent: boolean): Promise<void> {
  if (shuttingDown) return;
  const previous = codex;
  codexGeneration += 1;
  const generation = codexGeneration;
  codexReady = false;
  if (stopCurrent) await previous.stop();
  codex = createCodexAppServer(generation);
  try {
    await codex.start();
    armCodexStartupWatchdog(generation);
  } catch (error) {
    console.error(`[codex] restart failed: ${error instanceof Error ? error.message : error}`);
    scheduleCodexRestart(generation);
  }
}

function armCodexStartupWatchdog(generation: number): void {
  if (codexStartupTimer) clearTimeout(codexStartupTimer);
  codexStartupTimer = setTimeout(() => {
    if (shuttingDown || generation !== codexGeneration || codexReady) return;
    console.error("[codex] initialization timed out; replacing App Server.");
    failPendingRequests("Codex 初始化超时，Relay 正在重新启动服务。", true);
    clearPendingApprovals("startup-timeout");
    void replaceCodex(true);
  }, 30_000);
  codexStartupTimer.unref();
}

function failPendingRequests(message: string, notifyClients: boolean): void {
  for (const [bridgeId, pending] of pendingClientRequests.clear()) {
    rpcStartedAt.delete(bridgeId);
    if (notifyClients) send(pending.socket, { type: "rpcResult", id: pending.clientId, error: { message } });
  }
  for (const pending of pendingInternalRequests.values()) {
    clearTimeout(pending.timeout);
    pending.reject(new Error(message));
  }
  pendingInternalRequests.clear();
}

function clearPendingApprovals(reason: string): void {
  for (const pending of pendingServerRequests.values()) {
    clearTimeout(pending.timeout);
    broadcast({ type: "serverRequestResolved", id: pending.request.id, reason });
  }
  pendingServerRequests.clear();
}

function codexRequest(method: string, params: JsonObject, timeoutMs = defaultRpcTimeoutMs): Promise<JsonObject> {
  if (!codexReady) return Promise.reject(new Error("Codex App Server is not ready."));
  const id = `relay.internal.${nextInternalRequestId++}`;
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => {
      pendingInternalRequests.delete(id);
      cancelForwardedRequest(id);
      reject(new Error(`${method} timed out.`));
    }, timeoutMs);
    timeout.unref();
    pendingInternalRequests.set(id, { method, resolve, reject, timeout });
    try { codex.send({ id, method, params }); }
    catch (error) {
      clearTimeout(timeout);
      pendingInternalRequests.delete(id);
      reject(error);
    }
  });
}

async function dispatchAllQueuedPrompts(): Promise<void> {
  for (const threadId of new Set(promptQueue.list(activeCodexProfile.id).map((item) => item.threadId))) {
    void dispatchNextQueuedPrompt(threadId);
  }
}

async function dispatchNextQueuedPrompt(threadId: string): Promise<void> {
  if (!codexReady || dispatchingQueueThreads.has(threadId)) return;
  const next = promptQueue.peek(activeCodexProfile.id, threadId);
  if (!next) return;
  const runtime = await runtimeState.snapshotWithExternal(threadId, sessionActivity);
  if (runtime.known && runtime.isRunning) {
    scheduleQueueRetry(threadId);
    return;
  }
  dispatchingQueueThreads.add(threadId);
  try {
    const params: JsonObject = {
      threadId,
      clientUserMessageId: next.clientUserMessageId,
      input: next.input,
      summary: "detailed",
      ...(next.sandboxPolicy ? { sandboxPolicy: next.sandboxPolicy } : {}),
      ...(next.model ? { model: next.model } : {}),
      ...(next.effort ? { effort: next.effort } : {}),
    };
    const result = await codexRequest("turn/start", params);
    await promptQueue.remove(next.id);
    runtimeState.observeTurnStart(threadId, result.turn);
    desktopSync.activateThread(threadId, "queued-turn-started");
    broadcastPromptQueue(threadId);
  } catch (error) {
    console.error(`[queue] ${threadId}: ${error instanceof Error ? error.message : error}`);
    scheduleQueueRetry(threadId);
  } finally {
    dispatchingQueueThreads.delete(threadId);
  }
}

function scheduleQueueRetry(threadId: string): void {
  if (shuttingDown || queueRetryTimers.has(threadId) || !promptQueue.peek(activeCodexProfile.id, threadId)) return;
  const timer = setTimeout(() => {
    queueRetryTimers.delete(threadId);
    void dispatchNextQueuedPrompt(threadId);
  }, 15_000);
  timer.unref();
  queueRetryTimers.set(threadId, timer);
}

function broadcastPromptQueue(threadId: string): void {
  broadcast({ type: "promptQueueUpdated", threadId, items: promptQueue.list(activeCodexProfile.id, threadId) });
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
  if (codexRestartTimer) clearTimeout(codexRestartTimer);
  codexRestartTimer = undefined;
  if (codexStartupTimer) clearTimeout(codexStartupTimer);
  codexStartupTimer = undefined;
  codexRestartAttempt = 0;
  await previous.stop();
  codex = createCodexAppServer(codexGeneration);
  await codex.start();
  armCodexStartupWatchdog(codexGeneration);
  return activeCodexProfile;
}

function shutdown(): void {
  if (shuttingDown) return;
  shuttingDown = true;
  clearInterval(heartbeatInterval);
  if (codexRestartTimer) clearTimeout(codexRestartTimer);
  if (codexStartupTimer) clearTimeout(codexStartupTimer);
  for (const timer of queueRetryTimers.values()) clearTimeout(timer);
  queueRetryTimers.clear();
  failPendingRequests("Relay Bridge 正在关闭。", true);
  clearPendingApprovals("bridge-shutdown");
  for (const client of clients) client.close(1001, "Bridge shutting down");
  sessionActivity.dispose();
  void Promise.all([fileTransfer.dispose(), codex.stop()])
    .finally(() => httpServer.close(() => process.exit(0)));
}

process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);
}

void main().catch((error) => {
  console.error(error instanceof Error ? error.stack ?? error.message : error);
  process.exit(1);
});
