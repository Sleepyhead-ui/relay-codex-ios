import { createServer } from "node:http";
import { homedir } from "node:os";
import path from "node:path";
import { WebSocketServer, WebSocket } from "ws";
import qrcode from "qrcode-terminal";
import { CodexAppServer } from "./codexAppServer.js";
import { inspectCodexRuntime, type CodexRuntimeInfo } from "./codexExecutable.js";
import { CodexProfileRegistry, type CodexProfile } from "./codexProfiles.js";
import { CodexRuntimeConfigMonitor } from "./codexRuntimeConfigMonitor.js";
import { ClientPreferencesStore } from "./clientPreferences.js";
import { awaitFinalAnswer } from "./completionPreview.js";
import { loadConfig } from "./config.js";
import { DesktopSync } from "./desktopSync.js";
import { DeliveryRegistry, isDurableDeliveryMethod, type DeliveryResponse } from "./deliveryRegistry.js";
import { DiagnosticsLog } from "./diagnostics.js";
import { FileTransferManager } from "./fileTransfer.js";
import { GoalStore } from "./goalStore.js";
import { boundHistoryPage, boundThreadHistoryResult } from "./historyPayload.js";
import { PerformanceMetrics } from "./performanceMetrics.js";
import { BarkPushNotifier, cleanPreview, ExternalCompletionTracker } from "./pushNotifications.js";
import {
  codexRestartDelayMs,
  codexStartupWatchdogMs,
  shouldReplaceUnreadyCodex,
  shouldScheduleCodexRestart,
} from "./restartPolicy.js";
import { isAuthorized, isObject, parseClientMessage, type JsonObject } from "./protocol.js";
import { PromptQueue } from "./promptQueue.js";
import { queuedPromptWaitSatisfied } from "./queueDispatchPolicy.js";
import { RequestLifecycle, type PendingRequest } from "./requestLifecycle.js";
import { RuntimeStateTracker, type ThreadRuntimeSnapshot } from "./runtimeState.js";
import { SessionActivityTracker, type SessionTurnSnapshot } from "./sessionActivity.js";
import { boundSessionSnapshot } from "./sessionPatch.js";
import { SessionStream } from "./sessionStream.js";
import { SessionSourceOwnership } from "./sessionSourceOwnership.js";
import { SessionSubscriptionRegistry } from "./sessionSubscriptions.js";
import { canRestartForWriterRelease, ThreadControlRegistry, type ThreadControlStatus } from "./threadControl.js";
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
const relayVersion = process.env.RELAY_SERVICE_VERSION ?? "unknown";

