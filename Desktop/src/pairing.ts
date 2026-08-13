import type { ConnectionConfig } from "./types";

export function pairingURL(config: ConnectionConfig, computerName = "Windows PC") {
  if (!config.endpoint.trim() || !config.token.trim()) return "";
  const url = new URL("relay://connect");
  url.searchParams.set("url", config.endpoint.trim());
  url.searchParams.set("token", config.token.trim());
  url.searchParams.set("name", computerName.trim() || "Windows PC");
  return url.toString();
}
