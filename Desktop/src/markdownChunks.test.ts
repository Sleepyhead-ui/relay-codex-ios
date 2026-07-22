import { describe, expect, it } from "vitest";
import { splitMarkdownChunks } from "./markdownChunks";

describe("incremental markdown chunks", () => {
  it("keeps completed paragraphs stable while the tail grows", () => {
    const first = splitMarkdownChunks("first\n\nsecond");
    const next = splitMarkdownChunks("first\n\nsecond grows");
    expect(first[0]).toBe(next[0]);
    expect(next.join("")).toBe("first\n\nsecond grows");
  });

  it("does not split blank lines inside fenced code", () => {
    const source = "before\n\n```ts\nconst value = 1;\n\nconsole.log(value);\n```\n\nafter";
    const chunks = splitMarkdownChunks(source);
    expect(chunks.join("")).toBe(source);
    expect(chunks.filter((chunk) => chunk.includes("```ts"))).toHaveLength(1);
    expect(chunks.find((chunk) => chunk.includes("```ts"))).toContain("console.log");
  });

  it("keeps one markdown list in one parser chunk", () => {
    const source = "1. first\n\n2. second\n\n3. third";
    expect(splitMarkdownChunks(source)).toEqual([source]);
  });
});
