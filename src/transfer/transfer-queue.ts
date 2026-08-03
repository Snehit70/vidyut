import {
  mkdir,
  readFile,
  rename,
  stat,
  unlink,
  writeFile,
} from "node:fs/promises";
import { dirname } from "node:path";
import type {
  TransferDirection,
  TransferFileOffer,
  TransferOffer,
  TransferTimingSummary,
} from "../shared/wire";
import { isTransferOffer } from "../shared/wire";
import { partialPathFor } from "./transfer-paths";

export type TransferFileStatus =
  | "queued"
  | "active"
  | "verifying"
  | "finalizing"
  | "paused"
  | "completed"
  | "failed"
  | "cancelled";

export type TransferBatchStatus =
  | "queued"
  | "active"
  | "paused"
  | "completed"
  | "completed_with_issues"
  | "cancelled"
  | "expired";

export interface TransferFileRecord extends TransferFileOffer {
  sourcePath?: string;
  destinationPath?: string;
  finalizingPath?: string;
  maxChunkBytes?: number;
  status: TransferFileStatus;
  confirmedOffset: number;
  errorCode?: string;
  timing?: TransferTimingSummary;
}

export const transferTimingStage = {
  firstPayloadByte: "first_payload_byte",
  lastPayloadByte: "last_payload_byte",
  receiverVerification: "receiver_verification",
  publishFinalization: "publish_finalization",
  durableCompletion: "durable_completion",
} as const;

export interface TransferBatchRecord {
  transferId: string;
  batchId: string;
  origin: string;
  direction: TransferDirection;
  createdAtMs: number;
  updatedAtMs: number;
  expiresAtMs: number;
  status: TransferBatchStatus;
  files: TransferFileRecord[];
}

export interface TransferQueueSnapshot {
  v: 1;
  batches: TransferBatchRecord[];
}

export interface TransferQueueStorage {
  load(): Promise<TransferQueueSnapshot | undefined>;
  save(snapshot: TransferQueueSnapshot): Promise<void>;
}

export interface EnqueueTransferFile {
  filename: string;
  mime: string;
  size: number;
  lastModifiedMs: number;
  sha256: string;
  sourcePath?: string;
  destinationPath?: string;
}

export interface TransferClaim {
  batch: TransferBatchRecord;
  file: TransferFileRecord;
}

const sevenDaysMs = 7 * 24 * 60 * 60 * 1000;

export class TransferQueue {
  private readonly monotonicAnchors = new Map<string, number>();
  private constructor(
    private readonly storage: TransferQueueStorage,
    private state: TransferQueueSnapshot,
    private readonly now: () => number,
    private readonly id: (prefix: string) => string,
    private readonly monotonicNow: () => number,
  ) {}

  static async open({
    storage,
    now = Date.now,
    id = defaultId,
    monotonicNow = () => performance.now(),
  }: {
    storage: TransferQueueStorage;
    now?: () => number;
    id?: (prefix: string) => string;
    monotonicNow?: () => number;
  }): Promise<TransferQueue> {
    const state = (await storage.load()) ?? { v: 1, batches: [] };
    assertSnapshot(state);
    const queue = new TransferQueue(storage, state, now, id, monotonicNow);
    await queue.recoverInterrupted();
    await queue.expire();
    return queue;
  }

  snapshot(): TransferQueueSnapshot {
    return structuredClone(this.state);
  }

  async enqueue({
    direction,
    origin,
    files,
  }: {
    direction: TransferDirection;
    origin: string;
    files: EnqueueTransferFile[];
  }): Promise<TransferBatchRecord> {
    if (files.length === 0) throw new RangeError("A batch needs at least one file.");
    const timestamp = this.now();
    const batchId = this.id("batch");
    const transferId = this.id("transfer");
    const batch: TransferBatchRecord = {
      transferId,
      batchId,
      origin,
      direction,
      createdAtMs: timestamp,
      updatedAtMs: timestamp,
      expiresAtMs: timestamp + sevenDaysMs,
      status: "queued",
      files: files.map((file) => ({
        ...file,
        fileId: this.id("file"),
        status: "queued",
        confirmedOffset: 0,
        timing: this.newTiming(),
      })),
    };
    assertBatch(batch);
    this.state.batches.push(batch);
    await this.persist();
    return structuredClone(batch);
  }

