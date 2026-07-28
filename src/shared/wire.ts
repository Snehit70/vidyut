export type PayloadType = "image" | "text";

export interface PayloadFrame {
  v: 1;
  type: PayloadType;
  mime: string;
  origin: string;
  ts: number;
  nonce: string;
  payload: string;
}

export interface PayloadMetadata {
  type: PayloadType;
  mime: string;
  origin: string;
  ts: number;
}

export interface RelayHealth {
  status: "ok" | "degraded";
  relayName: string;
  clipboard?: {
    enabled: boolean;
    status: "starting" | "healthy" | "degraded" | "disabled";
    watcher?: string;
    error?: string;
  };
}

export type RelayMessage =
  | { v: 1; kind: "hello"; challenge: string; maxPayloadBytes: number }
  | { v: 1; kind: "auth"; deviceId: string; proof: string }
  | { v: 1; kind: "auth_ok"; health?: RelayHealth }
  | { v: 1; kind: "health"; health: RelayHealth }
  | { v: 1; kind: "publish"; frame: PayloadFrame }
  | { v: 1; kind: "payload"; frame: PayloadFrame }
  | { v: 1; kind: "ack"; ts: number }
  | { v: 1; kind: "error"; code: string; message: string };

export function isPayloadFrame(value: unknown): value is PayloadFrame {
  if (!value || typeof value !== "object") return false;
  const frame = value as Record<string, unknown>;
  return (
    frame.v === 1 &&
    (frame.type === "image" || frame.type === "text") &&
    typeof frame.mime === "string" &&
    typeof frame.origin === "string" &&
    typeof frame.ts === "number" &&
    Number.isFinite(frame.ts) &&
    typeof frame.nonce === "string" &&
    typeof frame.payload === "string"
  );
}

export function encodedPayloadBytes(frame: PayloadFrame): number {
  return Buffer.from(frame.payload, "base64").byteLength;
}
