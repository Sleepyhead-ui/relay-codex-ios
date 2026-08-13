import { describe, expect, it } from "vitest";
import { pairingURL } from "./pairing";

describe("pairingURL", () => {
  it("encodes the endpoint, token, and computer name for Relay", () => {
    const value = new URL(pairingURL(
      { endpoint: " ws://100.80.115.15:8765 ", token: " secret+/token " },
      "Studio PC",
    ));

    expect(value.protocol).toBe("relay:");
    expect(value.hostname).toBe("connect");
    expect(value.searchParams.get("url")).toBe("ws://100.80.115.15:8765");
    expect(value.searchParams.get("token")).toBe("secret+/token");
    expect(value.searchParams.get("name")).toBe("Studio PC");
  });

  it("does not create a pairing URL without complete credentials", () => {
    expect(pairingURL({ endpoint: "ws://host:8765", token: "" })).toBe("");
    expect(pairingURL({ endpoint: "", token: "secret" })).toBe("");
  });
});
