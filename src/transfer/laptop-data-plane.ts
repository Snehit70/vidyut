import {
  link,
  mkdir,
  open,
  stat,
  unlink,
  utimes,
} from "node:fs/promises";
import { basename, dirname, extname, join } from "node:path";
import {
  decryptTransferChunk,
  encryptTransferChunk,
  sha256Hex,
  type EncryptedTransferChunk,
  type TransferChunkMetadata,
} from "../shared/transfer-crypto";
import type { TransferControlMessage } from "../shared/wire";
import type { TransferFileRecord } from "./transfer-queue";
import { TransferQueue, transferTimingStage } from "./transfer-queue";
import { TransferHttpDataPlane } from "./http-data-plane";
import {
  legacyTransferChunkBytes,
  preferredTransferChunkBytes,
} from "./transfer-chunk-policy";
import { partialPathFor } from "./transfer-paths";

export interface ReceiverProgressPolicy {
  now?: () => number;
  checkpointBytes?: number;
  checkpointIntervalMs?: number;
  publishIntervalMs?: number;
}

export class ReceiverProgressSessions {
  private readonly sessions = new Map<string, ReceiverProgressSession>();
  private readonly locks = new Map<string, Promise<void>>();

  constructor(private readonly policy: ReceiverProgressPolicy = {}) {}

  async runExclusive<T>(
    transferId: string,
    fileId: string,
    operation: () => Promise<T>,
  ): Promise<T> {
    const key = progressKey(transferId, fileId);
    const previous = this.locks.get(key) ?? Promise.resolve();
    let release!: () => void;
    const current = new Promise<void>((resolve) => {
      release = resolve;
    });
    this.locks.set(key, current);
    await previous;
    try {
      return await operation();
    } finally {
      release();
      if (this.locks.get(key) === current) this.locks.delete(key);
    }
  }

  sessionFor(
    transferId: string,
    record: TransferFileRecord,
  ): ReceiverProgressSession {
    const key = progressKey(transferId, record.fileId);
    let session = this.sessions.get(key);
    if (!session) {
      session = new ReceiverProgressSession(record, this.policy);
      this.sessions.set(key, session);
    }
    if (record.confirmedOffset > session.acceptedOffset) {
      session.acceptedOffset = record.confirmedOffset;
      session.durableOffset = record.confirmedOffset;
    }
    return session;
  }

  liveAcceptedOffset(
    transferId: string,
    fileId: string,
    fallback: number,
  ): number {
    return this.sessions.get(progressKey(transferId, fileId))?.acceptedOffset ??
      fallback;
  }

  async checkpointAnd<T>(
    queue: TransferQueue,
    transferId: string,
    fileId: string,
    operation: () => Promise<T>,
  ): Promise<T> {
    return this.runExclusive(transferId, fileId, async () => {
      const session = this.sessions.get(progressKey(transferId, fileId));
      if (session && session.acceptedOffset > session.durableOffset) {
        const record = queue
          .snapshot()
          .batches.find((batch) => batch.transferId === transferId)
          ?.files.find((file) => file.fileId === fileId);
        if (!record?.destinationPath) {
          throw new Error("Cannot checkpoint a transfer without a destination.");
        }
        const partialPath = partialPathFor(record.destinationPath, fileId);
        const destination = await open(partialPath, "r+");
        try {
          await destination.sync();
        } finally {
          await destination.close();
        }
        await queue.confirmProgress(
          transferId,
          fileId,
          session.acceptedOffset,
        );
        session.markCheckpoint(session.acceptedOffset, this.now());
      }
      return operation();
    });
  }

  clear(transferId: string, fileId: string): void {
    this.sessions.delete(progressKey(transferId, fileId));
  }

  private now(): number {
    return this.policy.now?.() ?? performance.now();
  }
}

export class ReceiverProgressSession {
  readonly checkpointBytes: number;
  readonly checkpointIntervalMs: number;
  readonly publishIntervalMs: number;
  acceptedOffset: number;
  durableOffset: number;
  private lastCheckpointAt: number;
  private lastPublishedAt: number;

  constructor(
    record: TransferFileRecord,
    policy: ReceiverProgressPolicy = {},
  ) {
    this.checkpointBytes = policy.checkpointBytes ?? 4 * 1024 * 1024;
    this.checkpointIntervalMs = policy.checkpointIntervalMs ?? 1_000;
    this.publishIntervalMs = policy.publishIntervalMs ?? 1_000;
    this.acceptedOffset = record.confirmedOffset;
    this.durableOffset = record.confirmedOffset;
    const now = policy.now?.() ?? performance.now();
    this.lastCheckpointAt = now;
    this.lastPublishedAt = now;
  }

