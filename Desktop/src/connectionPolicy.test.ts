import { describe, expect, it } from "vitest";

const { reconnectDelayMs, stableConnectionResetMs } = require("../electron/connection-policy.cjs") as {
  reconnectDelayMs: (attempt: number) => number;
  stableConnectionResetMs: number;
};

describe("desktop connection retry policy", () => {
  it("backs off repeated failures instead of retrying once per second forever", () => {
    const delays = Array.from({ length: 12 }, (_, index) => reconnectDelayMs(index + 1));
    expect(delays[0]).toBe(800);
    expect(delays[1]).toBe(1_360);
    expect(delays[5]).toBeGreaterThan(8_000 / 2);
    expect(delays.at(-1)).toBe(8_000);
    expect(delays.every((delay, index) => index === 0 || delay >= delays[index - 1]!)).toBe(true);
  });

  it("requires a meaningful stable connection before resetting backoff", () => {
    expect(stableConnectionResetMs).toBe(10_000);
  });
});
