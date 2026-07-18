import { timingSafeEqual } from "node:crypto";

export type JsonObject = Record<string, unknown>;

export interface ClientRpcMessage {
  type: "rpc";
  id: string;
  method: string;
  params: JsonObject;
}

export interface ClientServerResponseMessage {
  type: "serverResponse";
  id: string | number;
  result?: unknown;
  error?: JsonObject;
}

export type ClientMessage = ClientRpcMessage | ClientServerResponseMessage;

export function isAuthorized(header: string | undefined, token: string): boolean {
  if (!header?.startsWith("Bearer ")) return false;
  const supplied = Buffer.from(header.slice(7), "utf8");
  const expected = Buffer.from(token, "utf8");
  return supplied.length === expected.length && timingSafeEqual(supplied, expected);
}

export function parseClientMessage(raw: string): ClientMessage {
  const value: unknown = JSON.parse(raw);
  if (!isObject(value) || typeof value.type !== "string") {
    throw new Error("Message must be an object with a type.");
  }

  if (value.type === "rpc") {
    if (
      typeof value.id !== "string" ||
      typeof value.method !== "string" ||
      !isObject(value.params)
    ) {
      throw new Error("Invalid rpc message.");
    }
    return { type: "rpc", id: value.id, method: value.method, params: value.params };
  }

  if (value.type === "serverResponse") {
    if (typeof value.id !== "string" && typeof value.id !== "number") {
      throw new Error("Invalid server response id.");
    }
    const result: ClientServerResponseMessage = { type: "serverResponse", id: value.id };
    if ("result" in value) result.result = value.result;
    if (isObject(value.error)) result.error = value.error;
    return result;
  }

  throw new Error(`Unsupported message type: ${value.type}`);
}

export function isObject(value: unknown): value is JsonObject {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

