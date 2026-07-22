import { describe, expect, it } from "vitest";

const { serviceStateFromHealth, updateBlockers, updateReadinessForService } = require("../electron/update-policy.cjs") as {
  serviceStateFromHealth: (health?: Record<string, unknown>) => string;
  updateBlockers: (health?: Record<string, unknown>) => string[];
  updateReadinessForService: (health: Record<string, unknown> | undefined, serviceState: string) => string[];
};

describe("desktop update safety", () => {
  it("defers installation while work can still be lost", () => {
    const blockers = updateBlockers({
      status: "ready",
      activeTurns: 1,
      activeTransferCount: 1,
      pendingRpcCount: 2,
      pendingApprovalCount: 1,
      queuedPromptCount: 3,
    });
    expect(blockers).toHaveLength(5);
    expect(blockers.join(" ")).toContain("任务正在运行");
    expect(blockers.join(" ")).toContain("文件仍在传输");
    expect(blockers.join(" ")).toContain("消息仍在排队");
  });

  it("allows an idle ready service or a stopped service", () => {
    expect(updateBlockers(undefined)).toEqual([]);
    expect(updateBlockers({ status: "ready", activeTurns: 0 })).toEqual([]);
  });

  it("treats ready with zero clients as degraded", () => {
    expect(serviceStateFromHealth({ status: "ready", clients: 0 })).toBe("degraded");
    expect(serviceStateFromHealth({ status: "ready", clients: 1 })).toBe("running");
    expect(serviceStateFromHealth({ status: "starting", clients: 0 })).toBe("starting");
  });

  it("fails closed when an online service temporarily stops answering health checks", () => {
    expect(updateReadinessForService(undefined, "running")).toEqual(["暂时无法确认远程任务状态"]);
    expect(updateReadinessForService(undefined, "stopped")).toEqual([]);
  });
});
