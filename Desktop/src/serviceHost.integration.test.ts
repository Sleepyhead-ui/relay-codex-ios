import { afterEach, describe, expect, it } from "vitest";
import { spawn } from "node:child_process";
import fs from "node:fs";
import http from "node:http";
import net from "node:net";
import os from "node:os";
import path from "node:path";

const spawnedPids = new Set<number>();

afterEach(() => {
  for (const pid of spawnedPids) {
    try { process.kill(pid); } catch {}
  }
  spawnedPids.clear();
});

describe("Relay service host", () => {
  it("restarts Bridge after an unexpected exit without Desktop", async () => {
    const directory = fs.mkdtempSync(path.join(os.tmpdir(), "relay-service-host-"));
    const counterPath = path.join(directory, "starts.txt");
    const heartbeatPath = path.join(directory, "heartbeat.json");
    const hostPidPath = path.join(directory, "host.pid");
    const bridgePidPath = path.join(directory, "bridge.pid");
    const fakeBridgePath = path.join(directory, "fake-bridge.cjs");
    const port = await availablePort();
    fs.writeFileSync(fakeBridgePath, `
      const fs = require("node:fs");
      const http = require("node:http");
      const counterPath = process.env.FAKE_BRIDGE_COUNTER;
      const starts = Number(fs.existsSync(counterPath) ? fs.readFileSync(counterPath, "utf8") : "0") + 1;
      fs.writeFileSync(counterPath, String(starts), "utf8");
      if (starts === 1) setTimeout(() => process.exit(7), 100);
      else http.createServer((_request, response) => {
        response.writeHead(200, { "content-type": "application/json" });
        response.end(JSON.stringify({ status: "ready", activeTurns: 0 }));
      }).listen(Number(process.env.RELAY_PORT), process.env.RELAY_HOST);
    `, "utf8");

    const hostPath = path.resolve(process.cwd(), "electron/service-host.cjs");
    const host = spawn(process.execPath, [hostPath, fakeBridgePath, heartbeatPath, hostPidPath, bridgePidPath], {
      windowsHide: true,
      stdio: "ignore",
      env: {
        ...process.env,
        RELAY_HOST: "127.0.0.1",
        RELAY_PORT: String(port),
        RELAY_ADVERTISE_URL: `ws://127.0.0.1:${port}`,
        RELAY_SERVICE_VERSION: "test",
        FAKE_BRIDGE_COUNTER: counterPath,
      },
    });
    if (host.pid) spawnedPids.add(host.pid);

    await waitFor(async () => Number(readText(counterPath)) >= 2 && await healthReady(port), 12_000);
    const heartbeat = JSON.parse(fs.readFileSync(heartbeatPath, "utf8"));
    if (heartbeat.bridgePid) spawnedPids.add(Number(heartbeat.bridgePid));

    expect(Number(readText(counterPath))).toBeGreaterThanOrEqual(2);
    expect(heartbeat.pid).toBe(host.pid);
    expect(heartbeat.restartCount).toBeGreaterThanOrEqual(1);
    expect(["managed", "starting"]).toContain(heartbeat.state);
    expect(await healthReady(port)).toBe(true);
  }, 15_000);
});

function readText(filePath: string): string {
  try { return fs.readFileSync(filePath, "utf8"); } catch { return ""; }
}

async function availablePort(): Promise<number> {
  return new Promise((resolve, reject) => {
    const server = net.createServer();
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      const port = typeof address === "object" && address ? address.port : 0;
      server.close((error) => error ? reject(error) : resolve(port));
    });
  });
}

async function healthReady(port: number): Promise<boolean> {
  return new Promise((resolve) => {
    const request = http.get(`http://127.0.0.1:${port}/health`, { timeout: 300 }, (response) => {
      response.resume();
      resolve(response.statusCode === 200);
    });
    request.on("timeout", () => request.destroy());
    request.on("error", () => resolve(false));
  });
}

async function waitFor(predicate: () => Promise<boolean>, timeoutMs: number): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (await predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error(`Timed out after ${timeoutMs}ms`);
}