  shouldCheckpoint(offset: number, now: number): boolean {
    return (
      offset - this.durableOffset >= this.checkpointBytes ||
      now - this.lastCheckpointAt >= this.checkpointIntervalMs
    );
  }

  shouldPublish(now: number, immediate = false): boolean {
    return immediate || now - this.lastPublishedAt >= this.publishIntervalMs;
  }

  markAccepted(offset: number): void {
    this.acceptedOffset = offset;
  }

  markCheckpoint(offset: number, now: number): void {
    this.acceptedOffset = offset;
    this.durableOffset = offset;
    this.lastCheckpointAt = now;
  }

  markPublished(now: number): void {
    this.lastPublishedAt = now;
  }
}

export class LaptopTransferDataPlane extends TransferHttpDataPlane {
  constructor(
    private readonly chunkPairingSecret: string,
    private readonly queue: TransferQueue,
    private readonly chunkBytes = preferredTransferChunkBytes,
    private readonly publishControl: (
      message: TransferControlMessage,
    ) => void = () => undefined,
    private readonly onFileTerminal: () => void | Promise<void> = () =>
      undefined,
    private readonly enqueueLaptopFiles?: (
      paths: string[],
    ) => Promise<unknown>,
    private readonly progressOptions: ReceiverProgressPolicy = {},
    private readonly progressSessions = new ReceiverProgressSessions(
      progressOptions,
    ),
  ) {
    super(chunkPairingSecret);
  }

  protected override async handleAuthenticated(
    request: Request,
    context: { isLoopback: boolean },
  ): Promise<Response | undefined> {
    const url = new URL(request.url);
    if (
      request.method === "POST" &&
      url.pathname === "/transfer/v1/local/enqueue"
    ) {
      if (!context.isLoopback) {
        return Response.json({ code: "local_only" }, { status: 403 });
      }
      return this.handleLocalEnqueue(request, url);
    }
    if (request.method !== "GET" && request.method !== "PUT") {
      return Response.json(
        { code: "method_not_allowed" },
        { status: 405, headers: { allow: "GET, PUT" } },
      );
    }
    const match = url.pathname.match(
      /^\/transfer\/v1\/([A-Za-z0-9_-]{16,128})\/([A-Za-z0-9_-]{16,128})$/,
    );
    if (!match) return undefined;
    const [, transferId, fileId] = match;
    const offset = parseOffset(url.searchParams.get("offset"));
    if (offset === undefined) {
      return Response.json({ code: "invalid_offset" }, { status: 400 });
    }
    if (request.method === "PUT") {
      return this.handleUpload(request, transferId!, fileId!, offset);
    }
    const record = this.lookup(
      transferId!,
      fileId!,
      "laptop_to_phone",
    );
    if (!record) {
      return Response.json({ code: "transfer_not_found" }, { status: 404 });
    }
    if (offset !== record.confirmedOffset) {
      return Response.json(
        {
          code: "offset_not_confirmed",
          confirmedOffset: record.confirmedOffset,
        },
        { status: 409 },
      );
    }
    if (!record.sourcePath) {
      return Response.json({ code: "transfer_not_found" }, { status: 404 });
    }
    if (record.size > 0 && offset >= record.size) {
      return Response.json(
        { code: "range_not_satisfiable" },
        { status: 416 },
      );
    }

    let source;
    try {
      const sourceStat = await stat(record.sourcePath);
      if (
        !sourceStat.isFile() ||
        sourceStat.size !== record.size ||
        Math.trunc(sourceStat.mtimeMs) !== Math.trunc(record.lastModifiedMs)
      ) {
        return Response.json({ code: "source_changed" }, { status: 409 });
      }
      source = await open(record.sourcePath, "r");
      const plaintextBytes = Math.min(
        this.chunkBytes,
        record.maxChunkBytes ?? legacyTransferChunkBytes,
        Math.max(0, record.size - offset),
      );
      const plaintext = new Uint8Array(plaintextBytes);
      if (plaintextBytes > 0) {
        const result = await source.read(
          plaintext,
          0,
          plaintextBytes,
          offset,
        );
        if (result.bytesRead !== plaintextBytes) {
          return Response.json({ code: "source_short_read" }, { status: 409 });
        }
      }
      const metadata: TransferChunkMetadata = {
        transferId: transferId!,
        fileId: fileId!,
        offset,
        plaintextBytes,
      };
      const chunk = await encryptTransferChunk(
        metadata,
        plaintext,
        this.chunkPairingSecret,
      );
      return new Response(toArrayBuffer(chunk.ciphertext), {
        status: 200,
        headers: {
          "content-type": "application/vnd.vidyut.encrypted-chunk",
          "cache-control": "no-store",
          "x-vidyut-nonce": chunk.nonce,
          "x-vidyut-offset": String(offset),
          "x-vidyut-plaintext-bytes": String(plaintextBytes),
          "x-vidyut-total-bytes": String(record.size),
          "x-vidyut-eof": String(offset + plaintextBytes === record.size),
        },
      });
    } catch (error) {
      if (
        error &&
        typeof error === "object" &&
        "code" in error &&
        (error.code === "ENOENT" || error.code === "EACCES")
      ) {
        return Response.json(
          {
            code:
              error.code === "ENOENT"
                ? "source_unavailable"
                : "source_permission_denied",
          },
          { status: 409 },
        );
      }
      throw error;
    } finally {
      await source?.close();
    }
  }

