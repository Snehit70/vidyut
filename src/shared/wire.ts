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

export type TransferDirection = "laptop_to_phone" | "phone_to_laptop";

export interface TransferFileOffer {
  fileId: string;
  filename: string;
  mime: string;
  size: number;
  lastModifiedMs: number;
  sha256: string;
}

export interface TransferOffer {
  transferId: string;
  batchId: string;
  origin: string;
  direction: TransferDirection;
  createdAtMs: number;
  files: TransferFileOffer[];
}

export type TransferControlMessage =
  | { v: 1; kind: "transfer_offer"; offer: TransferOffer }
  | {
      v: 1;
      kind: "transfer_accept";
      transferId: string;
      fileId: string;
      confirmedOffset: number;
    }
  | {
      v: 1;
      kind: "transfer_progress";
      transferId: string;
      fileId: string;
      confirmedOffset: number;
    }
  | {
      v: 1;
      kind: "transfer_pause" | "transfer_resume" | "transfer_cancel";
      transferId: string;
      fileId?: string;
    }
  | {
      v: 1;
      kind: "transfer_file_complete";
      transferId: string;
      fileId: string;
      sha256: string;
    }
  | {
      v: 1;
      kind: "transfer_file_failed";
      transferId: string;
      fileId: string;
      code: string;
    };

export type RelayMessage =
  | { v: 1; kind: "hello"; challenge: string; maxPayloadBytes: number }
  | { v: 1; kind: "auth"; deviceId: string; proof: string }
  | { v: 1; kind: "auth_ok"; health?: RelayHealth }
  | { v: 1; kind: "health"; health: RelayHealth }
  | { v: 1; kind: "publish"; frame: PayloadFrame }
  | { v: 1; kind: "payload"; frame: PayloadFrame }
  | { v: 1; kind: "ack"; ts: number }
  | TransferControlMessage
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

const idPattern = /^[A-Za-z0-9_-]{16,128}$/;
const sha256Pattern = /^[a-f0-9]{64}$/;

export function isTransferOffer(value: unknown): value is TransferOffer {
  if (!value || typeof value !== "object") return false;
  const offer = value as Record<string, unknown>;
  return (
    isId(offer.transferId) &&
    isId(offer.batchId) &&
    typeof offer.origin === "string" &&
    offer.origin.length > 0 &&
    (offer.direction === "laptop_to_phone" ||
      offer.direction === "phone_to_laptop") &&
    isNonNegativeSafeInteger(offer.createdAtMs) &&
    Array.isArray(offer.files) &&
    offer.files.length > 0 &&
    offer.files.every(isTransferFileOffer) &&
    new Set(
      offer.files.map((file) => (file as TransferFileOffer).fileId),
    ).size === offer.files.length
  );
}

export function isTransferControlMessage(
  value: unknown,
): value is TransferControlMessage {
  if (!value || typeof value !== "object") return false;
  const message = value as Record<string, unknown>;
  if (message.v !== 1 || typeof message.kind !== "string") return false;

  switch (message.kind) {
    case "transfer_offer":
      return isTransferOffer(message.offer);
    case "transfer_accept":
    case "transfer_progress":
      return (
        isId(message.transferId) &&
        isId(message.fileId) &&
        isNonNegativeSafeInteger(message.confirmedOffset)
      );
    case "transfer_pause":
    case "transfer_resume":
    case "transfer_cancel":
      return (
        isId(message.transferId) &&
        (message.fileId === undefined || isId(message.fileId))
      );
    case "transfer_file_complete":
      return (
        isId(message.transferId) &&
        isId(message.fileId) &&
        typeof message.sha256 === "string" &&
        sha256Pattern.test(message.sha256)
      );
    case "transfer_file_failed":
      return (
        isId(message.transferId) &&
        isId(message.fileId) &&
        typeof message.code === "string" &&
        message.code.length > 0
      );
    default:
      return false;
  }
}

function isTransferFileOffer(value: unknown): value is TransferFileOffer {
  if (!value || typeof value !== "object") return false;
  const file = value as Record<string, unknown>;
  return (
    isId(file.fileId) &&
    typeof file.filename === "string" &&
    file.filename.length > 0 &&
    file.filename.length <= 255 &&
    !file.filename.includes("/") &&
    !file.filename.includes("\\") &&
    file.filename !== "." &&
    file.filename !== ".." &&
    typeof file.mime === "string" &&
    file.mime.length > 0 &&
    isNonNegativeSafeInteger(file.size) &&
    isNonNegativeSafeInteger(file.lastModifiedMs) &&
    typeof file.sha256 === "string" &&
    sha256Pattern.test(file.sha256)
  );
}

function isId(value: unknown): value is string {
  return typeof value === "string" && idPattern.test(value);
}

function isNonNegativeSafeInteger(value: unknown): value is number {
  return (
    typeof value === "number" &&
    Number.isSafeInteger(value) &&
    value >= 0
  );
}
