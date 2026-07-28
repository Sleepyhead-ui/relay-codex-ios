const serviceHostHeartbeatStaleMs = 12_000;
const serviceHostUnhealthyRestartThreshold = 15;

function bridgeBindHost(advertisedHostname) {
  const hostname = String(advertisedHostname || "").trim().toLowerCase();
  if (hostname === "127.0.0.1" || hostname === "localhost") return "127.0.0.1";
  if (hostname === "::1" || hostname === "[::1]") return "::1";
  // Tailscale can briefly remove its adapter during network changes. Binding the
  // service to the adapter address would terminate Bridge and its active Codex.
  return "0.0.0.0";
}

function serviceHostRestartDelayMs(attempt) {
  const normalized = Math.max(1, Math.trunc(Number.isFinite(Number(attempt)) ? Number(attempt) : 1));
  return Math.min(1_000 * Math.pow(1.8, normalized - 1), 30_000);
}

function serviceHostStateFromHeartbeat(heartbeat, options = {}) {
  if (!heartbeat || typeof heartbeat !== "object") return { running: false, reason: "missing" };
  const now = Number(options.now ?? Date.now());
  const updatedAt = Number(heartbeat.updatedAt);
  const pid = Number(heartbeat.pid);
  if (!Number.isFinite(updatedAt) || now - updatedAt > serviceHostHeartbeatStaleMs) {
    return { running: false, reason: "stale" };
  }
  if (!Number.isInteger(pid) || pid <= 0) return { running: false, reason: "invalid-pid" };
  if (options.expectedEndpoint && heartbeat.endpoint !== options.expectedEndpoint) {
    return { running: false, reason: "endpoint-mismatch" };
  }
  const processIsAlive = options.processIsAlive ?? (() => true);
  if (!processIsAlive(pid)) return { running: false, reason: "exited" };
  return {
    running: true,
    reason: "healthy",
    pid,
    bridgePid: Number.isInteger(Number(heartbeat.bridgePid)) ? Number(heartbeat.bridgePid) : undefined,
    version: typeof heartbeat.version === "string" ? heartbeat.version : undefined,
    bridgeVersion: typeof heartbeat.bridgeVersion === "string" ? heartbeat.bridgeVersion : undefined,
    activeTurns: Math.max(0, Number(heartbeat.activeTurns) || 0),
    restartCount: Math.max(0, Number(heartbeat.restartCount) || 0),
    state: typeof heartbeat.state === "string" ? heartbeat.state : "monitoring",
    updatedAt,
  };
}

function loginItemSettings(autoStart, executablePath) {
  return {
    openAtLogin: Boolean(autoStart),
    path: executablePath,
    args: ["--relay-background"],
  };
}

function shouldReplaceServiceHost(supervisor, currentVersion) {
  return Boolean(
    supervisor?.running
    && supervisor.version
    && currentVersion
    && supervisor.version !== currentVersion,
  );
}

function bridgeVersionMatches(health, currentVersion) {
  return Boolean(health?.version && currentVersion && health.version === currentVersion);
}

function bridgeUpgradeBlockers(health) {
  if (!health || typeof health !== "object") return [];
  const fields = [
    ["activeTurns", "active-turns"],
    ["activeTransferCount", "active-transfers"],
    ["pendingRpcCount", "pending-rpc"],
    ["pendingApprovalCount", "pending-approvals"],
    ["queuedPromptCount", "queued-prompts"],
    ["pendingDeliveryCount", "pending-deliveries"],
  ];
  return fields
    .filter(([field]) => Math.max(0, Number(health[field]) || 0) > 0)
    .map(([, label]) => label);
}

module.exports = {
  bridgeBindHost,
  bridgeUpgradeBlockers,
  bridgeVersionMatches,
  loginItemSettings,
  serviceHostHeartbeatStaleMs,
  serviceHostRestartDelayMs,
  serviceHostStateFromHeartbeat,
  serviceHostUnhealthyRestartThreshold,
  shouldReplaceServiceHost,
};