  async acceptOffer(
    offer: TransferOffer,
    destinationPaths: ReadonlyMap<string, string>,
  ): Promise<TransferBatchRecord> {
    if (!isTransferOffer(offer)) throw new Error("Invalid transfer offer.");
    if (offer.files.some((file) => !destinationPaths.get(file.fileId))) {
      throw new Error("Every received file needs a destination path.");
    }
    const existing = this.state.batches.find(
      (batch) => batch.transferId === offer.transferId,
    );
    if (existing) {
      if (!offersMatch(this.offer(existing.transferId), offer)) {
        throw new Error("Transfer identity conflicts with an existing offer.");
      }
      return structuredClone(existing);
    }
    const timestamp = this.now();
    const batch: TransferBatchRecord = {
      ...offer,
      updatedAtMs: timestamp,
      expiresAtMs: timestamp + sevenDaysMs,
      status: "queued",
      files: offer.files.map((file) => ({
        ...file,
        destinationPath: destinationPaths.get(file.fileId)!,
        status: "queued",
        confirmedOffset: 0,
        timing: this.newTiming(),
      })),
    };
    assertBatch(batch);
    this.state.batches.push(batch);
    await this.persist();
    return structuredClone(batch);
  }

  offer(transferId: string): TransferOffer {
    const batch = this.findBatch(transferId);
    return {
      transferId: batch.transferId,
      batchId: batch.batchId,
      origin: batch.origin,
      direction: batch.direction,
      createdAtMs: batch.createdAtMs,
      files: batch.files.map(
        ({
          fileId,
          filename,
          mime,
          size,
          lastModifiedMs,
          lastModifiedKnown,
          sha256,
          senderTiming,
        }) => ({
          fileId,
          filename,
          mime,
          size,
          lastModifiedMs,
          ...(lastModifiedKnown === undefined ? {} : { lastModifiedKnown }),
          sha256,
          ...(senderTiming === undefined ? {} : { senderTiming }),
        }),
      ),
    };
  }

  async claimNext(): Promise<TransferClaim | undefined> {
    await this.expire();
    if (
      this.state.batches.some((batch) =>
        batch.files.some(
          (file) =>
            file.status === "active" ||
            file.status === "verifying" ||
            file.status === "finalizing",
        ),
      )
    ) {
      return undefined;
    }
    for (const batch of this.state.batches) {
      if (isTerminalBatch(batch.status) || batch.status === "paused") continue;
      const file = batch.files.find((candidate) => candidate.status === "queued");
      if (!file) continue;
      file.status = "active";
      batch.status = "active";
      this.touch(batch);
      await this.persist();
      return {
        batch: structuredClone(batch),
        file: structuredClone(file),
      };
    }
    return undefined;
  }

  async confirmProgress(
    transferId: string,
    fileId: string,
    confirmedOffset: number,
    maxChunkBytes?: number,
  ): Promise<void> {
    const { batch, file } = this.findFile(transferId, fileId);
    if (file.status !== "active") {
      throw new Error("Only an active file can confirm progress.");
    }
    if (
      !Number.isSafeInteger(confirmedOffset) ||
      confirmedOffset < file.confirmedOffset ||
      confirmedOffset > file.size
    ) {
      throw new RangeError("Confirmed offset must be monotonic and within the file.");
    }
    if (
      maxChunkBytes !== undefined &&
      (!Number.isSafeInteger(maxChunkBytes) || maxChunkBytes <= 0)
    ) {
      throw new RangeError("Maximum chunk bytes must be a positive integer.");
    }
    file.confirmedOffset = confirmedOffset;
    if (maxChunkBytes !== undefined) file.maxChunkBytes = maxChunkBytes;
    this.touch(batch);
    await this.persist();
  }

  async complete(
    transferId: string,
    fileId: string,
    verifiedSha256: string,
  ): Promise<void> {
    const { batch, file } = this.findFile(transferId, fileId);
    if (
      file.status !== "active" &&
      file.status !== "verifying" &&
      file.status !== "finalizing"
    ) {
      throw new Error(
        "Only an active, verifying, or finalizing file can complete.",
      );
    }
    if (file.confirmedOffset !== file.size) {
      throw new Error("A file cannot complete before every byte is confirmed.");
    }
    if (verifiedSha256 !== file.sha256) {
      throw new Error("Whole-file hash does not match the offer.");
    }
    if (file.finalizingPath) {
      file.destinationPath = file.finalizingPath;
      delete file.finalizingPath;
    }
    file.status = "completed";
    this.markTiming(
      transferId,
      fileId,
      file,
      transferTimingStage.publishFinalization,
      true,
    );
    this.markTiming(
      transferId,
      fileId,
      file,
      transferTimingStage.durableCompletion,
      true,
    );
    delete file.errorCode;
    this.deriveBatchStatus(batch);
    await this.persist();
  }