async function main(): Promise<void> {
const codexProfiles = await CodexProfileRegistry.create();
  const config = await loadConfig(codexProfiles.activeCodexHome);
  const clientPreferences = await ClientPreferencesStore.create(process.env.RELAY_CLIENT_PREFERENCES_STORE?.trim());
const pushNotifier = new BarkPushNotifier();
const threadTitles = new Map<string, string>();
const clients = new Set<WebSocket>();
const clientLiveness = new WeakMap<WebSocket, boolean>();
const sessionSubscriptions = new SessionSubscriptionRegistry<WebSocket>();
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
const diagnostics = new DiagnosticsLog(
  100,
  process.env.RELAY_DIAGNOSTICS_STORE?.trim() || path.join(homedir(), ".relay", "diagnostics.json"),
);
await diagnostics.restore();
const performanceMetrics = new PerformanceMetrics();
const rpcStartedAt = new Map<string, number>();
const deliveryRegistry = await DeliveryRegistry.create<WebSocket>(process.env.RELAY_DELIVERY_STORE?.trim() || undefined);
diagnostics.record("info", "bridge", "Relay Bridge started.");
const pendingClientRequests = new RequestLifecycle<WebSocket, JsonObject>((bridgeId, request) => {
  const startedAt = rpcStartedAt.get(bridgeId);
  if (startedAt !== undefined) performanceMetrics.recordRpcLatency(performance.now() - startedAt);
  rpcStartedAt.delete(bridgeId);
  rpcDiagnostics.lastErrorAt = new Date().toISOString();
  rpcDiagnostics.lastError = `Codex request timed out: ${request.method}`;
  if (request.method === "turn/start") {
    performanceMetrics.recordTurnRejected(
      typeof request.params.clientUserMessageId === "string" ? request.params.clientUserMessageId : undefined,
    );
  }
  if (["turn/start", "turn/steer"].includes(request.method)) {
    sessionSourceOwnership.finish(request.params.threadId);
  }
  diagnostics.record("error", "rpc", `Request timed out: ${request.method}`, { bridgeId });
  const response = {
    error: { message: "Codex 长时间没有完成请求，Relay 已释放该请求。" },
  };
  if (request.deliveryKey) void suspendDelivery(request.deliveryKey, response);
  else send(request.socket, {
    type: "rpcResult",
    id: request.clientId,
    ...response,
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
let recoveringDeliveries = false;
let shuttingDown = false;
let activeCodexProfile = (await codexProfiles.list()).find((profile) => profile.active)!;
let codexRuntimeInfo: CodexRuntimeInfo = inspectCodexRuntime(codexProfiles.activeCodexHome, config.codexBin);
let codexConfigReloadPending = false;
let codexConfigReloadInProgress = false;
let codexConfigReloadTimer: NodeJS.Timeout | undefined;
const changedCodexConfigFiles = new Set<string>();
const desktopSync = new DesktopSync(
  config.desktopSync,
  config.desktopCdpPort,
  config.desktopAppPath,
  (message) => console.log(`[desktop] ${message}`),
  (status) => broadcast(bridgeStatus(codexReady ? "ready" : "starting", status)),
);
const fileTransfer = new FileTransferManager(config.defaultCwd, config.filesRoot);
const updateManager = new UpdateManager(fileTransfer.filesRoot);
const promptQueue = await PromptQueue.create(process.env.RELAY_PROMPT_QUEUE_STORE);
const dispatchingQueueThreads = new Set<string>();
const queueRetryTimers = new Map<string, NodeJS.Timeout>();
const pendingInternalRequests = new Map<string, PendingInternalRequest>();
let nextInternalRequestId = 1;
const threadControl = new ThreadControlRegistry();
const threadControlAcquisitions = new Map<string, Promise<ThreadControlStatus>>();
const externallyRunningThreadIds = new Set<string>();
let threadControlReleaseTimer: NodeJS.Timeout | undefined;
let threadControlReleaseInProgress = false;
let threadControlReleaseNotBefore = 0;
let runtimeState = new RuntimeStateTracker();
let sessionActivity = new SessionActivityTracker();
const sessionSourceOwnership = new SessionSourceOwnership();
let monitoredThreadIds: string[] = [];
let pollingExternalSessions = false;
const externalCompletionTracker = new ExternalCompletionTracker();
const publishedRuntimeSignatures = new Map<string, string>();

const externalSessionPollInterval = setInterval(() => void pollExternalSessions(), 1_500);
externalSessionPollInterval.unref();
const externalSessionDiscoveryInterval = setInterval(() => void refreshExternalSessionMonitoring(), 5_000);
externalSessionDiscoveryInterval.unref();

let codex = createCodexAppServer(codexGeneration);
const codexConfigMonitor = new CodexRuntimeConfigMonitor((changedFiles) => requestCodexConfigReload(changedFiles));

await codex.start();
armCodexStartupWatchdog(codexGeneration);
await codexConfigMonitor.start(codexProfiles.activeCodexHome);

const httpServer = createServer((request, response) => {
  if (request.url === "/health") {
    response.writeHead(codexReady ? 200 : 503, { "content-type": "application/json" });
    response.end(JSON.stringify({
      status: codexReady ? "ready" : "starting",
      version: relayVersion,
      clients: clients.size,
      uptimeSeconds: Math.floor(process.uptime()),
      activeTurns: runtimeState.activeCount,
      activeTransferCount: fileTransfer.activeTransferCount,
      pendingRpcCount: pendingClientRequests.size,
      pendingApprovalCount: pendingServerRequests.size,
      ownedThreadCount: threadControl.ownedIds.length,
      pendingThreadReleaseCount: threadControl.pendingReleaseIds.length,
      queuedPromptCount: promptQueue.list(activeCodexProfile.id).length,
      codexRuntime: codexRuntimeInfo,
      pendingDeliveryCount: deliveryRegistry.pendingCount,
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
  sessionSubscriptions.open(socket);
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
    sessionSubscriptions.close(socket);
    clients.delete(socket);
    clientLiveness.delete(socket);
    deliveryRegistry.removeWaiter(socket);
    for (const [bridgeId] of pendingClientRequests.removeSocket(socket, (request) => Boolean(request.deliveryKey))) {
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
    const existing = pendingClientRequests.findClient(socket, message.id);
    if (existing?.[1].deliveryKey) {
      deliveryRegistry.removeWaiter(socket, message.id);
      diagnostics.record("info", "delivery", `Client detached from ${existing[1].method}; durable delivery continues.`);
      return;
    }
    const cancelled = pendingClientRequests.cancelClient(socket, message.id);
    if (cancelled) {
      rpcStartedAt.delete(cancelled[0]);
      diagnostics.record("info", "rpc", `Client cancelled ${cancelled[1].method}.`);
      cancelForwardedRequest(cancelled[0]);
    } else {
      deliveryRegistry.removeWaiter(socket, message.id);
    }
    return;
  }
  if (message.type === "rpc") {
    const receivedAt = new Date().toISOString();
    const receivedMs = performance.now();
    rpcDiagnostics.lastReceivedAt = receivedAt;
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
    if (message.method === "relay/preferences/get") {
      send(socket, { type: "rpcAccepted", id: message.id, method: message.method });
      send(socket, { type: "rpcResult", id: message.id, result: clientPreferences.get() });
      return;
    }
    if (message.method === "relay/preferences/update") {
      send(socket, { type: "rpcAccepted", id: message.id, method: message.method });
      try {
        const preferences = await clientPreferences.update(message.params);
        send(socket, { type: "rpcResult", id: message.id, result: preferences });
        broadcast({ type: "sidebarPreferencesUpdated", preferences });
      } catch (error) {
        send(socket, { type: "rpcResult", id: message.id, error: { message: error instanceof Error ? error.message : "Could not update Relay preferences." } });
      }
      return;
    }
    if (["relay/thread/control/status", "relay/thread/control/acquire", "relay/thread/control/release"].includes(message.method)) {
      send(socket, { type: "rpcAccepted", id: message.id, method: message.method });
      rpcDiagnostics.lastAcceptedAt = new Date().toISOString();
      try {
        const threadId = requiredThreadControlId(message.params.threadId);
        let result: JsonObject;
        if (message.method === "relay/thread/control/acquire") {
          result = { ...await ensureThreadControl(threadId) };
        } else if (message.method === "relay/thread/control/release") {
          result = requestThreadControlRelease(threadId, "explicit-release");
        } else {
          result = { ...await currentThreadControlStatus(threadId) };
        }
        send(socket, { type: "rpcResult", id: message.id, result });
        rpcDiagnostics.lastCompletedAt = new Date().toISOString();
        rpcDiagnostics.lastCompletedMethod = message.method;
      } catch (error) {
        const detail = error instanceof Error ? error.message : "Could not update task control.";
        rpcDiagnostics.lastErrorAt = new Date().toISOString();
        rpcDiagnostics.lastError = detail;
        send(socket, { type: "rpcResult", id: message.id, error: { code: -32000, message: detail } });
      }
      return;
    }
    if (message.method === "relay/delivery/status") {
      send(socket, { type: "rpcAccepted", id: message.id, method: message.method });
      rpcDiagnostics.lastAcceptedAt = new Date().toISOString();
      const result = await deliveryStatus(message.params);
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
      const result = boundSessionSnapshot(await sessionActivity.turnSnapshot(message.params.threadId));
      fileTransfer.allowConversationPayload(result);
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
        const subscriptionId = typeof message.params.subscriptionId === "string" && message.params.subscriptionId
          ? message.params.subscriptionId
          : undefined;
        const stream = new SessionStream(
          threadId,
          subscriptionId,
          incremental,
          {
            bufferedAmount: () => socket.bufferedAmount,
            send: (outbound) => send(socket, outbound),
          },
          performanceMetrics,
        );
        const stopWatching = sessionActivity.subscribe(threadId, (snapshot) => {
          fileTransfer.allowConversationPayload(snapshot);
          observeExternalThreadControl(threadId, snapshot.known && snapshot.isRunning);
          if (sessionSourceOwnership.isRelayOwned(threadId, snapshot.turnId)) {
            performanceMetrics.recordSuppressedSessionUpdate();
            return;
          }
          void publishExternalRuntime(threadId, snapshot);
          stream.enqueue(snapshot);
        });
        sessionSubscriptions.replace(socket, threadId, {
          ...(subscriptionId ? { subscriptionId } : {}),
          stop: () => {
            stopWatching();
            stream.dispose();
          },
        });
        const snapshot = await sessionActivity.turnSnapshot(threadId);
        fileTransfer.allowConversationPayload(snapshot);
        observeExternalThreadControl(threadId, snapshot.known && snapshot.isRunning);
        if (!sessionSourceOwnership.isRelayOwned(threadId, snapshot.turnId)) {
          void publishExternalRuntime(threadId, snapshot);
        }
        const result = stream.initialize(snapshot);
        send(socket, {
          type: "rpcResult",
          id: message.id,
          result: { ...result, source: "rollout", ...(subscriptionId ? { subscriptionId } : {}) },
        });
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
      const subscriptionId = typeof message.params.subscriptionId === "string" && message.params.subscriptionId
        ? message.params.subscriptionId
        : undefined;
      const unsubscribed = sessionSubscriptions.unsubscribe(socket, threadId, subscriptionId);
      const control = message.params.releaseControl === true
        ? requestThreadControlRelease(threadId, "task-left")
        : undefined;
      send(socket, { type: "rpcResult", id: message.id, result: { unsubscribed, ...(control ? { control } : {}) } });
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
    if (message.method === "relay/prompt/queue/promote") {
      send(socket, { type: "rpcAccepted", id: message.id, method: message.method });
      const id = typeof message.params.id === "string" ? message.params.id : "";
      const item = promptQueue.list(activeCodexProfile.id).find((candidate) => candidate.id === id);
      if (!item) {
        send(socket, { type: "rpcResult", id: message.id, error: { message: "The queued message is no longer waiting to be processed." } });
        return;
      }
      if (dispatchingQueueThreads.has(item.threadId)) {
        send(socket, { type: "rpcResult", id: message.id, error: { message: "The queued message is already being processed." } });
        return;
      }
      dispatchingQueueThreads.add(item.threadId);
      const retryTimer = queueRetryTimers.get(item.threadId);
      if (retryTimer) clearTimeout(retryTimer);
      queueRetryTimers.delete(item.threadId);
      try {
        const runtime = await runtimeState.snapshotWithExternal(item.threadId, sessionActivity);
        if (!runtime.isRunning || !runtime.activeTurnId) throw new Error("The current task has already ended.");
        if (item.waitForTurnId && item.waitForTurnId !== runtime.activeTurnId) {
          throw new Error("The queued message belongs to a different active task.");
        }
        const access = await ensureThreadControl(item.threadId);
        if (access.mode !== "relay-write") throw new Error("Another Codex instance owns this task.");
        const params: JsonObject = {
          threadId: item.threadId,
          expectedTurnId: runtime.activeTurnId,
          clientUserMessageId: item.clientUserMessageId,
          input: item.input,
        };
        performanceMetrics.recordTurnReceived(params);
        performanceMetrics.recordTurnForwarded(item.clientUserMessageId);
        const result = await codexRequest("turn/steer", params);
        performanceMetrics.recordTurnAccepted(item.clientUserMessageId, runtime.activeTurnId);
        await promptQueue.remove(item.id);
        desktopSync.activateThread(item.threadId, "turn-steered");
        broadcastPromptQueue(item.threadId);
        send(socket, { type: "rpcResult", id: message.id, result: { item, turnId: result.turnId ?? runtime.activeTurnId } });
      } catch (error) {
        performanceMetrics.recordTurnRejected(item.clientUserMessageId);
        scheduleQueueRetry(item.threadId);
        send(socket, { type: "rpcResult", id: message.id, error: { message: error instanceof Error ? error.message : "Could not promote the queued message." } });
      } finally {
        dispatchingQueueThreads.delete(item.threadId);
        if (threadControl.hasPendingRelease) scheduleThreadControlRelease(100);
      }
      return;
    }
    if (message.method === "relay/prompt/queue/update") {
      send(socket, { type: "rpcAccepted", id: message.id, method: message.method });
      try {
        const id = typeof message.params.id === "string" ? message.params.id : "";
        const item = id ? await promptQueue.update(activeCodexProfile.id, id, message.params) : undefined;
        if (!item) throw new Error("The queued message is no longer waiting to be processed.");
        send(socket, { type: "rpcResult", id: message.id, result: { item } });
        broadcastPromptQueue(item.threadId);
      } catch (error) {
        send(socket, { type: "rpcResult", id: message.id, error: { message: error instanceof Error ? error.message : "Could not update the queued message." } });
      }
      return;
    }
    if (message.method === "relay/push/status" || message.method === "relay/push/test") {
      send(socket, { type: "rpcAccepted", id: message.id, method: message.method });
      try {
        if (message.method === "relay/push/test") await pushNotifier.sendTest();
        const result = await pushNotifier.status();
        send(socket, { type: "rpcResult", id: message.id, result });
      } catch (error) {
        const detail = error instanceof Error ? error.message : "手机推送测试失败。";
        diagnostics.record("error", "push", detail);
        send(socket, { type: "rpcResult", id: message.id, error: { message: detail } });
      }
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
    if (["turn/start", "turn/steer"].includes(message.method)) {
      const threadId = requiredThreadControlId(message.params.threadId);
      const access = await ensureThreadControl(threadId);
      if (access.mode !== "relay-write") {
        const detail = "此任务当前由另一个 Codex 实例控制。Relay 已保留输入内容，请在 Codex 释放任务后重试。";
        diagnostics.record("warning", "thread-control", "Rejected a write because another App Server owns the thread.", { threadId, method: message.method });
        send(socket, {
          type: "rpcResult",
          id: message.id,
          error: { code: -32001, message: detail, data: { relayThreadAccess: access } },
        });
        return;
      }
    }
    const delivery = await deliveryRegistry.register(activeCodexProfile.id, message.method, message.params, {
      socket,
      clientId: message.id,
    });
    if (delivery?.kind === "conflict") {
      send(socket, { type: "rpcAccepted", id: message.id, method: message.method });
      send(socket, {
        type: "rpcResult",
        id: message.id,
        error: { message: "同一消息编号不能用于不同的任务或投递方式。" },
      });
      return;
    }
    if (delivery?.kind === "pending") {
      send(socket, { type: "rpcAccepted", id: message.id, method: message.method, duplicate: true });
      diagnostics.record("info", "delivery", `Attached a reconnected client to ${message.method}.`);
      return;
    }
    if (delivery?.kind === "completed") {
      send(socket, { type: "rpcAccepted", id: message.id, method: message.method, replayed: true });
      send(socket, { type: "rpcResult", id: message.id, ...delivery.response });
      diagnostics.record("info", "delivery", `Replayed completed ${message.method}.`);
      return;
    }
    if (delivery?.kind === "new") {
      const recovered = await untrackedDeliveryStatus(message.params);
      if (recovered.status === "completed") {
        send(socket, { type: "rpcAccepted", id: message.id, method: message.method, recovered: true });
        const turnId = typeof recovered.turnId === "string" ? recovered.turnId : undefined;
        const result = message.method === "turn/start"
          ? { ...(turnId ? { turn: { id: turnId }, turnId } : {}) }
          : { ...(turnId ? { turnId } : {}) };
        await completeDelivery(delivery.key, { result });
        diagnostics.record("info", "delivery", `Recovered completed ${message.method} from session history.`);
        return;
      }
    }
    if (message.method === "turn/start") {
      performanceMetrics.recordTurnReceived(message.params, receivedMs, receivedAt);
    }
    const bridgeId = `relay.${nextRequestId++}`;
    const params = { ...message.params };
    if (message.method === "thread/start" && config.defaultCwd && !("cwd" in params)) {
      params.cwd = config.defaultCwd;
    }
    const timeoutMs = message.method === "thread/turns/list" ? historyRpcTimeoutMs : defaultRpcTimeoutMs;
    pendingClientRequests.add(bridgeId, {
      socket,
      clientId: message.id,
      method: message.method,
      params,
      ...(delivery?.kind === "new" ? { deliveryKey: delivery.key } : {}),
    }, timeoutMs);
    if (delivery?.kind === "new") await deliveryRegistry.bindBridgeRequest(delivery.key, bridgeId);
    rpcStartedAt.set(bridgeId, performance.now());
    try {
      if (message.method === "turn/start") {
        performanceMetrics.recordTurnForwarded(
          typeof params.clientUserMessageId === "string" ? params.clientUserMessageId : undefined,
        );
      }
      if (["turn/start", "turn/steer"].includes(message.method)) {
        sessionSourceOwnership.begin(params.threadId);
      }
      codex.send({ method: message.method, id: bridgeId, params });
      send(socket, { type: "rpcAccepted", id: message.id, method: message.method });
      rpcDiagnostics.lastAcceptedAt = new Date().toISOString();
    } catch (error) {
      const pending = pendingClientRequests.take(bridgeId);
      if (message.method === "turn/start") {
        performanceMetrics.recordTurnRejected(
          typeof params.clientUserMessageId === "string" ? params.clientUserMessageId : undefined,
        );
      }
      if (["turn/start", "turn/steer"].includes(message.method)) {
        sessionSourceOwnership.finish(params.threadId);
      }
      rpcStartedAt.delete(bridgeId);
      rpcDiagnostics.lastErrorAt = new Date().toISOString();
      rpcDiagnostics.lastError = error instanceof Error ? error.message : "Could not forward RPC to Codex.";
      const response = { error: { message: rpcDiagnostics.lastError } };
      if (pending?.deliveryKey) await completeDelivery(pending.deliveryKey, response);
      else send(socket, { type: "rpcResult", id: message.id, ...response });
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

async function handleCodexResponse(message: JsonObject): Promise<void> {
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
  const responseError = "error" in message && isObject(message.error) && typeof message.error.message === "string"
    ? message.error.message
    : undefined;
  if (pending.method === "thread/resume" && responseError && isActiveWriterConflict(responseError)) {
    await completeReadOnlyThreadResume(pending, responseError);
    return;
  }
  if ("error" in message) {
    rpcDiagnostics.lastErrorAt = rpcDiagnostics.lastCompletedAt;
    rpcDiagnostics.lastError = isObject(message.error) && typeof message.error.message === "string"
      ? message.error.message
      : "Codex RPC failed.";
    diagnostics.record("error", "rpc", rpcDiagnostics.lastError, { method: pending.method });
  } else {
    rpcDiagnostics.lastError = null;
  }
  const response: DeliveryResponse = {};
  if ("result" in message) {
    response.result = pending.method === "thread/turns/list"
      ? boundHistoryPage(message.result)
      : ["thread/start", "thread/resume", "thread/read", "thread/fork"].includes(pending.method)
        ? boundThreadHistoryResult(message.result)
        : message.result;
  }
  if ("error" in message) response.error = message.error;
  if (pending.deliveryKey) await completeDelivery(pending.deliveryKey, response);
  else send(pending.socket, { type: "rpcResult", id: pending.clientId, ...response });
  if (pending.method === "thread/list" && "result" in message) {
    observeThreadListResult(message.result);
  } else if (["thread/resume", "thread/fork"].includes(pending.method) && "result" in message) {
    sessionActivity.observeThreadResume(message.result);
  }
  if (["thread/start", "thread/resume", "thread/fork"].includes(pending.method) && "result" in message) {
    markThreadControlFromResult(pending.method, pending.params, message.result);
  }
  if (pending.method === "turn/start") {
    const result = isObject(message.result) ? message.result : {};
    const turn = isObject(result.turn) ? result.turn : {};
    const clientUserMessageId = typeof pending.params.clientUserMessageId === "string"
      ? pending.params.clientUserMessageId
      : undefined;
    if ("error" in message) {
      performanceMetrics.recordTurnRejected(clientUserMessageId);
      sessionSourceOwnership.finish(pending.params.threadId);
    }
    else {
      const turnId = typeof turn.id === "string" ? turn.id : undefined;
      performanceMetrics.recordTurnAccepted(clientUserMessageId, turnId);
      sessionSourceOwnership.bind(pending.params.threadId, turnId);
    }
  }
  if ("result" in message) {
    observeFileTransferWorkspaces(pending.method, message.result);
    fileTransfer.allowConversationPayload(message.result);
  }
  if (pending.method === "turn/start" && !("error" in message)) {
    const result = isObject(message.result) ? message.result : {};
    runtimeState.observeTurnStart(pending.params.threadId, result.turn);
    desktopSync.activateThread(pending.params.threadId, "turn-started");
  }
  if (pending.method === "turn/steer" && !("error" in message)) {
    const result = isObject(message.result) ? message.result : {};
    runtimeState.observeTurnStart(pending.params.threadId, { id: result.turnId });
    if (typeof pending.params.threadId === "string" && typeof result.turnId === "string") {
      sessionSourceOwnership.bind(pending.params.threadId, result.turnId);
    }
    desktopSync.activateThread(pending.params.threadId, "turn-steered");
  } else if (pending.method === "turn/steer" && "error" in message) {
    sessionSourceOwnership.finish(pending.params.threadId);
  }
}

async function completeReadOnlyThreadResume(
  pending: PendingRequest<WebSocket, JsonObject>,
  conflictMessage: string,
): Promise<void> {
  const threadId = typeof pending.params.threadId === "string" ? pending.params.threadId : undefined;
  if (!threadId) {
    send(pending.socket, { type: "rpcResult", id: pending.clientId, error: { message: conflictMessage } });
    return;
  }
  try {
    observeExternalThreadControl(threadId, true);
    const pageRequest = isObject(pending.params.initialTurnsPage) ? pending.params.initialTurnsPage : {};
    const [summary, page] = await Promise.all([
      codexRequest("thread/read", { threadId, includeTurns: false }, 30_000),
      codexRequest("thread/turns/list", {
        threadId,
        limit: typeof pageRequest.limit === "number" ? pageRequest.limit : 12,
        sortDirection: typeof pageRequest.sortDirection === "string" ? pageRequest.sortDirection : "desc",
        itemsView: typeof pageRequest.itemsView === "string" ? pageRequest.itemsView : "full",
      }, historyRpcTimeoutMs),
    ]);
    const result: JsonObject = {
      ...summary,
      initialTurnsPage: boundHistoryPage(page),
      relayThreadAccess: { mode: "external-read-only", reason: "active-writer" },
    };
    sessionActivity.observeThreadResume(summary);
    observeFileTransferWorkspaces("thread/read", summary);
    fileTransfer.allowConversationPayload(result);
    rpcDiagnostics.lastError = null;
    diagnostics.record("warning", "rpc", "Opened a thread read-only because another Codex instance owns its writer lock.", { threadId });
    send(pending.socket, { type: "rpcResult", id: pending.clientId, result });
  } catch (fallbackError) {
    const detail = fallbackError instanceof Error ? fallbackError.message : conflictMessage;
    rpcDiagnostics.lastErrorAt = new Date().toISOString();
    rpcDiagnostics.lastError = detail;
    diagnostics.record("error", "rpc", detail, { method: pending.method, threadId, fallback: "thread/read" });
    send(pending.socket, { type: "rpcResult", id: pending.clientId, error: { message: detail } });
  }
}

function isActiveWriterConflict(message: string): boolean {
  return /already has an active writer|thread-store conflict/i.test(message);
}

function requiredThreadControlId(value: unknown): string {
  if (typeof value !== "string" || !value) throw new Error("Missing threadId.");
  return value;
}

async function currentThreadControlStatus(threadId: string): Promise<ThreadControlStatus> {
  if (threadControl.isOwned(threadId)) return { mode: "relay-write" };
  if (externallyRunningThreadIds.has(threadId)) return { mode: "external-read-only", reason: "active-writer" };
  const snapshot = await sessionActivity.turnSnapshot(threadId);
  return threadControl.status(threadId, snapshot.known && snapshot.isRunning);
}

async function ensureThreadControl(threadId: string): Promise<ThreadControlStatus> {
  if (threadControl.hasPendingRelease) {
    threadControlReleaseNotBefore = Math.max(threadControlReleaseNotBefore, Date.now() + 2_000);
  }
  if (threadControl.isOwned(threadId)) return { mode: "relay-write" };
  const existing = threadControlAcquisitions.get(threadId);
  if (existing) return existing;
  if (!codexReady) throw new Error("Codex App Server is not ready.");

  const acquisition = (async (): Promise<ThreadControlStatus> => {
    try {
      const result = await codexRequest("thread/resume", { threadId, excludeTurns: true }, 30_000);
      sessionActivity.observeThreadResume(result);
      observeFileTransferWorkspaces("thread/resume", result);
      markThreadControlOwned(threadId);
      diagnostics.record("info", "thread-control", "Relay acquired task writer ownership.", { threadId });
      return { mode: "relay-write" };
    } catch (error) {
      const detail = error instanceof Error ? error.message : String(error);
      if (!isActiveWriterConflict(detail)) throw error;
      observeExternalThreadControl(threadId, true);
      diagnostics.record("warning", "thread-control", "Another Codex App Server owns the task writer.", { threadId });
      return { mode: "external-read-only", reason: "active-writer" };
    } finally {
      threadControlAcquisitions.delete(threadId);
      if (threadControl.hasPendingRelease) scheduleThreadControlRelease(100);
    }
  })();
  threadControlAcquisitions.set(threadId, acquisition);
  return acquisition;
}

function markThreadControlFromResult(method: string, params: JsonObject, result: unknown): void {
  const object = isObject(result) ? result : {};
  const thread = isObject(object.thread) ? object.thread : {};
  const threadId = typeof thread.id === "string"
    ? thread.id
    : typeof params.threadId === "string" ? params.threadId : undefined;
  if (!threadId) return;
  markThreadControlOwned(threadId);
  diagnostics.record("info", "thread-control", `Relay acquired task writer ownership through ${method}.`, { threadId });
}

function markThreadControlOwned(threadId: string): void {
  externallyRunningThreadIds.delete(threadId);
  if (!threadControl.markOwned(threadId)) return;
  broadcast({ type: "threadControlUpdated", threadId, control: { mode: "relay-write" } });
}

function requestThreadControlRelease(threadId: string, reason: string): JsonObject {
  const requested = threadControl.requestRelease(threadId);
  if (requested) {
    diagnostics.record("info", "thread-control", "Task writer release was requested.", { threadId, reason });
    scheduleThreadControlRelease(350);
  }
  return {
    mode: threadControl.isOwned(threadId) ? "relay-write" : "unowned",
    release: requested ? "scheduled" : "not-owned",
  };
}

function scheduleThreadControlRelease(delayMs: number): void {
  if (shuttingDown || threadControlReleaseInProgress || threadControlReleaseTimer || !threadControl.hasPendingRelease) return;
  threadControlReleaseTimer = setTimeout(() => {
    threadControlReleaseTimer = undefined;
    void releaseThreadControlWhenIdle();
  }, delayMs);
  threadControlReleaseTimer.unref();
}

async function releaseThreadControlWhenIdle(): Promise<void> {
  if (shuttingDown || threadControlReleaseInProgress || !threadControl.hasPendingRelease) return;
  if (Date.now() < threadControlReleaseNotBefore) {
    scheduleThreadControlRelease(Math.max(100, threadControlReleaseNotBefore - Date.now()));
    return;
  }
  const conditions = {
    activeTurns: runtimeState.activeCount,
    pendingClientRequests: pendingClientRequests.size,
    pendingInternalRequests: pendingInternalRequests.size,
    pendingServerRequests: pendingServerRequests.size,
    pendingDeliveries: deliveryRegistry.pendingCountFor(activeCodexProfile.id),
    dispatchingQueues: dispatchingQueueThreads.size,
    queuedPrompts: promptQueue.list(activeCodexProfile.id).length,
    acquiringThreads: threadControlAcquisitions.size,
    recoveringDeliveries,
    configurationReloading: codexConfigReloadInProgress,
  };
  if (!canRestartForWriterRelease(conditions)) {
    scheduleThreadControlRelease(1_000);
    return;
  }

  threadControlReleaseInProgress = true;
  const requestedThreadIds = threadControl.pendingReleaseIds;
  diagnostics.record("info", "thread-control", "Restarting the Relay App Server to release idle task writers.", { requestedThreadIds });
  codexReady = false;
  broadcast({ ...bridgeStatus("reloading"), reason: "writer-release", threadIds: requestedThreadIds });
  try {
    await replaceCodex(true, "writer-release");
  } finally {
    threadControlReleaseInProgress = false;
  }
}

function clearThreadControl(reason: string): void {
  const releasedThreadIds = threadControl.reset();
  threadControlAcquisitions.clear();
  if (threadControlReleaseTimer) clearTimeout(threadControlReleaseTimer);
  threadControlReleaseTimer = undefined;
  threadControlReleaseNotBefore = 0;
  if (releasedThreadIds.length > 0) {
    broadcast({ type: "threadControlUpdated", threadIds: releasedThreadIds, control: { mode: "unowned" }, reason });
  }
}

function observeExternalThreadControl(threadId: string, running: boolean): void {
  if (threadControl.isOwned(threadId)) {
    externallyRunningThreadIds.delete(threadId);
    return;
  }
  if (!running || externallyRunningThreadIds.has(threadId)) return;
  externallyRunningThreadIds.add(threadId);
  broadcast({
    type: "threadControlUpdated",
    threadId,
    control: { mode: "external-read-only", reason: "active-writer" },
    reason: "external-activity",
  });
}

function observeFileTransferWorkspaces(method: string, result: unknown): void {
  const object = isObject(result) ? result : {};
  if (method === "thread/list") {
    for (const thread of Array.isArray(object.data) ? object.data : []) {
      if (isObject(thread)) {
        fileTransfer.allowWorkspace(thread.cwd);
        rememberThreadTitle(thread);
      }
    }
    return;
  }
  if (["thread/start", "thread/resume", "thread/read", "thread/fork"].includes(method) && isObject(object.thread)) {
    fileTransfer.allowWorkspace(object.thread.cwd);
    rememberThreadTitle(object.thread);
  }
}

function observeThreadListResult(result: unknown): void {
  sessionActivity.observeThreadList(result);
  const object = isObject(result) ? result : {};
  const threads = Array.isArray(object.data) ? object.data.filter(isObject) : [];
  const recentIds = threads
    .flatMap((thread) => typeof thread.id === "string" ? [thread.id] : [])
    .slice(0, 8);
  const activeIds = threads
    .filter(threadLooksActive)
    .flatMap((thread) => typeof thread.id === "string" ? [thread.id] : []);
  monitoredThreadIds = [...new Set([...activeIds, ...recentIds])].slice(0, 32);
  const monitored = new Set(monitoredThreadIds);
  for (const threadId of publishedRuntimeSignatures.keys()) {
    if (!monitored.has(threadId)) publishedRuntimeSignatures.delete(threadId);
  }
  for (const thread of threads) rememberThreadTitle(thread);
}

function threadLooksActive(thread: JsonObject): boolean {
  const status = typeof thread.status === "string"
    ? thread.status
    : isObject(thread.status) && typeof thread.status.type === "string" ? thread.status.type : "";
  return /active|running|progress|started|processing|pending|queued/i.test(status);
}

async function refreshExternalSessionMonitoring(): Promise<void> {
  if (!codexReady || shuttingDown) return;
  try {
    const result = await codexRequest("thread/list", {
      limit: 20,
      sortKey: "updated_at",
      sortDirection: "desc",
      useStateDbOnly: true,
    }, 20_000);
    observeThreadListResult(result);
  } catch {}
}

async function pollExternalSessions(): Promise<void> {
  if (pollingExternalSessions || shuttingDown || monitoredThreadIds.length === 0) return;
  pollingExternalSessions = true;
  try {
    for (const threadId of monitoredThreadIds) {
      const snapshot = await sessionActivity.turnSnapshot(threadId);
      observeExternalThreadControl(threadId, snapshot.known && snapshot.isRunning);
      if (!sessionSourceOwnership.isRelayOwned(threadId, snapshot.turnId)) {
        await publishExternalRuntime(threadId, snapshot);
      }
      if (!snapshot.known || !snapshot.turnId) continue;
      if (externalCompletionTracker.observe(threadId, snapshot)) {
        try {
          const preview = await completionPreview(threadId, snapshot.turnId, snapshot.items);
          const sent = await pushNotifier.sendTaskCompletion({
            turnId: snapshot.turnId,
            threadId,
            failed: false,
            ...(threadTitles.get(threadId) ? { taskTitle: threadTitles.get(threadId)! } : {}),
            ...(preview ? { preview } : {}),
          });
          if (sent) diagnostics.record("info", "push", "Sent an external task completion notification.", { threadId, turnId: snapshot.turnId });
        } catch (error) {
          externalCompletionTracker.retry(threadId, snapshot.turnId);
          const detail = error instanceof Error ? error.message : "手机任务通知发送失败。";
          diagnostics.record("error", "push", detail, { threadId, turnId: snapshot.turnId });
        }
      }
    }
  } finally {
    pollingExternalSessions = false;
  }
}

async function publishExternalRuntime(threadId: string, snapshot?: SessionTurnSnapshot): Promise<void> {
  const runtime = snapshot
    ? runtimeState.snapshotWithObservation(threadId, snapshot.known ? {
      active: snapshot.isRunning,
      ...(snapshot.turnId ? { turnId: snapshot.turnId } : {}),
      ...(snapshot.startedAt ? { startedAt: snapshot.startedAt } : {}),
      updatedAt: snapshot.updatedAt,
    } : null)
    : await runtimeState.snapshotWithExternal(threadId, sessionActivity);
  if (!runtime.known) return;
  const signature = runtimeSignature(runtime);
  if (publishedRuntimeSignatures.get(threadId) === signature) return;
  publishedRuntimeSignatures.set(threadId, signature);
  broadcast({ type: "runtimeUpdated", threadId, runtime });
}

function runtimeSignature(runtime: ThreadRuntimeSnapshot): string {
  return JSON.stringify({
    known: runtime.known,
    isRunning: runtime.isRunning,
    activeTurnId: runtime.activeTurnId,
    observedTurnId: runtime.observedTurnId,
    startedAt: runtime.startedAt,
    upstreamRetrying: runtime.upstreamRetrying,
    upstreamError: runtime.upstreamError,
  });
}

function rememberThreadTitle(thread: JsonObject): void {
  const id = typeof thread.id === "string" ? thread.id : undefined;
  const title = typeof thread.name === "string" ? thread.name
    : typeof thread.title === "string" ? thread.title
      : undefined;
  if (id && title?.trim()) threadTitles.set(id, title.trim());
}

function handleCodexNotification(message: JsonObject): void {
  fileTransfer.allowConversationPayload(message);
  if (typeof message.method === "string") {
    const latency = performanceMetrics.recordCodexEvent(
      message.method,
      isObject(message.params) ? message.params : {},
    );
    if (latency) {
      diagnostics.record("info", "latency", "Captured Relay turn latency.", {
        threadId: latency.threadId,
        turnId: latency.turnId,
        totalToFirstVisibleMs: latency.totalToFirstVisibleMs,
        totalDurationMs: latency.totalDurationMs,
        firstVisibleMethod: latency.firstVisibleMethod,
        model: latency.model,
        effort: latency.effort,
        summary: latency.summary,
      });
    }
  }
  runtimeState.observeNotification(message);
  const publishesRuntime = message.method === "turn/started"
    || message.method === "error"
    || ["turn/completed", "turn/aborted", "turn/interrupted", "turn/failed"].includes(String(message.method));
  if (publishesRuntime && isObject(message.params) && typeof message.params.threadId === "string") {
    broadcast({
      type: "runtimeUpdated",
      threadId: message.params.threadId,
      runtime: runtimeState.snapshot(message.params.threadId),
    });
  }
  broadcast({ type: "event", source: "appServer", ...message });
  if (["turn/completed", "turn/aborted", "turn/interrupted", "turn/failed"].includes(String(message.method))) {
    clearTerminalApprovals(message.params);
    const params = isObject(message.params) ? message.params : {};
    if (typeof params.threadId === "string") {
      const turn = isObject(params.turn) ? params.turn : {};
      const completedTurnId = typeof turn.id === "string"
        ? turn.id
        : typeof params.turnId === "string" ? params.turnId : undefined;
      sessionSourceOwnership.finish(params.threadId, completedTurnId);
      void dispatchNextQueuedPrompt(params.threadId, completedTurnId);
    }
    void pushTaskCompletion(String(message.method), params);
    if (codexConfigReloadPending) scheduleCodexConfigReload(100);
    if (threadControl.hasPendingRelease) scheduleThreadControlRelease(100);
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

async function pushTaskCompletion(method: string, params: JsonObject): Promise<void> {
  const threadId = typeof params.threadId === "string" ? params.threadId : undefined;
  const turn = isObject(params.turn) ? params.turn : {};
  const turnId = typeof params.turnId === "string" ? params.turnId
    : typeof turn.id === "string" ? turn.id
      : undefined;
  if (!threadId || !turnId) return;
  const items = Array.isArray(turn.items) ? turn.items.filter(isObject) : [];
  const taskTitle = threadTitles.get(threadId);
  try {
    const preview = method === "turn/failed" ? undefined : await completionPreview(threadId, turnId, items);
    const sent = await pushNotifier.sendTaskCompletion({
      turnId,
      threadId,
      failed: method === "turn/failed",
      ...(taskTitle ? { taskTitle } : {}),
      ...(preview ? { preview } : {}),
    });
    if (sent) diagnostics.record("info", "push", "Sent a task completion notification.", { threadId, turnId });
  } catch (error) {
    const detail = error instanceof Error ? error.message : "手机任务通知发送失败。";
    diagnostics.record("error", "push", detail, { threadId, turnId });
  }
}

async function completionPreview(threadId: string, turnId: string, initialItems?: JsonObject[]): Promise<string | undefined> {
  let registeredSession = false;
  const answer = await awaitFinalAnswer({
    turnId,
    ...(initialItems ? { initialItems } : {}),
    loadSnapshot: async () => {
      let snapshot = await sessionActivity.turnSnapshot(threadId);
      if (!snapshot.known && !registeredSession && codexReady) {
        registeredSession = true;
        try {
          const read = await codexRequest("thread/read", { threadId, includeTurns: true }, 15_000);
          sessionActivity.observeThreadResume(read);
          snapshot = await sessionActivity.turnSnapshot(threadId);
        } catch {}
      }
      return snapshot;
    },
  });
  return answer ? cleanPreview(answer) : undefined;
}

function send(socket: WebSocket, message: JsonObject): number {
  if (socket.readyState !== WebSocket.OPEN) return 0;
  const encoded = JSON.stringify(message);
  const bytes = Buffer.byteLength(encoded);
  performanceMetrics.recordOutbound(message, bytes);
  socket.send(encoded);
  return bytes;
}

async function completeDelivery(key: string, response: DeliveryResponse): Promise<void> {
  const waiters = await deliveryRegistry.complete(key, response);
  for (const waiter of waiters) {
    send(waiter.socket, { type: "rpcResult", id: waiter.clientId, ...response });
  }
  const separator = key.indexOf("\u0000");
  const profileId = separator >= 0 ? key.slice(0, separator) : activeCodexProfile.id;
  const clientUserMessageId = separator >= 0 ? key.slice(separator + 1) : key;
  broadcast({
    type: "deliveryUpdated",
    profileId,
    clientUserMessageId,
    status: "completed",
    ...response,
  });
}

async function suspendDelivery(key: string, response: DeliveryResponse): Promise<void> {
  const waiters = await deliveryRegistry.suspend(key);
  for (const waiter of waiters) {
    send(waiter.socket, { type: "rpcResult", id: waiter.clientId, deliveryUncertain: true, ...response });
  }
  const separator = key.indexOf("\u0000");
  const profileId = separator >= 0 ? key.slice(0, separator) : activeCodexProfile.id;
  const clientUserMessageId = separator >= 0 ? key.slice(separator + 1) : key;
  broadcast({
    type: "deliveryUpdated",
    profileId,
    clientUserMessageId,
    status: "pending",
    deliveryUncertain: true,
    ...response,
  });
}

async function deliveryStatus(params: JsonObject): Promise<JsonObject> {
  const clientUserMessageId = typeof params.clientUserMessageId === "string" ? params.clientUserMessageId : "";
  const tracked = deliveryRegistry.status(activeCodexProfile.id, clientUserMessageId);
  if (tracked.known) return tracked;
  return untrackedDeliveryStatus(params);
}

async function untrackedDeliveryStatus(params: JsonObject): Promise<JsonObject> {
  const clientUserMessageId = typeof params.clientUserMessageId === "string" ? params.clientUserMessageId : "";
  const threadId = typeof params.threadId === "string" ? params.threadId : "";
  const unknown = deliveryRegistry.status(activeCodexProfile.id, clientUserMessageId);
  if (!clientUserMessageId || !threadId) return unknown;

  const queued = promptQueue.list(activeCodexProfile.id, threadId)
    .find((item) => item.clientUserMessageId === clientUserMessageId);
  if (queued) {
    return {
      known: true,
      status: "pending",
      source: "queue",
      threadId,
      clientUserMessageId,
      updatedAt: queued.createdAt,
    };
  }

  const snapshot = await sessionActivity.turnSnapshot(threadId);
  const delivered = snapshot.items?.some((item) => item.clientId === clientUserMessageId || item.id === clientUserMessageId) === true;
  if (delivered) {
    return {
      known: true,
      status: "completed",
      source: "session",
      threadId,
      clientUserMessageId,
      ...(snapshot.turnId ? { turnId: snapshot.turnId } : {}),
      updatedAt: snapshot.updatedAt,
    };
  }
  return {
    known: false,
    status: "unknown",
    threadId,
    clientUserMessageId,
    updatedAt: snapshot.updatedAt,
  };
}

function sendError(socket: WebSocket, message: string): void {
  send(socket, { type: "bridgeError", message });
}

function bridgeStatus(status: string, sync = desktopSync.status): JsonObject {
  return {
    type: "bridgeStatus",
    status,
    version: relayVersion,
    desktopSync: sync,
    codexProfile: activeCodexProfile,
    codexRuntime: codexRuntimeInfo,
  };
}

function diagnosticsReport(): JsonObject {
  return diagnostics.report({
    codexReady,
    clients: clients.size,
    activeTurns: runtimeState.activeCount,
    activeTransferCount: fileTransfer.activeTransferCount,
    pendingRpcCount: pendingClientRequests.size,
    pendingApprovalCount: pendingServerRequests.size,
    ownedThreadCount: threadControl.ownedIds.length,
    pendingThreadReleaseCount: threadControl.pendingReleaseIds.length,
    queuedPromptCount: promptQueue.list(activeCodexProfile.id).length,
    pendingDeliveryCount: deliveryRegistry.pendingCount,
    codexRestartAttempt,
    uptimeSeconds: Math.floor(process.uptime()),
    desktopSync: { ...desktopSync.status },
    socket: { ...socketDiagnostics },
    rpc: { ...rpcDiagnostics },
    codexProfile: { ...activeCodexProfile },
    codexRuntime: { ...codexRuntimeInfo },
    performance: performanceMetrics.report(),
  });
}

function createCodexAppServer(generation: number): CodexAppServer {
  codexRuntimeInfo = inspectCodexRuntime(codexProfiles.activeCodexHome, config.codexBin);
  console.log(`[codex] Starting App Server with ${codexRuntimeInfo.executable} (${codexRuntimeInfo.version ?? "unknown"}, ${codexRuntimeInfo.compatibility})`);
  return new CodexAppServer(codexRuntimeInfo.executable, {
    onResponse: (message) => {
      if (generation === codexGeneration) void handleCodexResponse(message);
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
        void recoverPendingDeliveries();
        void dispatchAllQueuedPrompts();
        void refreshExternalSessionMonitoring();
      }
    },
    onExit: (code, signal) => {
      if (generation !== codexGeneration) return;
      void handleCodexExit(generation, code, signal);
    },
  }, { CODEX_HOME: codexProfiles.activeCodexHome });
}

async function handleCodexExit(generation: number, code: number | null, signal: NodeJS.Signals | null): Promise<void> {
  if (generation !== codexGeneration || shuttingDown) return;
  codexReady = false;
  if (codexStartupTimer) clearTimeout(codexStartupTimer);
  codexStartupTimer = undefined;
  await failPendingRequests("Codex App Server 已退出，Relay 正在自动恢复。", true);
  clearPendingApprovals("codex-exited");
  clearThreadControl("codex-exited");
  sessionSourceOwnership.clear();
  runtimeState.stopAll("Codex App Server exited.");
  diagnostics.record("error", "codex", "Codex App Server exited.", { code, signal });
  broadcast({ ...bridgeStatus("restarting"), code, signal });
  console.error(`Codex App Server exited (code=${code}, signal=${signal}). Scheduling restart.`);
  scheduleCodexRestart(generation);
}

function scheduleCodexRestart(generation: number): void {
  if (!shouldScheduleCodexRestart({
    shuttingDown,
    generation,
    currentGeneration: codexGeneration,
    timerPending: Boolean(codexRestartTimer),
  })) return;
  codexRestartAttempt += 1;
  const delay = codexRestartDelayMs(codexRestartAttempt);
  diagnostics.record("warning", "codex", "Scheduled Codex App Server restart.", { attempt: codexRestartAttempt, retryInMs: delay });
  broadcast({ ...bridgeStatus("restarting"), restartAttempt: codexRestartAttempt, retryInMs: delay });
  codexRestartTimer = setTimeout(() => {
    codexRestartTimer = undefined;
    void replaceCodex(false);
  }, delay);
  codexRestartTimer.unref();
}

async function replaceCodex(stopCurrent: boolean, reason = "worker-replaced"): Promise<void> {
  if (shuttingDown) return;
  const previous = codex;
  clearThreadControl(reason);
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
    if (!shouldReplaceUnreadyCodex({
      shuttingDown,
      generation,
      currentGeneration: codexGeneration,
      ready: codexReady,
    })) return;
    console.error("[codex] initialization timed out; replacing App Server.");
    void (async () => {
      await failPendingRequests("Codex 初始化超时，Relay 正在重新启动服务。", true);
      clearPendingApprovals("startup-timeout");
      await replaceCodex(true);
    })();
  }, codexStartupWatchdogMs);
  codexStartupTimer.unref();
}

async function failPendingRequests(message: string, notifyClients: boolean): Promise<void> {
  const deliveries: Promise<void>[] = [];
  for (const [bridgeId, pending] of pendingClientRequests.clear()) {
    rpcStartedAt.delete(bridgeId);
    if (!notifyClients) continue;
    const response = { error: { message } };
    if (pending.deliveryKey) deliveries.push(suspendDelivery(pending.deliveryKey, response));
    else send(pending.socket, { type: "rpcResult", id: pending.clientId, ...response });
  }
  for (const pending of pendingInternalRequests.values()) {
    clearTimeout(pending.timeout);
    pending.reject(new Error(message));
  }
  pendingInternalRequests.clear();
  await Promise.all(deliveries);
}

function requestCodexConfigReload(changedFiles: string[]): void {
  for (const file of changedFiles) changedCodexConfigFiles.add(file);
  if (!codexConfigReloadPending) {
    diagnostics.record("info", "codex", "Codex configuration changed; waiting to reload App Server.", {
      files: [...changedCodexConfigFiles],
      profileId: activeCodexProfile.id,
    });
  }
  codexConfigReloadPending = true;
  scheduleCodexConfigReload(300);
}

function scheduleCodexConfigReload(delayMs: number): void {
  if (shuttingDown || codexConfigReloadInProgress || codexConfigReloadTimer) return;
  codexConfigReloadTimer = setTimeout(() => {
    codexConfigReloadTimer = undefined;
    void reloadCodexConfigurationWhenIdle();
  }, delayMs);
  codexConfigReloadTimer.unref();
}

async function reloadCodexConfigurationWhenIdle(): Promise<void> {
  if (shuttingDown || !codexConfigReloadPending || codexConfigReloadInProgress) return;
  if (runtimeState.activeCount > 0 || pendingClientRequests.size > 0 || pendingServerRequests.size > 0) {
    scheduleCodexConfigReload(1_000);
    return;
  }

  codexConfigReloadInProgress = true;
  codexConfigReloadPending = false;
  const files = [...changedCodexConfigFiles];
  changedCodexConfigFiles.clear();
  diagnostics.record("info", "codex", "Reloading Codex App Server after configuration change.", {
    files,
    profileId: activeCodexProfile.id,
  });
  codexReady = false;
  broadcast({ ...bridgeStatus("reloading"), reason: "configuration-changed" });
  if (codexRestartTimer) clearTimeout(codexRestartTimer);
  codexRestartTimer = undefined;
  if (codexStartupTimer) clearTimeout(codexStartupTimer);
  codexStartupTimer = undefined;
  codexRestartAttempt = 0;
  try {
    await failPendingRequests("Codex configuration changed; Relay is reloading App Server.", true);
    await replaceCodex(true);
  } finally {
    codexConfigReloadInProgress = false;
    if (codexConfigReloadPending) scheduleCodexConfigReload(300);
  }
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

async function recoverPendingDeliveries(): Promise<void> {
  if (recoveringDeliveries || shuttingDown || !codexReady) return;
  const deliveries = deliveryRegistry.recoverable(activeCodexProfile.id);
  if (deliveries.length === 0) return;
  recoveringDeliveries = true;
  diagnostics.record("warning", "delivery", `Recovering ${deliveries.length} durable delivery request(s).`);
  try {
    try {
      const listed = await codexRequest("thread/list", { limit: 100, sortKey: "updated_at" }, 30_000);
      sessionActivity.observeThreadList(listed);
    } catch {}

    for (const delivery of deliveries) {
      if (shuttingDown || !codexReady || delivery.profileId !== activeCodexProfile.id) break;
      try {
        try {
          const read = await codexRequest("thread/read", { threadId: delivery.threadId, includeTurns: true }, 30_000);
          sessionActivity.observeThreadResume(read);
        } catch {}
        const status = await untrackedDeliveryStatus(delivery.params);
        if (status.status === "completed") {
          const turnId = typeof status.turnId === "string" ? status.turnId : undefined;
          const snapshot = await sessionActivity.turnSnapshot(delivery.threadId);
          if (snapshot.isRunning && turnId) runtimeState.observeTurnStart(delivery.threadId, { id: turnId });
          const result = delivery.method === "turn/start"
            ? { ...(turnId ? { turn: { id: turnId }, turnId } : {}) }
            : { ...(turnId ? { turnId } : {}) };
          await completeDelivery(delivery.key, { result });
          diagnostics.record("info", "delivery", `Recovered completed ${delivery.method} from session history.`);
          continue;
        }

        await deliveryRegistry.bindBridgeRequest(delivery.key, `recovery.${nextInternalRequestId}`);
        const access = await ensureThreadControl(delivery.threadId);
        if (access.mode !== "relay-write") throw new Error("此任务当前由另一个 Codex 实例控制，Relay 无法恢复待发送消息。");
        const result = await codexRequest(delivery.method, delivery.params);
        await completeDelivery(delivery.key, { result });
        if (delivery.method === "turn/start") {
          runtimeState.observeTurnStart(delivery.threadId, result.turn);
          desktopSync.activateThread(delivery.threadId, "turn-started");
        } else if (delivery.method === "turn/steer") {
          runtimeState.observeTurnStart(delivery.threadId, { id: result.turnId });
          desktopSync.activateThread(delivery.threadId, "turn-steered");
        }
        diagnostics.record("info", "delivery", `Resumed ${delivery.method} after service recovery.`);
      } catch (error) {
        if (!codexReady || shuttingDown) break;
        const message = error instanceof Error ? error.message : "Could not recover the durable delivery.";
        await completeDelivery(delivery.key, { error: { message } });
        diagnostics.record("error", "delivery", message, { method: delivery.method, threadId: delivery.threadId });
      }
    }
  } finally {
    recoveringDeliveries = false;
  }
}

async function dispatchAllQueuedPrompts(): Promise<void> {
  for (const threadId of new Set(promptQueue.list(activeCodexProfile.id).map((item) => item.threadId))) {
    void dispatchNextQueuedPrompt(threadId);
  }
}

async function dispatchNextQueuedPrompt(threadId: string, completedTurnId?: string): Promise<void> {
  if (!codexReady || dispatchingQueueThreads.has(threadId)) return;
  const next = promptQueue.peek(activeCodexProfile.id, threadId);
  if (!next) return;
  if (next.waitForTurnId && completedTurnId !== next.waitForTurnId) {
    const observed = await sessionActivity.turnSnapshot(threadId);
    if (!queuedPromptWaitSatisfied(next, observed, completedTurnId)) {
      scheduleQueueRetry(threadId);
      return;
    }
  }
  const runtime = await runtimeState.snapshotWithExternal(threadId, sessionActivity);
  if (runtime.known && runtime.isRunning) {
    scheduleQueueRetry(threadId);
    return;
  }
  dispatchingQueueThreads.add(threadId);
  try {
    const access = await ensureThreadControl(threadId);
    if (access.mode !== "relay-write") throw new Error("Another Codex instance owns this queued task.");
    const params: JsonObject = {
      threadId,
      clientUserMessageId: next.clientUserMessageId,
      input: next.input,
      summary: "auto",
      ...(next.approvalPolicy ? { approvalPolicy: next.approvalPolicy } : {}),
      ...(next.sandboxPolicy ? { sandboxPolicy: next.sandboxPolicy } : {}),
      ...(next.model ? { model: next.model } : {}),
      ...(next.effort ? { effort: next.effort } : {}),
    };
    performanceMetrics.recordTurnReceived(params);
    performanceMetrics.recordTurnForwarded(next.clientUserMessageId);
    const result = await codexRequest("turn/start", params);
    const turn = isObject(result.turn) ? result.turn : {};
    performanceMetrics.recordTurnAccepted(
      next.clientUserMessageId,
      typeof turn.id === "string" ? turn.id : undefined,
    );
    await promptQueue.remove(next.id);
    runtimeState.observeTurnStart(threadId, result.turn);
    desktopSync.activateThread(threadId, "queued-turn-started");
    broadcastPromptQueue(threadId);
  } catch (error) {
    performanceMetrics.recordTurnRejected(next.clientUserMessageId);
    console.error(`[queue] ${threadId}: ${error instanceof Error ? error.message : error}`);
    scheduleQueueRetry(threadId);
  } finally {
    dispatchingQueueThreads.delete(threadId);
    if (threadControl.hasPendingRelease) scheduleThreadControlRelease(100);
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
  if (deliveryRegistry.pendingCountFor(activeCodexProfile.id) > 0) throw new Error("仍有消息等待 Codex 确认，请稍后再切换 Codex 实例。");
  if (pendingServerRequests.size > 0) throw new Error("请先处理当前审批，再切换 Codex 实例。");

  const available = await codexProfiles.list();
  const requested = available.find((profile) => profile.id === profileId);
  if (!requested) throw new Error("找不到所选 Codex 实例，请刷新后重试。");
  if (requested.active) return requested;

  activeCodexProfile = await codexProfiles.select(profileId);
  codexRuntimeInfo = inspectCodexRuntime(codexProfiles.activeCodexHome, config.codexBin);
  await codexConfigMonitor.setCodexHome(codexProfiles.activeCodexHome);
  codexConfigReloadPending = false;
  changedCodexConfigFiles.clear();
  if (codexConfigReloadTimer) clearTimeout(codexConfigReloadTimer);
  codexConfigReloadTimer = undefined;
  codexReady = false;
  broadcast(bridgeStatus("switching"));
  for (const client of clients) {
    sessionSubscriptions.open(client);
  }
  sessionActivity.dispose();
  sessionActivity = new SessionActivityTracker();
  fileTransfer.resetConversationAccess();
  sessionSourceOwnership.clear();
  clearThreadControl("profile-switch");
  runtimeState = new RuntimeStateTracker();
  publishedRuntimeSignatures.clear();
  monitoredThreadIds = [];
  externallyRunningThreadIds.clear();
  externalCompletionTracker.reset();
  threadTitles.clear();

  const previous = codex;
  codexGeneration += 1;
  if (codexRestartTimer) clearTimeout(codexRestartTimer);
  codexRestartTimer = undefined;
  if (codexStartupTimer) clearTimeout(codexStartupTimer);
  if (threadControlReleaseTimer) clearTimeout(threadControlReleaseTimer);
  codexStartupTimer = undefined;
  threadControlReleaseTimer = undefined;
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
  clearInterval(externalSessionPollInterval);
  clearInterval(externalSessionDiscoveryInterval);
  codexConfigMonitor.stop();
  if (codexConfigReloadTimer) clearTimeout(codexConfigReloadTimer);
  if (codexRestartTimer) clearTimeout(codexRestartTimer);
  if (codexStartupTimer) clearTimeout(codexStartupTimer);
  if (threadControlReleaseTimer) clearTimeout(threadControlReleaseTimer);
  for (const timer of queueRetryTimers.values()) clearTimeout(timer);
  queueRetryTimers.clear();
  clearPendingApprovals("bridge-shutdown");
  for (const client of clients) client.close(1001, "Bridge shutting down");
  sessionActivity.dispose();
  void Promise.all([
    failPendingRequests("Relay Bridge 正在关闭。", true),
    fileTransfer.dispose(),
    codex.stop(),
    diagnostics.flush(),
  ])
    .finally(() => httpServer.close(() => process.exit(0)));
}

process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);
}

void main().catch((error) => {
  console.error(error instanceof Error ? error.stack ?? error.message : error);
  process.exit(1);
});
