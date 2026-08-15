import { afterEach, describe, expect, it } from "vitest";
import { spawn } from "node:child_process";
import fs from "node:fs";
import http from "node:http";
import net from "node:net";
import os from "node:os";
import path from "node:path";

const spawnedPids = new Set<number>();
const PROCESS_READY_TIMEOUT_MS = 10_000;
const UPGRADE_TIMEOUT_MS = 12_000;
const UPGRADE_TEST_TIMEOUT_MS = 30_000;

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
        response.end(JSON.stringify({ status: "ready", version: process.env.RELAY_SERVICE_VERSION, activeTurns: 0 }));
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
        RELAY_HEALTH_URL: `http://127.0.0.1:${port}/health`,
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

  it("monitors Bridge through loopback while the advertised Tailscale address is unavailable", async () => {
    const directory = fs.mkdtempSync(path.join(os.tmpdir(), "relay-service-host-loopback-"));
    const heartbeatPath = path.join(directory, "heartbeat.json");
    const hostPidPath = path.join(directory, "host.pid");
    const bridgePidPath = path.join(directory, "bridge.pid");
    const fakeBridgePath = path.join(directory, "fake-bridge.cjs");
    const port = await availablePort();
    fs.writeFileSync(fakeBridgePath, `
      const http = require("node:http");
      http.createServer((_request, response) => {
        response.writeHead(200, { "content-type": "application/json" });
        response.end(JSON.stringify({ status: "ready", version: process.env.RELAY_SERVICE_VERSION, activeTurns: 1 }));
      }).listen(Number(process.env.RELAY_PORT), "127.0.0.1");
    `, "utf8");

    const hostPath = path.resolve(process.cwd(), "electron/service-host.cjs");
    const host = spawn(process.execPath, [hostPath, fakeBridgePath, heartbeatPath, hostPidPath, bridgePidPath], {
      windowsHide: true,
      stdio: "ignore",
      env: {
        ...process.env,
        RELAY_HOST: "0.0.0.0",
        RELAY_PORT: String(port),
        RELAY_ADVERTISE_URL: `ws://100.64.0.99:${port}`,
        RELAY_HEALTH_URL: `http://127.0.0.1:${port}/health`,
        RELAY_SERVICE_VERSION: "test",
      },
    });
    if (host.pid) spawnedPids.add(host.pid);

    await waitFor(async () => {
      try {
        const heartbeat = JSON.parse(fs.readFileSync(heartbeatPath, "utf8"));
        if (heartbeat.bridgePid) spawnedPids.add(Number(heartbeat.bridgePid));
        return heartbeat.bridgeStatus === "ready" && heartbeat.activeTurns === 1;
      } catch { return false; }
    }, 8_000);

    const heartbeat = JSON.parse(fs.readFileSync(heartbeatPath, "utf8"));
    expect(heartbeat.endpoint).toBe(`ws://100.64.0.99:${port}`);
    expect(heartbeat.restartCount).toBe(0);
  }, 10_000);

  it("allows only one Host to claim a concurrent startup", async () => {
    const directory = fs.mkdtempSync(path.join(os.tmpdir(), "relay-service-host-single-"));
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
      http.createServer((_request, response) => {
        response.writeHead(200, { "content-type": "application/json" });
        response.end(JSON.stringify({ status: "ready", version: process.env.RELAY_SERVICE_VERSION, activeTurns: 0 }));
      }).listen(Number(process.env.RELAY_PORT), "127.0.0.1");
    `, "utf8");

    const args = [path.resolve(process.cwd(), "electron/service-host.cjs"), fakeBridgePath, heartbeatPath, hostPidPath, bridgePidPath];
    const env = { ...process.env, RELAY_HOST: "127.0.0.1", RELAY_PORT: String(port), RELAY_ADVERTISE_URL: `ws://127.0.0.1:${port}`, RELAY_HEALTH_URL: `http://127.0.0.1:${port}/health`, RELAY_SERVICE_VERSION: "1.0.1", FAKE_BRIDGE_COUNTER: counterPath };
    const first = spawn(process.execPath, args, { windowsHide: true, stdio: "ignore", env });
    const second = spawn(process.execPath, args, { windowsHide: true, stdio: "ignore", env });
    if (first.pid) spawnedPids.add(first.pid);
    if (second.pid) spawnedPids.add(second.pid);

    await waitFor(async () => await healthReady(port), 8_000);
    await new Promise((resolve) => setTimeout(resolve, 500));
    const heartbeat = JSON.parse(fs.readFileSync(heartbeatPath, "utf8"));
    if (heartbeat.bridgePid) spawnedPids.add(Number(heartbeat.bridgePid));
    expect(Number(readText(counterPath))).toBe(1);
    expect([first.pid, second.pid]).toContain(heartbeat.pid);
  }, 10_000);

  it("recovers a stale Host lock", async () => {
    const directory = fs.mkdtempSync(path.join(os.tmpdir(), "relay-service-host-stale-"));
    const heartbeatPath = path.join(directory, "heartbeat.json");
    const hostPidPath = path.join(directory, "host.pid");
    const bridgePidPath = path.join(directory, "bridge.pid");
    const fakeBridgePath = path.join(directory, "fake-bridge.cjs");
    const port = await availablePort();
    fs.mkdirSync(`${hostPidPath}.lock`);
    fs.writeFileSync(path.join(`${hostPidPath}.lock`, "owner"), "2147483647\n");
    fs.writeFileSync(hostPidPath, "2147483647\n");
    fs.writeFileSync(fakeBridgePath, `
      const http = require("node:http");
      http.createServer((_request, response) => response.end(JSON.stringify({ status: "ready", version: process.env.RELAY_SERVICE_VERSION, activeTurns: 0 }))).listen(Number(process.env.RELAY_PORT), "127.0.0.1");
    `, "utf8");

    const host = spawnServiceHost(fakeBridgePath, heartbeatPath, hostPidPath, bridgePidPath, port, { RELAY_SERVICE_VERSION: "1.0.1" });
    await waitFor(async () => await healthReady(port), 8_000);
    const heartbeat = JSON.parse(fs.readFileSync(heartbeatPath, "utf8"));
    if (heartbeat.bridgePid) spawnedPids.add(Number(heartbeat.bridgePid));
    expect(heartbeat.pid).toBe(host.pid);
  }, 10_000);

  it("recovers a stale Host lock after its PID is reused", async () => {
    const directory = fs.mkdtempSync(path.join(os.tmpdir(), "relay-service-host-reused-pid-"));
    const heartbeatPath = path.join(directory, "heartbeat.json");
    const hostPidPath = path.join(directory, "host.pid");
    const bridgePidPath = path.join(directory, "bridge.pid");
    const fakeBridgePath = path.join(directory, "fake-bridge.cjs");
    const lockPath = `${hostPidPath}.lock`;
    const port = await availablePort();
    fs.mkdirSync(lockPath);
    fs.writeFileSync(path.join(lockPath, "owner"), `${process.pid}\n`);
    fs.writeFileSync(hostPidPath, `${process.pid}\n`);
    fs.writeFileSync(heartbeatPath, JSON.stringify({
      pid: process.pid,
      endpoint: `ws://127.0.0.1:${port}`,
      updatedAt: Date.now() - 60_000,
    }));
    const staleAt = new Date(Date.now() - 60_000);
    fs.utimesSync(lockPath, staleAt, staleAt);
    fs.writeFileSync(fakeBridgePath, `
      const http = require("node:http");
      http.createServer((_request, response) => response.end(JSON.stringify({ status: "ready", version: process.env.RELAY_SERVICE_VERSION, activeTurns: 0 }))).listen(Number(process.env.RELAY_PORT), "127.0.0.1");
    `, "utf8");

    const host = spawnServiceHost(fakeBridgePath, heartbeatPath, hostPidPath, bridgePidPath, port, { RELAY_SERVICE_VERSION: "1.0.1" });
    await waitFor(async () => await healthReady(port), 8_000);
    const heartbeat = JSON.parse(fs.readFileSync(heartbeatPath, "utf8"));
    if (heartbeat.bridgePid) spawnedPids.add(Number(heartbeat.bridgePid));
    expect(heartbeat.pid).toBe(host.pid);
  }, 10_000);

  it("waits for an active old Bridge, then upgrades it when idle", async () => {
    const directory = fs.mkdtempSync(path.join(os.tmpdir(), "relay-service-host-upgrade-"));
    const heartbeatPath = path.join(directory, "heartbeat.json");
    const hostPidPath = path.join(directory, "host.pid");
    const bridgePidPath = path.join(directory, "bridge.pid");
    const activityPath = path.join(directory, "active.txt");
    const startsPath = path.join(directory, "new-starts.txt");
    const oldBridgePath = path.join(directory, "old-bridge.cjs");
    const newBridgePath = path.join(directory, "new-bridge.cjs");
    const port = await availablePort();
    fs.writeFileSync(activityPath, "1");
    fs.writeFileSync(oldBridgePath, `
      const fs = require("node:fs"); const http = require("node:http");
      http.createServer((_request, response) => response.end(JSON.stringify({ status: "ready", version: "1.0.0", activeTurns: Number(fs.readFileSync(process.env.ACTIVITY_PATH, "utf8")) }))).listen(Number(process.env.RELAY_PORT), "127.0.0.1");
    `, "utf8");
    fs.writeFileSync(newBridgePath, `
      const fs = require("node:fs"); const http = require("node:http");
      fs.writeFileSync(process.env.NEW_STARTS_PATH, "1");
      http.createServer((_request, response) => response.end(JSON.stringify({ status: "ready", version: process.env.RELAY_SERVICE_VERSION, activeTurns: 0 }))).listen(Number(process.env.RELAY_PORT), "127.0.0.1");
    `, "utf8");
    const oldBridge = spawn(process.execPath, [oldBridgePath], { windowsHide: true, stdio: "ignore", env: { ...process.env, RELAY_PORT: String(port), ACTIVITY_PATH: activityPath } });
    if (oldBridge.pid) { spawnedPids.add(oldBridge.pid); fs.writeFileSync(bridgePidPath, `${oldBridge.pid}\n`); }
    await waitFor(async () => (await health(port))?.version === "1.0.0", PROCESS_READY_TIMEOUT_MS);
    const host = spawnServiceHost(newBridgePath, heartbeatPath, hostPidPath, bridgePidPath, port, { RELAY_SERVICE_VERSION: "1.0.1", RELAY_SERVICE_EXPECT_EXISTING: "1", NEW_STARTS_PATH: startsPath });

    await waitFor(async () => { try { return JSON.parse(fs.readFileSync(heartbeatPath, "utf8")).state === "waiting-for-idle-upgrade"; } catch { return false; } }, PROCESS_READY_TIMEOUT_MS);
    expect(fs.existsSync(startsPath)).toBe(false);
    expect(oldBridge.exitCode).toBeNull();
    fs.writeFileSync(activityPath, "0");
    await waitFor(async () => (await health(port))?.version === "1.0.1", UPGRADE_TIMEOUT_MS);
    const heartbeat = JSON.parse(fs.readFileSync(heartbeatPath, "utf8"));
    if (heartbeat.bridgePid) spawnedPids.add(Number(heartbeat.bridgePid));
    expect(readText(startsPath)).toBe("1");
    expect(host.pid).toBe(heartbeat.pid);
  }, UPGRADE_TEST_TIMEOUT_MS);

  it("checks the advertised address before loopback during an upgrade", async () => {
    const directory = fs.mkdtempSync(path.join(os.tmpdir(), "relay-desktop-service-host-advertised-"));
    const heartbeatPath = path.join(directory, "heartbeat.json");
    const hostPidPath = path.join(directory, "host.pid");
    const bridgePidPath = path.join(directory, "bridge.pid");
    const activityPath = path.join(directory, "active.txt");
    const oldBridgePath = path.join(directory, "bridge", "dist", "index.cjs");
    const newBridgePath = path.join(directory, "new-bridge.cjs");
    const port = await availablePort();
    fs.mkdirSync(path.dirname(oldBridgePath), { recursive: true });
    fs.writeFileSync(activityPath, "1");
    fs.writeFileSync(oldBridgePath, `
      const fs = require("node:fs"); const http = require("node:http");
      http.createServer((_request, response) => response.end(JSON.stringify({ status: "ready", version: "1.0.0", activeTurns: Number(fs.readFileSync(process.env.ACTIVITY_PATH, "utf8")) }))).listen(Number(process.env.RELAY_PORT), "127.0.0.2");
    `, "utf8");
    fs.writeFileSync(newBridgePath, `
      const http = require("node:http");
      http.createServer((_request, response) => response.end(JSON.stringify({ status: "ready", version: process.env.RELAY_SERVICE_VERSION, activeTurns: 0 }))).listen(Number(process.env.RELAY_PORT), "127.0.0.1");
    `, "utf8");
    const oldBridge = spawn(process.execPath, [oldBridgePath], { windowsHide: true, stdio: "ignore", env: { ...process.env, RELAY_PORT: String(port), ACTIVITY_PATH: activityPath } });
    if (oldBridge.pid) spawnedPids.add(oldBridge.pid);
    await waitFor(async () => (await health(port, "127.0.0.2"))?.version === "1.0.0", PROCESS_READY_TIMEOUT_MS);
    const hostPath = path.resolve(process.cwd(), "electron/service-host.cjs");
    const host = spawn(process.execPath, [hostPath, newBridgePath, heartbeatPath, hostPidPath, bridgePidPath], {
      windowsHide: true, stdio: "ignore",
      env: { ...process.env, RELAY_HOST: "127.0.0.1", RELAY_PORT: String(port), RELAY_ADVERTISE_URL: `ws://127.0.0.2:${port}`, RELAY_HEALTH_URL: `http://127.0.0.1:${port}/health`, RELAY_SERVICE_VERSION: "1.0.1", RELAY_SERVICE_EXPECT_EXISTING: "1" },
    });
    if (host.pid) spawnedPids.add(host.pid);

    await waitFor(async () => {
      try {
        const heartbeat = JSON.parse(fs.readFileSync(heartbeatPath, "utf8"));
        return heartbeat.state === "waiting-for-idle-upgrade"
          && Number(readText(bridgePidPath).trim()) === oldBridge.pid;
      } catch { return false; }
    }, PROCESS_READY_TIMEOUT_MS);
    expect(Number(readText(bridgePidPath).trim())).toBe(oldBridge.pid);
    expect(await health(port, "127.0.0.1")).toBeUndefined();
    fs.writeFileSync(activityPath, "0");
    await waitFor(async () => (await health(port, "127.0.0.1"))?.version === "1.0.1", UPGRADE_TIMEOUT_MS);
    const heartbeat = JSON.parse(fs.readFileSync(heartbeatPath, "utf8"));
    if (heartbeat.bridgePid) spawnedPids.add(Number(heartbeat.bridgePid));
  }, UPGRADE_TEST_TIMEOUT_MS);
});

function spawnServiceHost(fakeBridgePath: string, heartbeatPath: string, hostPidPath: string, bridgePidPath: string, port: number, extraEnv: Record<string, string>) {
  const hostPath = path.resolve(process.cwd(), "electron/service-host.cjs");
  const host = spawn(process.execPath, [hostPath, fakeBridgePath, heartbeatPath, hostPidPath, bridgePidPath], {
    windowsHide: true, stdio: "ignore",
    env: { ...process.env, RELAY_HOST: "127.0.0.1", RELAY_PORT: String(port), RELAY_ADVERTISE_URL: `ws://127.0.0.1:${port}`, RELAY_HEALTH_URL: `http://127.0.0.1:${port}/health`, ...extraEnv },
  });
  if (host.pid) spawnedPids.add(host.pid);
  return host;
}

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

async function health(port: number, hostname = "127.0.0.1"): Promise<Record<string, any> | undefined> {
  try {
    const response = await fetch(`http://${hostname}:${port}/health`);
    return response.ok ? await response.json() as Record<string, any> : undefined;
  } catch { return undefined; }
}

async function waitFor(predicate: () => Promise<boolean>, timeoutMs: number): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (await predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error(`Timed out after ${timeoutMs}ms`);
}
