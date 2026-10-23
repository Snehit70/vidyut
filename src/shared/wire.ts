export type PayloadType = "image" | "text" | "link";

export interface PayloadFrame {
  v: 1;
  type: PayloadType;
  mime: string;
  origin: string;
  ts: number;
  nonce: string;
  payload: string;
  /** The same text with its formatting, sealed on its own (ADR 0024). */
  alt?: PayloadAlternative;
}

/**
 * A richer rendering of a text frame. Only `text/html` is defined; a receiver
 * that does not know it, or cannot open it, uses the plain `payload`.
 */
export interface PayloadAlternative {
  mime: "text/html";
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
    paused?: boolean;
    pausedUntil?: number;
  };
}

export interface LaptopTelemetry {
  v: 1;
  kind: "telemetry";
  ts: number;
  batteryPercent: number | null;
  batteryState: "charging" | "on_battery" | "plugged_in" | null;
  memoryUsedBytes: number | null;
  memoryTotalBytes: number | null;
  storageUsedBytes: number | null;
  storageTotalBytes: number | null;
  cpuUsagePercent: number | null;
  cpuTemperatureCelsius: number | null;
}

export type TransferDirection = "laptop_to_phone" | "phone_to_laptop";

export interface TransferTimingSummary {
  v: 1;
  wallAnchorMs: number;
  offerWallMs?: number;
  acceptWallMs?: number;
  attempts: Array<{
    attempt: number;
    stages: Record<string, { startMs: number; endMs?: number }>;
  }>;
}

