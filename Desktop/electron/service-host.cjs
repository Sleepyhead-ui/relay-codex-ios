const fs = require("node:fs");
const http = require("node:http");
const https = require("node:https");
const path = require("node:path");
const { spawn, spawnSync } = require("node:child_process");
const {
  bridgeUpgradeBlockers,
  bridgeVersionMatches,
  serviceHostHeartbeatStaleMs,
  serviceHostRestartDelayMs,
  serviceHostUnhealthyRestartThreshold,
} = require("./service-host-policy.cjs");

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
const hostLockPath = `${hostPidPath}.lock`;

if (!claimHostPid()) process.exit(0);
terminateLegacyServiceHosts();

function processIsAlive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

function claimHostPid() {
  fs.mkdirSync(path.dirname(hostPidPath), { recursive: true });
  for (let attempt = 0; attempt < 3; attempt += 1) {
    const candidatePath = `${hostLockPath}.candidate-${process.pid}-${attempt}`;
    try {
      fs.mkdirSync(candidatePath);
      fs.writeFileSync(path.join(candidatePath, "owner"), `${process.pid}\n`, "utf8");
      fs.renameSync(candidatePath, hostLockPath);
      fs.writeFileSync(hostPidPath, `${process.pid}\n`, "utf8");
      return true;
    } catch (error) {
      try { fs.rmSync(candidatePath, { recursive: true, force: true }); } catch {}
      if (!["EEXIST", "ENOTEMPTY", "EPERM", "EACCES"].includes(error?.code)) return false;
      let owner;
      try { owner = Number(fs.readFileSync(path.join(hostLockPath, "owner"), "utf8").trim()); } catch {}
      if (Number.isInteger(owner) && owner > 0 && hostClaimIsActive(owner)) return false;
      try {
        const stalePath = `${hostLockPath}.stale-${process.pid}-${Date.now()}`;
        fs.renameSync(hostLockPath, stalePath);
        fs.rmSync(stalePath, { recursive: true, force: true });
      } catch {
        return false;
      }
    }
  }
  return false;
}

function hostClaimIsActive(owner) {
  if (!processIsAlive(owner)) return false;
  try {
    const heartbeat = JSON.parse(fs.readFileSync(heartbeatPath, "utf8"));
    const updatedAt = Number(heartbeat?.updatedAt);
    if (
      Number(heartbeat?.pid) === owner
      && Number.isFinite(updatedAt)
      && Date.now() - updatedAt <= serviceHostHeartbeatStaleMs
    ) return true;
  } catch {}

  // A newly created Host has not necessarily written its first heartbeat yet.
  // After that grace period, a live but reused PID must not keep a stale lock.
  try {
    const lockAgeMs = Date.now() - fs.statSync(hostLockPath).mtimeMs;
    return lockAgeMs <= serviceHostHeartbeatStaleMs;
  } catch {
    return false;
  }
}

function terminateLegacyServiceHosts() {
  if (process.platform !== "win32") return;
  const script = [
    `$current = ${process.pid}`,
    "Get-CimInstance Win32_Process -Filter \"Name = 'node.exe'\" | Where-Object { $_.ProcessId -ne $current -and $_.CommandLine -like '*relay-desktop*service-runtime*service-host.cjs*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }",
  ].join("; ");
  try {
    spawnSync("powershell.exe", ["-NoProfile", "-NonInteractive", "-Command", script], {
      windowsHide: true,
      stdio: "ignore",
      timeout: 5_000,
    });
  } catch {}
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
    ...(health ? {
      bridgeStatus: health.status,
      bridgeVersion: typeof health.version === "string" ? health.version : undefined,
      activeTurns: Number(health.activeTurns) || 0,
    } : {}),
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

function readHealthAt(candidateEndpoint) {
  return new Promise((resolve) => {
    let url;
    try {
      url = new URL(candidateEndpoint);
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

async function readHealth() {
  const advertisedHealth = await readHealthAt(endpoint);
  if (advertisedHealth) return advertisedHealth;
  if (healthEndpoint === endpoint) return undefined;
  return readHealthAt(healthEndpoint);
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
  if (bridgePid) return;
  const discovered = discoverRelayBridgePid();
  if (!discovered) return;
  bridgePid = discovered;
  try {
    fs.mkdirSync(path.dirname(bridgePidPath), { recursive: true });
    fs.writeFileSync(bridgePidPath, `${bridgePid}\n`, "utf8");
  } catch {}
}

function discoverRelayBridgePid() {
  if (process.platform !== "win32") return undefined;
  let port;
  try { port = Number(new URL(endpoint).port || 8765); } catch { return undefined; }
  if (!Number.isInteger(port) || port <= 0 || port > 65_535) return undefined;
  const script = [
    `$port = ${port}`,
    "Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue | Select-Object -ExpandProperty OwningProcess -Unique | ForEach-Object { $candidatePid = $_; $candidate = Get-CimInstance Win32_Process -Filter \"ProcessId = $candidatePid\" -ErrorAction SilentlyContinue; if ($candidate.CommandLine -like '*relay-desktop*bridge*dist*index*') { $candidatePid } }",
  ].join("; ");
  try {
    const result = spawnSync("powershell.exe", ["-NoProfile", "-NonInteractive", "-Command", script], {
      windowsHide: true,
      encoding: "utf8",
      timeout: 5_000,
    });
    return String(result.stdout || "")
      .split(/\s+/)
      .map(Number)
      .find((candidate) => Number.isInteger(candidate) && candidate > 0 && candidate !== process.pid && processIsAlive(candidate));
  } catch {
    return undefined;
  }
}

function terminateUnhealthyBridge() {
  const managed = Boolean(bridgeChild);
  const pid = bridgePid;
  if (!pid) return;
  writeHeartbeat("restarting-unhealthy");
  try { process.kill(pid); } catch {}
  if (!managed) recordExit(undefined, "health-timeout", true);
}

function terminateOutdatedBridge(health) {
  const managed = Boolean(bridgeChild);
  const pid = bridgePid;
  if (!pid) {
    writeHeartbeat("upgrade-blocked-missing-bridge-pid", health);
    return;
  }
  writeHeartbeat("upgrading-bridge", health);
  try { process.kill(pid); } catch {}
  if (!managed) {
    recordExit(undefined, "version-upgrade", true);
    nextStartAt = Date.now();
    hasSeenHealthy = false;
    healthMisses = 0;
  }
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
      if (!bridgeVersionMatches(health, version)) {
        const blockers = bridgeUpgradeBlockers(health);
        if (blockers.length > 0) writeHeartbeat("waiting-for-idle-upgrade", health);
        else terminateOutdatedBridge(health);
        return;
      }
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
  releaseHostClaim();
  process.exit(0);
}

function releaseHostClaim() {
  try {
    const owner = Number(fs.readFileSync(path.join(hostLockPath, "owner"), "utf8").trim());
    if (owner === process.pid) fs.rmSync(hostLockPath, { recursive: true, force: true });
  } catch {}
  try {
    const current = Number(fs.readFileSync(hostPidPath, "utf8").trim());
    if (current === process.pid) fs.unlinkSync(hostPidPath);
  } catch {}
}

process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);
process.on("exit", () => {
  releaseHostClaim();
});

writeHeartbeat("starting-host");
void tick();
setInterval(() => void tick(), 2_000);
