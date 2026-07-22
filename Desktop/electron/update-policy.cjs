function updateBlockers(health) {
  if (!health) return [];
  const blockers = [];
  if (health.status !== "ready") blockers.push("Codex 正在启动或恢复");
  if (number(health.activeTurns) > 0) blockers.push(`${number(health.activeTurns)} 个任务正在运行`);
  if (number(health.pendingRpcCount) > 0) blockers.push(`${number(health.pendingRpcCount)} 个请求尚未完成`);
  if (number(health.pendingApprovalCount) > 0) blockers.push(`${number(health.pendingApprovalCount)} 项操作等待确认`);
  if (number(health.queuedPromptCount) > 0) blockers.push(`${number(health.queuedPromptCount)} 条消息仍在排队`);
  return blockers;
}

function serviceStateFromHealth(health) {
  if (!health) return "stopped";
  if (health.status !== "ready") return "starting";
  return number(health.clients) > 0 ? "running" : "degraded";
}

function updateReadinessForService(health, serviceState) {
  if (!health && ["running", "starting", "degraded"].includes(serviceState)) {
    return ["暂时无法确认远程任务状态"];
  }
  return updateBlockers(health);
}

function number(value) {
  return Number.isFinite(Number(value)) ? Number(value) : 0;
}

module.exports = { serviceStateFromHealth, updateBlockers, updateReadinessForService };