export interface TransferFileOffer {
  fileId: string;
  filename: string;
  mime: string;
  size: number;
  lastModifiedMs: number;
  lastModifiedKnown?: boolean;
  sha256: string;
  senderTiming?: TransferTimingSummary;
  /**
   * Subfolder to place the file in on arrival, relative and "/"-separated.
   * Set when the phone pulled a whole folder (ADR 0026).
   */
  folder?: string;
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
      maxChunkBytes?: number;
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
  /** `features` names optional protocol behaviour this Relay understands. */
  | {
      v: 1;
      kind: "hello";
      challenge: string;
      maxPayloadBytes: number;
      features?: RelayFeature[];
    }
  /**
   * `clientChallenge` asks the Relay to prove it holds the pairing secret too
   * (ADR 0023); `features` names what the Device can do.
   */
  | {
      v: 1;
      kind: "auth";
      deviceId: string;
      proof: string;
      clientChallenge?: string;
      features?: string[];
    }
  /**
   * `relayProof` answers a `clientChallenge`, and covers `features`: the
   * session features both sides settled on.
   */
  | {
      v: 1;
      kind: "auth_ok";
      health?: RelayHealth;
      relayProof?: string;
      features?: SessionFeature[];
    }
  | { v: 1; kind: "health"; health: RelayHealth }
  | LaptopTelemetry
  /**
   * `sentAt` is the sender's clock at send time. The Relay uses it to map
   * `frame.ts` onto its own clock before ordering. Absent from older phones.
   */
  | { v: 1; kind: "publish"; frame: PayloadFrame; sentAt?: number }
  | { v: 1; kind: "payload"; frame: PayloadFrame }
  /** `stale` marks a frame the pool dropped because it already held a newer one. */
  | { v: 1; kind: "ack"; ts: number; stale?: true }
  | TransferControlMessage
  /**
   * The phone wants laptop telemetry only while someone is looking at it. A
   * device that advertised `telemetry_subscribe` starts unsubscribed; one that
   * did not is subscribed for its whole session, as before the feature.
   */
  | { v: 1; kind: "telemetry_subscribe"; active: boolean }
  | BrowseRequest
  | BrowseResult
  | SealedMessage
  | { v: 1; kind: "error"; code: string; message: string };

/**
 * The phone reading the laptop's shared folders (ADR 0026, 0027). A
 * `browse_list` without `root` lists the shared folders themselves. A
 * `browse_thumb` asks for a picture of one file, small for a list row and
 * large for a full-screen preview. A `browse_search` matches names under one
 * shared folder, or under all of them without `root`. Only sealed sessions
 * may browse.
 */
export type BrowseRequest =
  | {
      v: 1;
      kind: "browse_list";
      requestId: string;
      root?: string;
      path?: string;
    }
  | {
      v: 1;
      kind: "browse_pull";
      requestId: string;
      root: string;
      paths: string[];
    }
  | {
      v: 1;
      kind: "browse_thumb";
      requestId: string;
      root: string;
      path: string;
      size?: BrowseThumbSize;
    }
  | {
      v: 1;
      kind: "browse_search";
      requestId: string;
      query: string;
      root?: string;
      path?: string;
    };

export type BrowseThumbSize = "small" | "large";

export interface BrowseRoot {
  id: string;
  name: string;
}

export interface BrowseEntry {
  name: string;
  kind: "file" | "folder";
  /** Absent for folders. */
  size?: number;
  modifiedMs: number;
}

/** One name match from a `browse_search`; `path` is relative to `root` and ends in `name`. */
export interface BrowseMatch extends BrowseEntry {
  root: string;
  path: string;
}

export type BrowseAnswer =
  | { ok: true; roots: BrowseRoot[] }
  | { ok: true; entries: BrowseEntry[]; truncated?: true }
  | { ok: true; queued: { files: number; bytes: number } }
  | { ok: true; thumb: { mime: "image/png" | "image/jpeg"; data: string } }
  | { ok: true; matches: BrowseMatch[]; truncated?: true }
  | { ok: false; code: string; message: string };

/** The answer to one BrowseRequest, matched by `requestId`. */
export type BrowseResult = {
  v: 1;
  kind: "browse_result";
  requestId: string;
} & BrowseAnswer;

/** Any other message, AES-256-GCM sealed under the session key (ADR 0023). */
export interface SealedMessage {
  v: 1;
  kind: "sealed";
  nonce: string;
  payload: string;
}

export type RelayFeature = "telemetry_subscribe" | "relay_proof" | "browse_files" | SessionFeature;

/** Features negotiated per session and covered by `relayProof`. */
export type SessionFeature = "sealed_control";

export function isPayloadFrame(value: unknown): value is PayloadFrame {
  if (!value || typeof value !== "object") return false;
  const frame = value as Record<string, unknown>;
  return (
    frame.v === 1 &&
    (frame.type === "image" || frame.type === "text" || frame.type === "link") &&
    typeof frame.mime === "string" &&
    typeof frame.origin === "string" &&
    typeof frame.ts === "number" &&
    Number.isFinite(frame.ts) &&
    typeof frame.nonce === "string" &&
    typeof frame.payload === "string" &&
    (frame.alt === undefined || isPayloadAlternative(frame.alt))
  );
}

function isPayloadAlternative(value: unknown): value is PayloadAlternative {
  if (!value || typeof value !== "object") return false;
  const alt = value as Record<string, unknown>;
  return alt.mime === "text/html" && typeof alt.nonce === "string" && typeof alt.payload === "string";
}

export function encodedPayloadBytes(frame: PayloadFrame): number {
  const main = Buffer.from(frame.payload, "base64").byteLength;
  return frame.alt ? main + Buffer.from(frame.alt.payload, "base64").byteLength : main;
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
    offer.files.length <= 100 &&
    offer.files.every(isTransferFileOffer) &&
    new Set(
      offer.files.map((file) => (file as TransferFileOffer).fileId),
    ).size === offer.files.length
  );
}

export function isBrowseKind(kind: unknown): boolean {
  return (
    kind === "browse_list" ||
    kind === "browse_pull" ||
    kind === "browse_thumb" ||
    kind === "browse_search"
  );
}

