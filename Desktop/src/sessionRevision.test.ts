import { describe, expect, it } from "vitest";
import { SessionRevisionTracker } from "./sessionRevision";

describe("session revision tracker", () => {
  it("rejects out-of-order patches without advancing the cursor", () => {
    const tracker = new SessionRevisionTracker();
    tracker.reset("thread.1", 0);
    expect(tracker.acceptPatch("thread.1", 0, 1)).toBe(true);
    expect(tracker.acceptPatch("thread.1", 0, 2)).toBe(false);
    expect(tracker.revision("thread.1")).toBe(1);
    tracker.reset("thread.1", 5);
    expect(tracker.acceptPatch("thread.1", 5, 6)).toBe(true);
  });
});
