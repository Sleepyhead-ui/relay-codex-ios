const os = require("node:os");
const { WebSocket } = require("ws");

const cdpEndpoint = process.argv[2] || "http://127.0.0.1:9333/json/list";
const tailscaleAddress = Object.values(os.networkInterfaces())
  .flatMap((addresses) => addresses || [])
  .find((address) => address.family === "IPv4" && !address.internal && address.address.startsWith("100."))?.address;
const healthEndpoint = process.argv[3] || (tailscaleAddress ? `http://${tailscaleAddress}:8765/health` : "http://127.0.0.1:8765/health");

void main().catch((error) => {
  console.error(error instanceof Error ? error.message : error);
  process.exit(1);
});

async function main() {
  const page = await waitForPage();
  const socket = new WebSocket(page.webSocketDebuggerUrl);
  await new Promise((resolve, reject) => {
    socket.once("open", resolve);
    socket.once("error", reject);
  });
  const clicked = await evaluate(socket, `(() => {
    const button = [...document.querySelectorAll("button")].find((item) => item.textContent.includes("启动远程服务"));
    if (!button) return false;
    button.click();
    return true;
  })()`);
  socket.close();
  if (!clicked) throw new Error("Start remote service button was not found.");

  for (let attempt = 0; attempt < 80; attempt += 1) {
    await delay(250);
    try {
      const health = await (await fetch(healthEndpoint)).json();
      if (health.status === "ready") {
        console.log(JSON.stringify({ clicked, status: health.status, profile: health.codexProfile?.name, clients: health.clients }));
        return;
      }
    } catch {}
  }
  throw new Error("Desktop did not start the bundled remote service.");
}

async function waitForPage() {
  for (let attempt = 0; attempt < 40; attempt += 1) {
    try {
      const targets = await (await fetch(cdpEndpoint)).json();
      const page = targets.find((target) => target.type === "page" && target.title === "Relay Desktop");
      if (page) return page;
    } catch {}
    await delay(250);
  }
  throw new Error("Relay Desktop renderer was not available.");
}

function evaluate(socket, expression) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error("CDP evaluation timed out.")), 5_000);
    const handler = (data) => {
      const message = JSON.parse(data.toString());
      if (message.id !== 1) return;
      clearTimeout(timer);
      socket.off("message", handler);
      resolve(message.result?.result?.value);
    };
    socket.on("message", handler);
    socket.send(JSON.stringify({ id: 1, method: "Runtime.evaluate", params: { expression, returnByValue: true } }));
  });
}

function delay(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}
