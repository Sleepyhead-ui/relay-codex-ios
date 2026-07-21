import { describe, expect, it } from "vitest";
import { applyUserMessagePlacements, bindUserPrompt, formatElapsed, mergeSnapshot, parseItem } from "./transcript";

describe("desktop transcript", () => {
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
        { type: "text", text: "查看这张截图\n\n<image name=[Image #1] path=\"C:\\Temp\\screen.png\">" },
      ],
    }, "turn.1");
    expect(item?.text).toBe("查看这张截图");
    expect(item?.imagePaths).toEqual(["C:\\Temp\\screen.png"]);
  });

  it("deduplicates matching progress from app-server and rollout snapshots", () => {
    const existing = [{ id: "live.1", turnId: "turn.1", kind: "assistant" as const, phase: "commentary", text: "正在检查同步状态" }];
    const snapshot = [{ id: "rollout.1", turnId: "turn.1", kind: "assistant" as const, phase: "commentary", text: "正在检查同步状态" }];
    const merged = mergeSnapshot(existing, snapshot, "turn.1");
    expect(merged).toHaveLength(1);
    expect(merged[0].id).toBe("live.1");
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
    expect(merged.map((item) => item.id)).toEqual(["progress.1", "command.1", "user.1"]);

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
});
