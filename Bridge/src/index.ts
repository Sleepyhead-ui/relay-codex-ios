import { createServer } from "node:http";
import { WebSocketServer, WebSocket } from "ws";
import qrcode from "qrcode-terminal";
import { CodexAppServer } from "./codexAppServer.js";
import { loadConfig } from "./config.js";
import { DesktopSync } from "./desktopSync.js";
import { FileTransferManager } from "./fileTransfer.js";
import { isAuthorized, isObject, parseClientMessage, type JsonObject } from "./protocol.js";

interface PendingClientRequest {
  socket: WebSocket;
  clientId: string;
  method: string;
  params: JsonObject;
}

const config = await loadConfig();
const clients = new Set<WebSocket>();
const clientLiveness = new WeakMap<WebSocket, boolean>();
const pendingClientRequests = new Map<string, PendingClientRequest>();
const pendingServerRequests = new Map<string, JsonObject>();
let nextRequestId = 1;
let codexReady = false;
const desktopSync = new DesktopSync(
  config.desktopSync,
  config.desktopCdpPort,
  config.desktopAppPath,
  (message) => console.log(`[desktop] ${message}`),
  (status) => broadcast({ type: "bridgeStatus", status: codexReady ? "ready" : "starting", desktopSync: status }),
);
const fileTransfer = new FileTransferManager(config.defaultCwd, config.filesRoot);

const codex = new CodexAppServer(config.codexBin, {
  onResponse: handleCodexResponse,
  onNotification: handleCodexNotification,
  onRequest: handleCodexRequest,
  onLog: (message) => {
    if (message) console.log(`[codex] ${message}`);
    if (message.includes("initialized")) {
      codexReady = true;
      broadcast({ type: "bridgeStatus", status: "ready", desktopSync: desktopSync.status });
    }
  },
  onExit: (code, signal) => {
    codexReady = false;
    broadcast({ type: "bridgeStatus", status: "codexExited", code, signal });
    console.error(`Codex App Server exited (code=${code}, signal=${signal}). Restart Relay Bridge.`);
  },
});

await codex.start();

const httpServer = createServer((request, response) => {
  if (request.url === "/health") {
    response.writeHead(codexReady ? 200 : 503, { "content-type": "application/json" });
    response.end(JSON.stringify({
      status: codexReady ? "ready" : "starting",
      clients: clients.size,
      uptimeSeconds: Math.floor(process.uptime()),
      desktopSync: desktopSync.status,
    }));
    return;
  }
  response.writeHead(404).end();
});

const webSocketServer = new WebSocketServer({ noServer: true, maxPayload: 2 * 1024 * 1024 });

httpServer.on("upgrade", (request, socket, head) => {
  if (request.headers.origin) {
    socket.write("HTTP/1.1 403 Forbidden\r\nConnection: close\r\n\r\n");
    socket.destroy();
    return;
  }
  if (!isAuthorized(request.headers.authorization, config.token)) {
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
  console.log(`[socket] mobile client connected (${clients.size} total)`);
  send(socket, { type: "bridgeStatus", status: codexReady ? "ready" : "starting", desktopSync: desktopSync.status });
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
  socket.on("close", () => {
    clients.delete(socket);
    clientLiveness.delete(socket);
    console.log(`[socket] mobile client disconnected (${clients.size} total)`);
  });
  socket.on("error", (error) => console.error(`[socket] ${error.message}`));
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
    if (message.method.startsWith("relay/")) {
      try {
        const result = await fileTransfer.handle(message.method, message.params);
        send(socket, { type: "rpcResult", id: message.id, result });
      } catch (error) {
        send(socket, {
          type: "rpcResult",
          id: message.id,
          error: { message: error instanceof Error ? error.message : "File transfer failed." },
        });
      }
      return;
    }
    if (!codexReady) throw new Error("Codex is still starting.");
    const bridgeId = `relay.${nextRequestId++}`;
    const params = { ...message.params };
    if (message.method === "thread/start" && config.defaultCwd && !("cwd" in params)) {
      params.cwd = config.defaultCwd;
    }
    pendingClientRequests.set(bridgeId, { socket, clientId: message.id, method: message.method, params });
    codex.send({ method: message.method, id: bridgeId, params });
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
  const payload: JsonObject = { type: "rpcResult", id: pending.clientId };
  if ("result" in message) payload.result = message.result;
  if ("error" in message) payload.error = message.error;
  send(pending.socket, payload);
  if (pending.method === "turn/start" && !("error" in message)) {
    desktopSync.activateThread(pending.params.threadId, "turn-started");
  }
}

function handleCodexNotification(message: JsonObject): void {
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

function shutdown(): void {
  clearInterval(heartbeatInterval);
  for (const client of clients) client.close(1001, "Bridge shutting down");
  codex.stop();
  httpServer.close(() => process.exit(0));
}

process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);
