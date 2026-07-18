import test from "node:test";
import assert from "node:assert/strict";
import { createServer } from "node:http";
import { WebSocketServer } from "ws";
import { DesktopSync } from "../dist/desktopSync.js";

test("enhanced desktop sync sends a renderer reload over localhost CDP", async (t) => {
  let received;
  const server = createServer((request, response) => {
    if (request.url !== "/json/list") return response.writeHead(404).end();
    const address = server.address();
    response.writeHead(200, { "content-type": "application/json" });
    response.end(JSON.stringify([{
      type: "page",
      title: "Codex",
      url: "app://codex/thread",
      webSocketDebuggerUrl: `ws://127.0.0.1:${address.port}/devtools/page/relay-test`,
    }]));
  });
  const webSockets = new WebSocketServer({ noServer: true });
  server.on("upgrade", (request, socket, head) => {
    webSockets.handleUpgrade(request, socket, head, (client) => webSockets.emit("connection", client));
  });
  webSockets.on("connection", (client) => {
    client.on("message", (data) => { received = JSON.parse(data.toString("utf8")); });
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  t.after(() => new Promise((resolve) => webSockets.close(() => server.close(resolve))));

  const port = server.address().port;
  const sync = new DesktopSync(true, port, undefined, () => {});
  assert.equal(await sync.reloadDesktopRenderer(), true);
  await new Promise((resolve) => setTimeout(resolve, 50));
  assert.deepEqual(received, { id: 1, method: "Page.reload", params: { ignoreCache: false } });
});