  private async handleLocalEnqueue(
    request: Request,
    url: URL,
  ): Promise<Response> {
    if (!this.enqueueLaptopFiles) {
      return Response.json({ code: "enqueue_unavailable" }, { status: 503 });
    }
    const bytes = new Uint8Array(await request.arrayBuffer());
    const expectedDigest = url.searchParams.get("digest");
    if (!expectedDigest || (await sha256Hex(bytes)) !== expectedDigest) {
      return Response.json({ code: "body_digest_mismatch" }, { status: 400 });
    }
    let paths: unknown;
    try {
      paths = JSON.parse(new TextDecoder().decode(bytes));
    } catch {
      return Response.json({ code: "invalid_json" }, { status: 400 });
    }
    if (
      !Array.isArray(paths) ||
      paths.length === 0 ||
      paths.length > 100 ||
      paths.some((path) => typeof path !== "string" || path.length === 0)
    ) {
      return Response.json({ code: "invalid_paths" }, { status: 400 });
    }
    try {
      const offer = await this.enqueueLaptopFiles(paths as string[]);
      return Response.json({ offer }, { status: 202 });
    } catch (error) {
      return Response.json(
        {
          code: "enqueue_failed",
          message: error instanceof Error ? error.message : String(error),
        },
        { status: 400 },
      );
    }
  }

  private async handleUpload(
    request: Request,
    transferId: string,
    fileId: string,
    offset: number,
  ): Promise<Response> {
    return this.progressSessions.runExclusive(
      transferId,
      fileId,
      async () => {
        const record = this.lookup(
          transferId,
          fileId,
          "phone_to_laptop",
        );
        if (!record) {
          return Response.json({ code: "transfer_not_found" }, { status: 404 });
        }
        this.progressSessions.sessionFor(transferId, record);
        const expectedOffset = this.progressSessions.liveAcceptedOffset(
          transferId,
          fileId,
          record.confirmedOffset,
        );
        if (offset !== expectedOffset) {
          return Response.json(
            {
              code: "offset_not_confirmed",
              confirmedOffset: expectedOffset,
            },
            { status: 409 },
          );
        }
        return this.handleUploadLocked(request, transferId, fileId, offset, record);
      },
    );
  }

