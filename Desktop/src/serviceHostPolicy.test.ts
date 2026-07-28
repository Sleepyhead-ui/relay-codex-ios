import { describe, expect, it } from "vitest";

const {
  bridgeBindHost,
  bridgeUpgradeBlockers,
  bridgeVersionMatches,
  loginItemSettings,
  serviceHostHeartbeatStaleMs,
  serviceHostRestartDelayMs,
  serviceHostStateFromHeartbeat,
  serviceHostUnhealthyRestartThreshold,
  shouldReplaceServiceHost,
} = require("../electron/service-host-policy.cjs") as {
  bridgeBindHost: (advertisedHostname: string) => string;
  bridgeUpgradeBlockers: (health?: Record<string, unknown>) => string[];
  bridgeVersionMatches: (health: Record<string, unknown> | undefined, currentVersion: string) => boolean;
  loginItemSettings: (autoStart: boolean, executablePath: string) => { openAtLogin: boolean; path: string; args: string[] };
  serviceHostHeartbeatStaleMs: number;
  serviceHostRestartDelayMs: (attempt: number) => number;
  serviceHostUnhealthyRestartThreshold: number;
  serviceHostStateFromHeartbeat: (
    heartbeat: Record<string, unknown> | undefined,
    options?: { now?: number; expectedEndpoint?: string; processIsAlive?: (pid: number) => boolean },
  ) => { running: boolean; reason: string; pid?: number; restartCount?: number };
  shouldReplaceServiceHost: (supervisor: { running: boolean; version?: string }, currentVersion: string) => boolean;
};

describe("Relay service host policy", () => {
  it("keeps Bridge alive while a Tailscale adapter is temporarily unavailable", () => {
    expect(bridgeBindHost("100.80.115.15")).toBe("0.0.0.0");
    expect(bridgeBindHost("127.0.0.1")).toBe("127.0.0.1");
    expect(bridgeBindHost("localhost")).toBe("127.0.0.1");
  });

  it("keeps Bridge startup hidden at Windows login", () => {
    expect(loginItemSettings(true, "C:\\Relay Desktop.exe")).toEqual({
      openAtLogin: true,
      path: "C:\\Relay Desktop.exe",
      args: ["--relay-background"],
    });
    expect(loginItemSettings(false, "C:\\Relay Desktop.exe").openAtLogin).toBe(false);
  });

  it("accepts only a fresh heartbeat from a live host on the expected endpoint", () => {
    const now = 10_000_000;
    const heartbeat = { pid: 42, endpoint: "ws://100.80.115.15:8765", updatedAt: now - 1_000, restartCount: 3 };
    expect(serviceHostStateFromHeartbeat(heartbeat, {
      now,
      expectedEndpoint: "ws://100.80.115.15:8765",
      processIsAlive: (pid) => pid === 42,
    })).toMatchObject({ running: true, pid: 42, restartCount: 3 });
    expect(serviceHostStateFromHeartbeat(heartbeat, {
      now,
      expectedEndpoint: "ws://100.64.0.1:8765",
      processIsAlive: () => true,
    })).toMatchObject({ running: false, reason: "endpoint-mismatch" });
    expect(serviceHostStateFromHeartbeat({ ...heartbeat, updatedAt: now - serviceHostHeartbeatStaleMs - 1 }, {
      now,
      processIsAlive: () => true,
    })).toMatchObject({ running: false, reason: "stale" });
    expect(serviceHostStateFromHeartbeat(heartbeat, {
      now,
      processIsAlive: () => false,
    })).toMatchObject({ running: false, reason: "exited" });
  });

  it("backs off repeated Bridge crashes", () => {
    const delays = Array.from({ length: 12 }, (_, index) => serviceHostRestartDelayMs(index + 1));
    expect(delays[0]).toBe(1_000);
    expect(delays[1]).toBe(1_800);
    expect(delays.at(-1)).toBe(30_000);
    expect(delays.every((delay, index) => index === 0 || delay >= delays[index - 1]!)).toBe(true);
    expect(serviceHostUnhealthyRestartThreshold * 2_000).toBe(30_000);
  });

  it("hands supervision to a new Host version without replacing Bridge", () => {
    expect(shouldReplaceServiceHost({ running: true, version: "0.9.0" }, "0.9.1")).toBe(true);
    expect(shouldReplaceServiceHost({ running: true, version: "0.9.1" }, "0.9.1")).toBe(false);
    expect(shouldReplaceServiceHost({ running: false, version: "0.9.0" }, "0.9.1")).toBe(false);
  });

  it("requires the running Bridge to match the Desktop version", () => {
    expect(bridgeVersionMatches({ version: "1.0.1" }, "1.0.1")).toBe(true);
    expect(bridgeVersionMatches({ version: "1.0.0" }, "1.0.1")).toBe(false);
    expect(bridgeVersionMatches({}, "1.0.1")).toBe(false);
  });

  it("waits for all durable work before replacing an outdated Bridge", () => {
    expect(bridgeUpgradeBlockers({
      activeTurns: 1,
      activeTransferCount: 2,
      pendingRpcCount: 3,
      pendingApprovalCount: 4,
      queuedPromptCount: 5,
      pendingDeliveryCount: 6,
    })).toEqual([
      "active-turns", "active-transfers", "pending-rpc",
      "pending-approvals", "queued-prompts", "pending-deliveries",
    ]);
    expect(bridgeUpgradeBlockers({ status: "ready", activeTurns: 0 })).toEqual([]);
  });
});
