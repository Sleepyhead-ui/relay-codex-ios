import assert from "node:assert/strict";
import test from "node:test";
import { boundHistoryPage, boundThreadHistoryResult } from "../dist/historyPayload.js";

test("bounds large technical history without dropping user or assistant messages", () => {
  const hugeOutput = "x".repeat(500_000);
  const result = boundHistoryPage({
    data: [{
      id: "turn.1",
      items: [
        { id: "user.1", type: "userMessage", content: [{ type: "text", text: "保留提示词" }] },
        ...Array.from({ length: 8 }, (_, index) => ({
          id: `command.${index}`,
          type: "commandExecution",
          command: `command ${index}`,
          aggregatedOutput: hugeOutput,
          status: "completed",
        })),
        { id: "answer.1", type: "agentMessage", text: "保留最终回答", phase: "final_answer" },
      ],
    }],
  });

  const encoded = Buffer.byteLength(JSON.stringify(result));
  assert.ok(encoded <= 768 * 1024);
  assert.equal(result.data[0].items[0].content[0].text, "保留提示词");
  assert.equal(result.data[0].items.at(-1).text, "保留最终回答");
  assert.ok(result.data[0].items.some((item) => item.aggregatedOutputTruncated === true));
});

test("drops old activity summaries when a turn contains thousands of tool records", () => {
  const result = boundHistoryPage({
    data: [{
      id: "turn.large",
      items: [
        { id: "user.large", type: "userMessage", content: [{ type: "text", text: "保留提示词" }] },
        ...Array.from({ length: 10_000 }, (_, index) => ({
          id: `tool.${index}`,
          type: "dynamicToolCall",
          tool: "wait",
          status: "completed",
        })),
        { id: "answer.large", type: "agentMessage", text: "保留最终回答", phase: "final_answer" },
      ],
    }],
  });

  assert.ok(Buffer.byteLength(JSON.stringify(result)) <= 768 * 1024);
  assert.equal(result.data[0].items[0].id, "user.large");
  assert.equal(result.data[0].items.at(-1).id, "answer.large");
  assert.ok(result.data[0].historyOmittedItemCount > 9_000);
});

test("bounds history embedded by thread resume responses", () => {
  const result = boundThreadHistoryResult({
    thread: { id: "thread.1", turns: [{ id: "turn.thread", items: [{ id: "tool.thread", type: "commandExecution", output: "x".repeat(900_000) }] }] },
    initialTurnsPage: { data: [{ id: "turn.page", items: [{ id: "tool.page", type: "commandExecution", output: "y".repeat(900_000) }] }] },
  });

  assert.ok(Buffer.byteLength(JSON.stringify(result.thread.turns[0])) <= 768 * 1024);
  assert.ok(Buffer.byteLength(JSON.stringify(result.initialTurnsPage.data[0])) <= 768 * 1024);
  assert.equal(result.thread.turns[0].items[0].outputTruncated, true);
  assert.equal(result.initialTurnsPage.data[0].items[0].outputTruncated, true);
});