  private async handleUploadLocked(
    request: Request,
    transferId: string,
    fileId: string,
    offset: number,
    record: TransferFileRecord,
  ): Promise<Response> {
    if (!record.destinationPath || record.status !== "active") {
      return Response.json({ code: "transfer_not_active" }, { status: 409 });
    }
    const nonce = request.headers.get("x-vidyut-nonce");
    const plaintextBytes = parseNonNegativeInteger(
      request.headers.get("x-vidyut-plaintext-bytes"),
    );
    if (
      !nonce ||
      plaintextBytes === undefined ||
      plaintextBytes > this.chunkBytes ||
      offset + plaintextBytes > record.size ||
      (record.size > 0 && plaintextBytes === 0)
    ) {
      return Response.json({ code: "invalid_chunk" }, { status: 400 });
    }
    const contentLength = parseNonNegativeInteger(
      request.headers.get("content-length"),
    );
    if (
      contentLength !== undefined &&
      contentLength > this.chunkBytes + 16
    ) {
      return Response.json({ code: "chunk_too_large" }, { status: 413 });
    }
    const ciphertext = new Uint8Array(await request.arrayBuffer());
    if (ciphertext.byteLength > this.chunkBytes + 16) {
      return Response.json({ code: "chunk_too_large" }, { status: 413 });
    }

    let plaintext: Uint8Array;
    try {
      const chunk: EncryptedTransferChunk = {
        transferId,
        fileId,
        offset,
        plaintextBytes,
        nonce,
        ciphertext,
      };
      plaintext = await decryptTransferChunk(
        chunk,
        this.chunkPairingSecret,
      );
    } catch {
      return Response.json(
        { code: "chunk_auth_failed" },
        { status: 400 },
      );
    }

    const partialPath = partialPathFor(record.destinationPath, fileId);
    await mkdir(dirname(partialPath), { recursive: true });
    let destination;
    try {
      destination = await open(partialPath, offset === 0 ? "w+" : "r+");
    } catch (error) {
      if (
        error &&
        typeof error === "object" &&
        "code" in error &&
        error.code === "ENOENT"
      ) {
        await unlink(partialPath).catch(() => undefined);
        await this.queue.fail(
          transferId,
          fileId,
          "partial_state_missing",
        );
        this.publishControl({
          v: 1,
          kind: "transfer_file_failed",
          transferId,
          fileId,
          code: "partial_state_missing",
        });
        this.progressSessions.clear(transferId, fileId);
        await this.onFileTerminal();
        return Response.json(
          { code: "partial_state_missing", confirmedOffset: 0 },
          { status: 409 },
        );
      }
      throw error;
    }
    const hasTimingStage = (stage: string): boolean =>
      record.timing?.attempts.at(-1)?.stages[stage] !== undefined;
    const firstPayloadStarted = !hasTimingStage(
        transferTimingStage.firstPayloadByte,
      );
    const lastPayloadStarted =
      offset + plaintextBytes === record.size &&
      !hasTimingStage(transferTimingStage.lastPayloadByte);
    const progress = this.progressSessions.sessionFor(transferId, record);
    const confirmedOffset = offset + plaintextBytes;
    const now = this.progressOptions.now?.() ?? performance.now();
    const checkpointDue =
      confirmedOffset === record.size ||
      progress.shouldCheckpoint(confirmedOffset, now);
    try {
      if (firstPayloadStarted) {
        await this.queue.markStage(
          transferId,
          fileId,
          transferTimingStage.firstPayloadByte,
        );
      }
      if (lastPayloadStarted) {
        await this.queue.markStage(
          transferId,
          fileId,
          transferTimingStage.lastPayloadByte,
        );
      }
      if (plaintext.byteLength > 0) {
        const result = await destination.write(
          plaintext,
          0,
          plaintext.byteLength,
          offset,
        );
        if (result.bytesWritten !== plaintext.byteLength) {
          return Response.json(
            { code: "destination_short_write" },
            { status: 507 },
          );
        }
      }
      if (checkpointDue) await destination.sync();
    } finally {
      await destination.close();
    }

    if (firstPayloadStarted) {
      await this.queue.markStage(
        transferId,
        fileId,
        transferTimingStage.firstPayloadByte,
        true,
      );
    }
    if (lastPayloadStarted) {
      await this.queue.markStage(
        transferId,
        fileId,
        transferTimingStage.lastPayloadByte,
        true,
      );
    }

    const publishDue =
      checkpointDue || progress.shouldPublish(now);
    if (confirmedOffset === record.size) {
      await this.queue.beginVerification(
        transferId,
        fileId,
        confirmedOffset,
      );
      progress.markCheckpoint(confirmedOffset, now);
    } else if (checkpointDue) {
      await this.queue.confirmProgress(transferId, fileId, confirmedOffset);
      progress.markCheckpoint(confirmedOffset, now);
    } else {
      progress.markAccepted(confirmedOffset);
    }
    if (publishDue) {
      this.publishControl({
        v: 1,
        kind: "transfer_progress",
        transferId,
        fileId,
        confirmedOffset,
      });
      progress.markPublished(now);
    }

    if (confirmedOffset === record.size) {
      let verifiedSha256: string;
      try {
        verifiedSha256 = await hashFile(partialPath);
        if (verifiedSha256 !== record.sha256) {
          await unlink(partialPath).catch(() => undefined);
          await this.queue.fail(transferId, fileId, "hash_mismatch");
          this.publishControl({
            v: 1,
            kind: "transfer_file_failed",
            transferId,
            fileId,
            code: "hash_mismatch",
          });
          this.progressSessions.clear(transferId, fileId);
          await this.onFileTerminal();
          return Response.json({ code: "hash_mismatch" }, { status: 409 });
        }
        const finalizedPath = await finalizeWithoutOverwrite(
          partialPath,
          record.destinationPath,
          (candidate) =>
            this.queue.beginFinalization(transferId, fileId, candidate),
        );
        await this.queue.complete(transferId, fileId, verifiedSha256);
        await unlink(partialPath).catch(() => undefined);
        if (record.lastModifiedKnown !== false) {
          const modified = new Date(record.lastModifiedMs);
          await utimes(finalizedPath, modified, modified).catch(() => undefined);
        }
      } catch {
        const current = this.lookup(transferId, fileId, "phone_to_laptop");
        if (current?.status === "completed") {
          this.publishControl({
            v: 1,
            kind: "transfer_file_complete",
            transferId,
            fileId,
            sha256: record.sha256,
          });
          this.progressSessions.clear(transferId, fileId);
          await this.onFileTerminal();
          return Response.json({ confirmedOffset, complete: true });
        }
        if (current?.finalizingPath) {
          await unlinkFinalizedLink(
            partialPath,
            current.finalizingPath,
          );
        }
        await unlink(partialPath).catch(() => undefined);
        await this.queue.fail(
          transferId,
          fileId,
          "terminal_processing_failed",
        );
        this.publishControl({
          v: 1,
          kind: "transfer_file_failed",
          transferId,
          fileId,
          code: "terminal_processing_failed",
        });
        this.progressSessions.clear(transferId, fileId);
        await this.onFileTerminal();
        return Response.json(
          { code: "terminal_processing_failed" },
          { status: 500 },
        );
      }
      this.publishControl({
        v: 1,
        kind: "transfer_file_complete",
        transferId,
        fileId,
        sha256: verifiedSha256,
      });
      this.progressSessions.clear(transferId, fileId);
      await this.onFileTerminal();
    }

    return Response.json({
      confirmedOffset,
      complete: confirmedOffset === record.size,
    });
  }

