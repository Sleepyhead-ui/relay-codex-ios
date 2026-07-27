const fs = require("node:fs");
const http = require("node:http");
const https = require("node:https");
const path = require("node:path");
const { spawn } = require("node:child_process");
const { serviceHostRestartDelayMs, serviceHostUnhealthyRestartThreshold } = require("./service-host-policy.cjs");

const [bridgeEntry, heartbeatPath, hostPidPath, bridgePidPath] = process.argv.slice(2);
const endpoint = process.env.RELAY_ADVERTISE_URL;
const healthEndpoint = process.env.RELAY_HEALTH_URL || endpoint;
const version = process.env.RELAY_SERVICE_VERSION || "unknown";
const startedAt = Number(process.env.RELAY_SERVICE_STARTED_AT) || Date.now();

if (!bridgeEntry || !heartbeatPath || !hostPidPath || !bridgePidPath || !endpoint) process.exit(2);

let bridgeChild;
let bridgePid;
let restartCount = 0;
let restartAttempt = 0;
let nextStartAt = 0;
let lastExit;
let ticking = false;
let shuttingDown = false;
let hasSeenHealthy = process.env.RELAY_SERVICE_EXPECT_EXISTING === "1";
let healthMisses = 0;

if (!claimHostPid()) process.exit(0);

function processIsAlive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

function claimHostPid() {
  try {
    const existing = Number(fs.readFileSync(hostPidPath, "utf8").trim());
    if (Number.isInteger(existing) && existing > 0 && existing !== process.pid && processIsAlive(existing)) return false;
  } catch {}
  fs.mkdirSync(path.dirname(hostPidPath), { recursive: true });
  fs.writeFileSync(hostPidPath, `${process.pid}\n`, "utf8");
  return true;
}

function writeHeartbeat(state, health) {
  const heartbeat = {
    pid: process.pid,
    bridgePid,
    version,
    endpoint,
    state,
    restartCount,
    restartAttempt,
    updatedAt: Date.now(),
    startedAt,
    ...(lastExit ? { lastExit } : {}),
    ...(health ? { bridgeStatus: health.status, activeTurns: Number(health.activeTurns) || 0 } : {}),
  };
  const temporaryPath = `${heartbeatPath}.${process.pid}.tmp`;
  try {
    fs.mkdirSync(path.dirname(heartbeatPath), { recursive: true });
    fs.writeFileSync(temporaryPath, JSON.stringify(heartbeat), "utf8");
    fs.renameSync(temporaryPath, heartbeatPath);
  } catch {
    try { fs.writeFileSync(heartbeatPath, JSON.stringify(heartbeat), "utf8"); } catch {}
    try { fs.unlinkSync(temporaryPath); } catch {}
  }
}

function readHealth() {
  return new Promise((resolve) => {
    let url;
    try {
      url = new URL(healthEndpoint);
      url.protocol = url.protocol === "wss:" ? "https:" : "http:";
      url.pathname = "/health";
      url.search = "";
    } catch {
      resolve(undefined);
      return;
    }
    const client = url.protocol === "https:" ? https : http;
    const request = client.get(url, { timeout: 1_200 }, (response) => {
      let body = "";
      response.setEncoding("utf8");
      response.on("data", (chunk) => { body += chunk; });
      response.on("end", () => {
        try { resolve(JSON.parse(body)); } catch { resolve(undefined); }
      });
    });
    request.on("timeout", () => request.destroy());
    request.on("error", () => resolve(undefined));
  });
}

function spawnBridge() {
  if (bridgeChild || shuttingDown) return;
  try {
    const child = spawn(process.execPath, [bridgeEntry], {
      detached: true,
      windowsHide: true,
      stdio: ["ignore", "inherit", "inherit"],
      env: { ...process.env, RELAY_SERVICE_HOST_PID: String(process.pid) },
    });
    bridgeChild = child;
    bridgePid = child.pid;
    if (bridgePid) {
      fs.mkdirSync(path.dirname(bridgePidPath), { recursive: true });
      fs.writeFileSync(bridgePidPath, `${bridgePid}\n`, "utf8");
    }
    child.once("error", (error) => recordExit(undefined, error.message));
    child.once("exit", (code, signal) => recordExit(code, signal));
    child.unref();
  } catch (error) {
    recordExit(undefined, error instanceof Error ? error.message : String(error), true);
  }
}

function adoptBridgePid() {
  if (bridgePid) return;
  try {
    const candidate = Number(fs.readFileSync(bridgePidPath, "utf8").trim());
    if (Number.isInteger(candidate) && candidate > 0 && processIsAlive(candidate)) bridgePid = candidate;
  } catch {}
}

function terminateUnhealthyBridge() {
  const managed = Boolean(bridgeChild);
  const pid = bridgePid;
  if (!pid) return;
  writeHeartbeat("restarting-unhealthy");
  try { process.kill(pid); } catch {}
  if (!managed) recordExit(undefined, "health-timeout", true);
}

function recordExit(code, signal, force = false) {
  if (!force && !bridgeChild && !bridgePid) return;
  bridgeChild = undefined;
  bridgePid = undefined;
  restartCount += 1;
  restartAttempt += 1;
  nextStartAt = Date.now() + serviceHostRestartDelayMs(restartAttempt);
  lastExit = { at: Date.now(), code: Number.isInteger(code) ? code : undefined, signal: signal || undefined };
  try { fs.unlinkSync(bridgePidPath); } catch {}
  writeHeartbeat("waiting-to-restart");
}

async function tick() {
  if (ticking || shuttingDown) return;
  ticking = true;
  try {
    const health = await readHealth();
    if (health) {
      hasSeenHealthy = true;
      healthMisses = 0;
      adoptBridgePid();
      if (health.status === "ready") restartAttempt = 0;
      writeHeartbeat(bridgeChild ? "managed" : "monitoring", health);
      return;
    }
    healthMisses += 1;
    if (bridgePid && !processIsAlive(bridgePid)) recordExit(undefined, "process-exited", true);
    if (bridgeChild || bridgePid) {
      if (healthMisses >= serviceHostUnhealthyRestartThreshold) terminateUnhealthyBridge();
      else writeHeartbeat(hasSeenHealthy ? "bridge-unresponsive" : "starting");
      return;
    }
    if (Date.now() >= nextStartAt && (!hasSeenHealthy || healthMisses >= 3)) spawnBridge();
    writeHeartbeat(bridgeChild ? "starting" : "waiting-to-restart");
  } finally {
    ticking = false;
  }
}

function shutdown() {
  if (shuttingDown) return;
  shuttingDown = true;
  writeHeartbeat("stopping");
  try { fs.unlinkSync(hostPidPath); } catch {}
  process.exit(0);
}

process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);
process.on("exit", () => {
  try {
    const current = Number(fs.readFileSync(hostPidPath, "utf8").trim());
    if (current === process.pid) fs.unlinkSync(hostPidPath);
  } catch {}
});

writeHeartbeat("starting-host");
void tick();
setInterval(() => void tick(), 2_000);
