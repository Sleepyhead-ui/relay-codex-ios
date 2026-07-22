import { describe, expect, it } from "vitest";
import { applyContextCompaction, applyDeltaBatch, applyUserMessagePlacements, bindUserPrompt, diffLineKind, extractGoalContext, filterThreads, formatElapsed, mergeSessionPatch, mergeSnapshot, parseApproval, parseItem, TranscriptGroupIndex, windowTranscriptGroups } from "./transcript";
import type { TranscriptItem } from "./types";

describe("desktop transcript", () => {
  it("applies incremental session changes without replacing unrelated turns", () => {
    const existing = [
      { id: "older", turnId: "turn.0", kind: "assistant" as const, text: "older" },
      { id: "one", turnId: "turn.1", kind: "assistant" as const, text: "first" },
      { id: "two", turnId: "turn.1", kind: "command" as const, text: "old command" },
    ];
    const merged = mergeSessionPatch(existing, [
      { id: "one", turnId: "turn.1", kind: "assistant", text: "first expanded" },
      { id: "three", turnId: "turn.1", kind: "reasoning", text: "next" },
    ], ["two"], "turn.1");
    expect(merged.map((item) => item.id)).toEqual(["older", "one", "three"]);
    expect(merged[1]?.text).toBe("first expanded");
  });

  it("uses timestamps when an active turn carries a zero history duration", () => {
    expect(formatElapsed(Date.now() / 1000 - 65, undefined, 0)).toBe("1 分 5 秒");
  });

  it("uses completed timestamps when a stopped history turn carries a zero duration", () => {
    expect(formatElapsed(1_000, 1_171, 0)).toBe("2 分 51 秒");
  });

  it("extracts the actual shell command from an exec wrapper", () => {
    const item = parseItem({
      id: "tool.1",
      type: "dynamicToolCall",
      tool: "exec",
      arguments: 'const result = await tools.shell_command({ command: "Get-ChildItem -Force" });',
      result: "Exit code: 0",
      status: "completed",
    }, "turn.1");
    expect(item?.kind).toBe("command");
    expect(item?.text).toBe("Get-ChildItem -Force");
    expect(item?.detail).toContain("Exit code: 0");
  });

  it("removes the desktop attachment wrapper from user prompts", () => {
    const item = parseItem({
      id: "user.1",
      type: "userMessage",
      content: [{ type: "text", text: "# Files mentioned by the user:\n\nimage.png: C:\\\\Temp\\\\image.png\n\n## My request for Codex:\n\n输入文字应该正常显示" }],
    }, "turn.1");
    expect(item?.text).toBe("输入文字应该正常显示");
  });

  it("keeps local images as structured user-message media", () => {
    const item = parseItem({
      id: "user.image",
      type: "userMessage",
      content: [
        { type: "localImage", path: "C:\\Temp\\screen.png" },
        { type: "text", text: "查看这张截图" },
      ],
    }, "turn.1");
    expect(item?.text).toBe("查看这张截图");
    expect(item?.imagePaths).toEqual(["C:\\Temp\\screen.png"]);
  });

  it("turns Codex image markup into media without showing the raw tag", () => {
    const item = parseItem({
      id: "user.image-markup",
      type: "userMessage",
      content: [
        { type: "localImage", path: "C:\\Temp\\screen.png" },
        { type: "text", text: "查看这张截图\n\n<image name=[Image #1] path=\"C:\\Temp\\screen.png\">\n</image>" },
      ],
    }, "turn.1");
    expect(item?.text).toBe("查看这张截图");
    expect(item?.imagePaths).toEqual(["C:\\Temp\\screen.png"]);
  });

  it("hides internal environment context user messages", () => {
    const item = parseItem({
      id: "internal.env",
      type: "userMessage",
      content: [{ type: "text", text: "<environment_context><current_date>2026-07-22</current_date></environment_context>" }],
    }, "turn.1");
    expect(item).toBeNull();
  });

  it("deduplicates matching progress from app-server and rollout snapshots", () => {
    const existing = [{ id: "live.1", turnId: "turn.1", kind: "assistant" as const, phase: "commentary", text: "正在检查同步状态" }];
    const snapshot = [{ id: "rollout.1", turnId: "turn.1", kind: "assistant" as const, phase: "commentary", text: "正在检查同步状态" }];
    const merged = mergeSnapshot(existing, snapshot, "turn.1");
    expect(merged).toHaveLength(1);
    expect(merged[0].id).toBe("live.1");
  });

  it("replaces an internal compaction answer with a compact status item", () => {
    const messages = [
      { id: "user.1", turnId: "turn.1", kind: "user" as const, text: "Continue" },
      { id: "summary.1", turnId: "turn.1", kind: "assistant" as const, phase: "final_answer", text: "## Current State\nInternal details" },
    ];
    const compacted = applyContextCompaction(messages, "turn.1");
    expect(compacted.map((item) => item.kind)).toEqual(["user", "compaction"]);
    expect(compacted.some((item) => item.text.includes("Current State"))).toBe(false);
  });

  it("preserves two commands when the same command genuinely ran twice", () => {
    const existing = [
      { id: "live.1", turnId: "turn.1", kind: "command" as const, text: "npm test" },
      { id: "live.2", turnId: "turn.1", kind: "command" as const, text: "npm test" },
    ];
    const snapshot = [
      { id: "file.1", turnId: "turn.1", kind: "command" as const, text: "npm test" },
      { id: "file.2", turnId: "turn.1", kind: "command" as const, text: "npm test" },
    ];
    expect(mergeSnapshot(existing, snapshot, "turn.1")).toHaveLength(2);
  });

  it("moves an optimistic user prompt before activity as soon as the turn id is known", () => {
    const messages = [
      { id: "progress.1", turnId: "turn.1", kind: "assistant" as const, phase: "commentary", text: "正在检查" },
      { id: "user.1", kind: "user" as const, text: "帮我安装桌面端" },
      { id: "command.1", turnId: "turn.1", kind: "command" as const, text: "Get-Item setup.exe" },
    ];
    const bound = bindUserPrompt(messages, "user.1", "turn.1");
    expect(bound.map((item) => item.id)).toEqual(["user.1", "progress.1", "command.1"]);
    expect(bound[0].turnId).toBe("turn.1");
  });

  it("keeps a start prompt ahead of activity after every incomplete snapshot", () => {
    const existing = [
      { id: "user.1", turnId: "turn.1", kind: "user" as const, text: "开始任务" },
      { id: "progress.1", turnId: "turn.1", kind: "assistant" as const, phase: "commentary", text: "正在检查" },
    ];
    const snapshot = [
      { id: "progress.1", turnId: "turn.1", kind: "assistant" as const, phase: "commentary", text: "正在检查" },
      { id: "command.1", turnId: "turn.1", kind: "command" as const, text: "npm test" },
    ];
    const merged = mergeSnapshot(existing, snapshot, "turn.1");
    expect(merged.map((item) => item.id)).toEqual(["user.1", "progress.1", "command.1"]);

    const placed = applyUserMessagePlacements(merged, [{
      messageId: "user.1", threadId: "thread.1", turnId: "turn.1", sequence: 1,
    }], "thread.1", "turn.1");
    expect(placed.map((item) => item.id)).toEqual(["user.1", "progress.1", "command.1"]);
    const mergedAgain = mergeSnapshot(placed, snapshot, "turn.1");
    const placedAgain = applyUserMessagePlacements(mergedAgain, [{
      messageId: "user.1", threadId: "thread.1", turnId: "turn.1", sequence: 1,
    }], "thread.1", "turn.1");
    expect(placedAgain.map((item) => item.id)).toEqual(["user.1", "progress.1", "command.1"]);
  });

  it("does not let a lagging snapshot shorten streamed progress or command output", () => {
    const existing = [
      { id: "progress.1", turnId: "turn.1", kind: "assistant" as const, phase: "commentary", text: "正在检查完整进展" },
      { id: "command.1", turnId: "turn.1", kind: "command" as const, text: "npm test", detail: "line 1\nline 2" },
    ];
    const snapshot = [
      { id: "progress.1", turnId: "turn.1", kind: "assistant" as const, phase: "commentary", text: "正在检查" },
      { id: "command.1", turnId: "turn.1", kind: "command" as const, text: "npm test", detail: "line 1" },
    ];
    const merged = mergeSnapshot(existing, snapshot, "turn.1");
    expect(merged[0].text).toBe("正在检查完整进展");
    expect(merged[1].detail).toBe("line 1\nline 2");
  });

  it("keeps a steer prompt at its actual point in the activity timeline", () => {
    const existing = [
      { id: "user.1", turnId: "turn.1", kind: "user" as const, text: "开始任务" },
      { id: "progress.1", turnId: "turn.1", kind: "assistant" as const, phase: "commentary", text: "第一阶段" },
      { id: "user.2", turnId: "turn.1", kind: "user" as const, text: "继续检查这里" },
    ];
    const snapshot = [
      { id: "progress.1", turnId: "turn.1", kind: "assistant" as const, phase: "commentary", text: "第一阶段" },
      { id: "progress.2", turnId: "turn.1", kind: "assistant" as const, phase: "commentary", text: "第二阶段" },
    ];
    const merged = mergeSnapshot(existing, snapshot, "turn.1");
    const placed = applyUserMessagePlacements(merged, [
      { messageId: "user.1", threadId: "thread.1", turnId: "turn.1", sequence: 1 },
      { messageId: "user.2", threadId: "thread.1", turnId: "turn.1", afterItemId: "progress.1", sequence: 2 },
    ], "thread.1", "turn.1");
    expect(placed.map((item) => item.id)).toEqual(["user.1", "progress.1", "user.2", "progress.2"]);
  });

  it("extracts only the objective from internal goal context", () => {
    const parsed = extractGoalContext(`before\n<codex_internal_context source="goal">\n<objective>完成第一、第二阶段</objective>\n<status>active</status>\nInternal continuation instructions\n</codex_internal_context>\nafter`);
    expect(parsed.text).toBe("before\n\nafter");
    expect(parsed.objective).toBe("完成第一、第二阶段");
    const item = parseItem({
      id: "goal.1", type: "userMessage", content: [{ type: "text", text: `<codex_internal_context source="goal"><objective>完成同步核心</objective><internal>do not show</internal></codex_internal_context>` }],
    }, "turn.1");
    expect(item?.text).toBe("");
    expect(item?.goal).toBe("完成同步核心");
  });

  it("keeps approval ownership so concurrent tasks cannot overwrite context", () => {
    const approval = parseApproval({
      id: 7,
      method: "item/commandExecution/requestApproval",
      params: { threadId: "thread.2", turnId: "turn.4", command: "npm test" },
    });
    expect(approval.threadId).toBe("thread.2");
    expect(approval.turnId).toBe("turn.4");
  });

  it("searches threads by title, preview, and project path", () => {
    const threads = [
      { id: "1", title: "同步 Relay", preview: "修复实时输出", cwd: "C:\\Projects\\Relay", updatedAt: 1, status: "idle" },
      { id: "2", title: "文档", preview: "整理发布说明", cwd: "C:\\Projects\\Docs", updatedAt: 2, status: "idle" },
    ];
    expect(filterThreads(threads, "实时").map((thread) => thread.id)).toEqual(["1"]);
    expect(filterThreads(threads, "docs").map((thread) => thread.id)).toEqual(["2"]);
    expect(filterThreads(threads, "同步").map((thread) => thread.id)).toEqual(["1"]);
  });

  it("classifies diff headers before additions and removals", () => {
    expect(["--- a/file", "+++ b/file", "@@ -1 +1 @@", "-old", "+new", " same"].map(diffLineKind))
      .toEqual(["header", "header", "hunk", "removed", "added", "context"]);
  });

  it("replays a high-load transcript without loss, duplication, or reordering", () => {
    let messages: TranscriptItem[] = Array.from({ length: 1_000 }, (_, index) => ({
      id: `history.${index}`, turnId: `turn.${Math.floor(index / 10)}`, kind: "assistant" as const, text: `message ${index}`,
    }));
    const outputChunk = "x".repeat(100_000);
    const deltas = Array.from({ length: 100 }, () => ({
      id: "command.live", turnId: "turn.live", kind: "command" as const, text: "", detail: outputChunk,
    }));
    messages = applyDeltaBatch(messages, deltas);

    expect(messages).toHaveLength(1_001);
    expect(messages.slice(0, 1_000).map((item) => item.id)).toEqual(
      Array.from({ length: 1_000 }, (_, index) => `history.${index}`),
    );
    expect(messages.filter((item) => item.id === "command.live")).toHaveLength(1);
    expect(messages.at(-1)?.detail?.length).toBe(10_000_000);
  });

  it("windows one thousand transcript turns without changing visible order", () => {
    const messages: TranscriptItem[] = Array.from({ length: 1_000 }, (_, index) => ({
      id: `message.${index}`, turnId: `turn.${index}`, kind: "assistant", text: `${index}`,
    }));
    const window = windowTranscriptGroups(messages, 40);
    expect(window.hasEarlierGroups).toBe(true);
    expect(window.groups).toHaveLength(40);
    expect(window.groups[0]?.id).toBe("turn.turn.960");
    expect(window.groups.at(-1)?.id).toBe("turn.turn.999");
  });

  it("updates one live turn incrementally across one hundred frames", () => {
    let messages: TranscriptItem[] = Array.from({ length: 1_000 }, (_, index) => ({
      id: `message.${index}`, turnId: `turn.${index}`, kind: "assistant", text: `${index}`,
    }));
    const index = new TranscriptGroupIndex();
    const first = index.window(messages, 40);
    const stableItems = first.groups[0]!.items;
    for (let frame = 0; frame < 100; frame += 1) {
      messages = applyDeltaBatch(messages, [{
        id: "message.999", turnId: "turn.999", kind: "assistant", text: ".", detail: "",
      }]);
      index.window(messages, 40);
    }
    const last = index.window(messages, 40);
    expect(index.fullRebuildCount).toBe(1);
    expect(index.incrementalUpdateCount).toBe(100);
    expect(last.groups[0]!.items).toBe(stableItems);
    expect(last.groups.at(-1)?.items[0]?.text.endsWith(".".repeat(100))).toBe(true);
  });
});