  async beginVerification(
    transferId: string,
    fileId: string,
    confirmedOffset: number,
  ): Promise<void> {
    const { batch, file } = this.findFile(transferId, fileId);
    if (file.status !== "active") {
      throw new Error("Only an active file can begin verification.");
    }
    if (confirmedOffset !== file.size || confirmedOffset < file.confirmedOffset) {
      throw new RangeError(
        "Verification can begin only after every byte is confirmed.",
      );
    }
    file.confirmedOffset = confirmedOffset;
    file.status = "verifying";
    this.markTiming(
      transferId,
      fileId,
      file,
      transferTimingStage.receiverVerification,
      false,
    );
    this.deriveBatchStatus(batch);
    await this.persist();
  }

  async beginFinalization(
    transferId: string,
    fileId: string,
    destinationPath: string,
  ): Promise<void> {
    if (!destinationPath) throw new Error("Final destination cannot be empty.");
    const { batch, file } = this.findFile(transferId, fileId);
    if (file.status !== "verifying" && file.status !== "finalizing") {
      throw new Error("Only a verifying file can begin finalization.");
    }
    file.status = "finalizing";
    this.markTiming(
      transferId,
      fileId,
      file,
      transferTimingStage.receiverVerification,
      true,
    );
    this.markTiming(
      transferId,
      fileId,
      file,
      transferTimingStage.publishFinalization,
      false,
    );
    file.finalizingPath = destinationPath;
    this.deriveBatchStatus(batch);
    await this.persist();
  }

  async markStage(
    transferId: string,
    fileId: string,
    stage: string,
    end = false,
  ): Promise<void> {
    const { batch, file } = this.findFile(transferId, fileId);
    this.markTiming(transferId, fileId, file, stage, end);
    this.touch(batch);
    await this.persist();
  }

  async fail(
    transferId: string,
    fileId: string,
    errorCode: string,
  ): Promise<void> {
    const { batch, file } = this.findFile(transferId, fileId);
    if (isTerminalFile(file.status)) return;
    file.status = "failed";
    file.errorCode = errorCode;
    delete file.finalizingPath;
    this.deriveBatchStatus(batch);
    await this.persist();
  }

  async pause(transferId: string, fileId?: string): Promise<void> {
    const batch = this.findBatch(transferId);
    if (fileId) {
      const file = this.findFile(transferId, fileId).file;
      if (file.status === "queued" || file.status === "active") {
        file.status = "paused";
      }
      this.deriveBatchStatus(batch);
    } else {
      for (const file of batch.files) {
        if (file.status === "queued" || file.status === "active") {
          file.status = "paused";
        }
      }
      batch.status = "paused";
      this.touch(batch);
    }
    await this.persist();
  }

  async resume(transferId: string, fileId?: string): Promise<void> {
    const batch = this.findBatch(transferId);
    const files = fileId
      ? [this.findFile(transferId, fileId).file]
      : batch.files;
    for (const file of files) {
      if (file.status === "paused") file.status = "queued";
    }
    this.deriveBatchStatus(batch);
    await this.persist();
  }

  async cancel(transferId: string, fileId?: string): Promise<void> {
    const batch = this.findBatch(transferId);
    const files = fileId
      ? [this.findFile(transferId, fileId).file]
      : batch.files;
    for (const file of files) {
      if (!isTerminalFile(file.status)) {
        file.status = "cancelled";
        delete file.errorCode;
      }
    }
    this.deriveBatchStatus(batch);
    await this.persist();
  }

  async retry(transferId: string, fileId?: string): Promise<void> {
    const batch = this.findBatch(transferId);
    const files = fileId
      ? [this.findFile(transferId, fileId).file]
      : batch.files;
    for (const file of files) {
      if (file.status === "failed") {
        const timing = file.timing ?? this.newTiming();
        const attempt = (timing.attempts.at(-1)?.attempt ?? -1) + 1;
        timing.attempts = [
          ...timing.attempts,
          { attempt, stages: {} },
        ].slice(-4);
        file.status = "queued";
        file.confirmedOffset = 0;
        file.timing = timing;
        delete file.errorCode;
        delete file.finalizingPath;
      }
    }
    this.deriveBatchStatus(batch);
    await this.persist();
  }

  async setDestinationPath(
    transferId: string,
    fileId: string,
    destinationPath: string,
  ): Promise<void> {
    if (!destinationPath) throw new Error("Destination path cannot be empty.");
    const { batch, file } = this.findFile(transferId, fileId);
    file.destinationPath = destinationPath;
    this.touch(batch);
    await this.persist();
  }