  private lookup(
    transferId: string,
    fileId: string,
    direction: "laptop_to_phone" | "phone_to_laptop",
  ): TransferFileRecord | undefined {
    const batch = this.queue
      .snapshot()
      .batches.find((candidate) => candidate.transferId === transferId);
    if (!batch || batch.direction !== direction) return undefined;
    return batch.files.find((candidate) => candidate.fileId === fileId);
  }
}

function parseOffset(value: string | null): number | undefined {
  if (value === null || !/^(0|[1-9][0-9]*)$/.test(value)) return undefined;
  const offset = Number(value);
  return Number.isSafeInteger(offset) && offset >= 0 ? offset : undefined;
}

function progressKey(transferId: string, fileId: string): string {
  return `${transferId}:${fileId}`;
}

function parseNonNegativeInteger(value: string | null): number | undefined {
  if (value === null || !/^(0|[1-9][0-9]*)$/.test(value)) return undefined;
  const parsed = Number(value);
  return Number.isSafeInteger(parsed) && parsed >= 0 ? parsed : undefined;
}

async function hashFile(path: string): Promise<string> {
  const hasher = new Bun.CryptoHasher("sha256");
  for await (const chunk of Bun.file(path).stream()) {
    hasher.update(chunk);
  }
  return hasher.digest("hex");
}

async function finalizeWithoutOverwrite(
  partialPath: string,
  requestedPath: string,
  beforeLink: (candidate: string) => Promise<void>,
): Promise<string> {
  const extension = extname(requestedPath);
  const stem = basename(requestedPath, extension);
  const parent = dirname(requestedPath);
  for (let suffix = 0; suffix < 10_000; suffix += 1) {
    const candidate =
      suffix === 0
        ? requestedPath
        : join(parent, `${stem} (${suffix})${extension}`);
    await beforeLink(candidate);
    try {
      await link(partialPath, candidate);
      return candidate;
    } catch (error) {
      if (
        error &&
        typeof error === "object" &&
        "code" in error &&
        error.code === "EEXIST"
      ) {
        continue;
      }
      throw error;
    }
  }
  throw new Error("Could not resolve a collision-free destination.");
}

async function unlinkFinalizedLink(
  partialPath: string,
  finalizedPath: string,
): Promise<void> {
  try {
    const [partial, finalized] = await Promise.all([
      stat(partialPath),
      stat(finalizedPath),
    ]);
    if (partial.dev === finalized.dev && partial.ino === finalized.ino) {
      await unlink(finalizedPath);
    }
  } catch {
    // A missing or unrelated destination must never be removed.
  }
}

function toArrayBuffer(bytes: Uint8Array): ArrayBuffer {
  const buffer = new ArrayBuffer(bytes.byteLength);
  new Uint8Array(buffer).set(bytes);
  return buffer;
}