export function isBrowseRequest(value: unknown): value is BrowseRequest {
  if (!value || typeof value !== "object") return false;
  const message = value as Record<string, unknown>;
  if (message.v !== 1 || !isId(message.requestId)) return false;
  switch (message.kind) {
    case "browse_list":
      return (
        (message.root === undefined && message.path === undefined) ||
        (typeof message.root === "string" &&
          (message.path === undefined || typeof message.path === "string"))
      );
    case "browse_pull":
      return (
        typeof message.root === "string" &&
        Array.isArray(message.paths) &&
        message.paths.length > 0 &&
        message.paths.length <= 100 &&
        message.paths.every((path) => typeof path === "string")
      );
    case "browse_thumb":
      return (
        typeof message.root === "string" &&
        typeof message.path === "string" &&
        message.path.length > 0 &&
        (message.size === undefined ||
          message.size === "small" ||
          message.size === "large")
      );
    case "browse_search":
      return (
        typeof message.query === "string" &&
        message.query.trim().length >= minSearchQueryLength &&
        message.query.length <= maxSearchQueryLength &&
        (message.root === undefined || typeof message.root === "string") &&
        (message.path === undefined ||
          (typeof message.root === "string" &&
            typeof message.path === "string"))
      );
    default:
      return false;
  }
}

export const minSearchQueryLength = 2;
export const maxSearchQueryLength = 100;

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
      return (
        isId(message.transferId) &&
        isId(message.fileId) &&
        isNonNegativeSafeInteger(message.confirmedOffset) &&
        (message.maxChunkBytes === undefined ||
          (isNonNegativeSafeInteger(message.maxChunkBytes) &&
            message.maxChunkBytes > 0))
      );
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
    new TextEncoder().encode(file.filename).byteLength <= 255 &&
    !/[\u0000-\u001f\u007f]/u.test(file.filename) &&
    !file.filename.includes("/") &&
    !file.filename.includes("\\") &&
    file.filename !== "." &&
    file.filename !== ".." &&
    typeof file.mime === "string" &&
    file.mime.length > 0 &&
    isNonNegativeSafeInteger(file.size) &&
    isNonNegativeSafeInteger(file.lastModifiedMs) &&
    (file.lastModifiedKnown === undefined ||
      typeof file.lastModifiedKnown === "boolean") &&
    typeof file.sha256 === "string" &&
    (file.senderTiming === undefined || isTransferTiming(file.senderTiming)) &&
    (file.folder === undefined || isRelativeFolder(file.folder)) &&
    sha256Pattern.test(file.sha256)
  );
}

/** A relative "/"-separated folder with no empty, "." or ".." segment. */
export function isRelativeFolder(value: unknown): value is string {
  if (typeof value !== "string" || value.length === 0) return false;
  if (new TextEncoder().encode(value).byteLength > 1024) return false;
  if (/[\u0000-\u001f\u007f\\]/u.test(value)) return false;
  return value
    .split("/")
    .every((segment) => segment.length > 0 && segment !== "." && segment !== "..");
}

function isTransferTiming(value: unknown): value is TransferTimingSummary {
  if (!value || typeof value !== "object") return false;
  const timing = value as Record<string, unknown>;
  if (
    timing.v !== 1 ||
    !isNonNegativeSafeInteger(timing.wallAnchorMs) ||
    (timing.offerWallMs !== undefined &&
      !isNonNegativeSafeInteger(timing.offerWallMs)) ||
    (timing.acceptWallMs !== undefined &&
      !isNonNegativeSafeInteger(timing.acceptWallMs)) ||
    !Array.isArray(timing.attempts) ||
    timing.attempts.length > 4
  ) {
    return false;
  }
  return timing.attempts.every((attempt) => {
    if (!attempt || typeof attempt !== "object") return false;
    const item = attempt as Record<string, unknown>;
    if (
      !isNonNegativeSafeInteger(item.attempt) ||
      !item.stages ||
      typeof item.stages !== "object" ||
      Array.isArray(item.stages)
    ) {
      return false;
    }
    return Object.values(item.stages).every((span) => {
      if (!span || typeof span !== "object") return false;
      const value = span as Record<string, unknown>;
      return (
        typeof value.startMs === "number" &&
        Number.isFinite(value.startMs) &&
        (value.endMs === undefined ||
          (typeof value.endMs === "number" &&
            Number.isFinite(value.endMs) &&
            value.endMs >= value.startMs))
      );
    });
  });
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