  async expire(): Promise<void> {
    const now = this.now();
    let changed = false;
    for (const batch of this.state.batches) {
      if (!isTerminalBatch(batch.status) && batch.expiresAtMs <= now) {
        batch.status = "expired";
        for (const file of batch.files) {
          if (!isTerminalFile(file.status)) {
            file.status = "failed";
            file.errorCode = "transfer_expired";
          }
        }
        batch.updatedAtMs = now;
        changed = true;
      }
    }
    if (changed) await this.persist();
  }

  private async recoverInterrupted(): Promise<void> {
    let changed = false;
    for (const batch of this.state.batches) {
      if (isTerminalBatch(batch.status)) continue;
      let batchChanged = false;
      for (const file of batch.files) {
        if (file.status === "finalizing") {
          const partialPath = file.destinationPath
            ? partialPathFor(file.destinationPath, file.fileId)
            : undefined;
          if (
            partialPath &&
            file.finalizingPath &&
            await pathsShareInode(partialPath, file.finalizingPath)
          ) {
            const finalizedPath = file.finalizingPath;
            file.destinationPath = finalizedPath;
            delete file.finalizingPath;
            delete file.errorCode;
            file.status = "completed";
            this.deriveBatchStatus(batch);
            await this.persist();
            await unlink(partialPath).catch(() => undefined);
          } else {
            if (partialPath) {
              await unlink(partialPath).catch(() => undefined);
            }
            delete file.finalizingPath;
            file.status = "failed";
            file.errorCode = "finalization_interrupted";
            batchChanged = true;
          }
        } else if (
          file.status === "verifying" ||
          (file.status === "active" &&
            file.size > 0 &&
            file.confirmedOffset === file.size)
        ) {
          if (file.destinationPath) {
            await unlink(
              partialPathFor(file.destinationPath, file.fileId),
            ).catch(() => undefined);
          }
          file.status = "failed";
          file.errorCode = "verification_interrupted";
          batchChanged = true;
        } else if (file.status === "active") {
          file.status = "queued";
          batchChanged = true;
        }
      }
      if (batchChanged) {
        this.deriveBatchStatus(batch);
        changed = true;
      }
    }
    if (changed) await this.persist();
  }

  private deriveBatchStatus(batch: TransferBatchRecord): void {
    if (batch.files.every((file) => file.status === "completed")) {
      batch.status = "completed";
    } else if (batch.files.every((file) => file.status === "cancelled")) {
      batch.status = "cancelled";
    } else if (batch.files.every((file) => isTerminalFile(file.status))) {
      batch.status = "completed_with_issues";
    } else if (
      batch.files.some(
        (file) =>
          file.status === "active" ||
          file.status === "verifying" ||
          file.status === "finalizing",
      )
    ) {
      batch.status = "active";
    } else if (
      batch.files.some((file) => file.status === "queued")
    ) {
      batch.status = "queued";
    } else {
      batch.status = "paused";
    }
    this.touch(batch);
  }

  private touch(batch: TransferBatchRecord): void {
    const timestamp = this.now();
    batch.updatedAtMs = timestamp;
    batch.expiresAtMs = timestamp + sevenDaysMs;
  }

  private findBatch(transferId: string): TransferBatchRecord {
    const batch = this.state.batches.find(
      (candidate) => candidate.transferId === transferId,
    );
    if (!batch) throw new Error(`Unknown transfer: ${transferId}`);
    return batch;
  }

  private findFile(
    transferId: string,
    fileId: string,
  ): { batch: TransferBatchRecord; file: TransferFileRecord } {
    const batch = this.findBatch(transferId);
    const file = batch.files.find((candidate) => candidate.fileId === fileId);
    if (!file) throw new Error(`Unknown file: ${fileId}`);
    return { batch, file };
  }

  private async persist(): Promise<void> {
    await this.storage.save(this.snapshot());
  }

  private newTiming(): TransferTimingSummary {
    return { v: 1, wallAnchorMs: this.now(), attempts: [] };
  }

