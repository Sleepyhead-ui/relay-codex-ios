import { describe, expect, it } from "vitest";
import { previewTechnicalText } from "./technicalText";

describe("large technical output", () => {
  it("keeps a ten megabyte command out of one DOM text node", () => {
    const source = `${"old output\n".repeat(1_000_000)}latest line`;
    const preview = previewTechnicalText(source);
    expect(preview.truncated).toBe(true);
    expect(preview.text.length).toBeLessThan(40_000);
    expect(preview.text).toContain("latest line");
  });

  it("does not alter short output", () => {
    expect(previewTechnicalText("first\nsecond").text).toBe("first\nsecond");
  });
});