  private markTiming(
    transferId: string,
    fileId: string,
    file: TransferFileRecord,
    stage: string,
    end: boolean,
  ): void {
    const timing = file.timing ?? this.newTiming();
    let attempt = timing.attempts.at(-1);
    if (!attempt) {
      attempt = { attempt: 0, stages: {} };
      timing.attempts.push(attempt);
    }
    const now = this.monotonicNow();
    const key = `${transferId}:${fileId}`;
    const anchor = this.monotonicAnchors.get(key) ?? now;
    this.monotonicAnchors.set(key, anchor);
    const elapsed = Math.max(0, Math.round(now - anchor));
    const current = attempt.stages[stage];
    const startMs = current?.startMs ?? elapsed;
    attempt.stages[stage] = {
      startMs,
      ...(end
        ? { endMs: Math.max(startMs, elapsed) }
        : current?.endMs === undefined
        ? {}
        : { endMs: current.endMs }),
    };
    timing.attempts = timing.attempts.slice(-4);
    file.timing = timing;
  }
}

function offersMatch(left: TransferOffer, right: TransferOffer): boolean {
  const normalize = (offer: TransferOffer) => ({
    transferId: offer.transferId,
    batchId: offer.batchId,
    origin: offer.origin,
    direction: offer.direction,
    createdAtMs: offer.createdAtMs,
    files: [...offer.files]
      .map(({ senderTiming: _senderTiming, ...file }) => file)
      .sort((a, b) => a.fileId.localeCompare(b.fileId)),
  });
  return JSON.stringify(normalize(left)) === JSON.stringify(normalize(right));
}

export class JsonTransferQueueStorage implements TransferQueueStorage {
  constructor(private readonly path: string) {}

  async load(): Promise<TransferQueueSnapshot | undefined> {
    try {
      return JSON.parse(
        await readFile(this.path, "utf8"),
      ) as TransferQueueSnapshot;
    } catch (error) {
      if (
        error &&
        typeof error === "object" &&
        "code" in error &&
        error.code === "ENOENT"
      ) {
        return undefined;
      }
      throw error;
    }
  }

  async save(snapshot: TransferQueueSnapshot): Promise<void> {
    await mkdir(dirname(this.path), { recursive: true });
    const temporaryPath = `${this.path}.${crypto.randomUUID()}.tmp`;
    await writeFile(
      temporaryPath,
      `${JSON.stringify(snapshot, null, 2)}\n`,
      { mode: 0o600 },
    );
    await rename(temporaryPath, this.path);
  }
}

function defaultId(prefix: string): string {
  return `${prefix}_${crypto.randomUUID().replaceAll("-", "")}`;
}

function isTerminalFile(status: TransferFileStatus): boolean {
  return (
    status === "completed" ||
    status === "failed" ||
    status === "cancelled"
  );
}

function isTerminalBatch(status: TransferBatchStatus): boolean {
  return (
    status === "completed" ||
    status === "completed_with_issues" ||
    status === "cancelled" ||
    status === "expired"
  );
}

async function pathsShareInode(left: string, right: string): Promise<boolean> {
  try {
    const [leftStat, rightStat] = await Promise.all([stat(left), stat(right)]);
    return leftStat.dev === rightStat.dev && leftStat.ino === rightStat.ino;
  } catch {
    return false;
  }
}

function assertSnapshot(snapshot: TransferQueueSnapshot): void {
  if (
    snapshot.v !== 1 ||
    !Array.isArray(snapshot.batches)
  ) {
    throw new Error("Invalid transfer queue snapshot.");
  }
  snapshot.batches.forEach(assertBatch);
}

function assertBatch(batch: TransferBatchRecord): void {
  if (
    batch.files.length === 0 ||
    new Set(batch.files.map((file) => file.fileId)).size !==
      batch.files.length
  ) {
    throw new Error("Invalid transfer batch.");
  }
  for (const file of batch.files) {
    if (
      !Number.isSafeInteger(file.size) ||
      file.size < 0 ||
      !Number.isSafeInteger(file.confirmedOffset) ||
      file.confirmedOffset < 0 ||
      file.confirmedOffset > file.size
      || (file.maxChunkBytes !== undefined &&
        (!Number.isSafeInteger(file.maxChunkBytes) || file.maxChunkBytes <= 0))
    ) {
      throw new Error("Invalid transfer file progress.");
    }
    if (file.timing !== undefined && !isTiming(file.timing)) {
      throw new Error("Invalid transfer timing summary.");
    }
  }
}

function isTiming(value: TransferTimingSummary): boolean {
  return value.v === 1 && Number.isSafeInteger(value.wallAnchorMs) &&
    Array.isArray(value.attempts) && value.attempts.length <= 4 &&
    value.attempts.every((attempt) => Number.isSafeInteger(attempt.attempt) &&
      Object.values(attempt.stages).every((span) =>
        Number.isFinite(span.startMs) &&
        (span.endMs === undefined || span.endMs >= span.startMs)));
}
