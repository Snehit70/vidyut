import { mkdir, stat, statfs } from "node:fs/promises";
import { basename, join } from "node:path";
import type {
  TransferControlMessage,
  TransferOffer,
} from "../shared/wire";
import { isTransferOffer } from "../shared/wire";
import {
  TransferQueue,
  type EnqueueTransferFile,
  type TransferClaim,
} from "./transfer-queue";
import {
  legacyTransferChunkBytes,
  negotiateTransferChunkBytes,
} from "./transfer-chunk-policy";

export interface TransferCoordinatorOptions {
  queue: TransferQueue;
  destinationDirectory: string;
  maxFileBytes: number;
  maxChunkBytes?: number;
  publishControl(message: TransferControlMessage): void;
  availableBytes?: (path: string) => Promise<number>;
}

export class TransferCoordinator {
  constructor(private readonly options: TransferCoordinatorOptions) {}

  async start(): Promise<void> {
    await mkdir(this.options.destinationDirectory, { recursive: true });
    await this.activateNext();
  }

  async enqueueLaptopFiles(paths: string[]): Promise<TransferOffer> {
    if (paths.length === 0) throw new RangeError("Select at least one file.");
    const files: EnqueueTransferFile[] = [];
    for (const path of paths) {
      const info = await stat(path);
      if (!info.isFile()) {
        throw new Error(`Only regular files can be transferred: ${path}`);
      }
      if (info.size > this.options.maxFileBytes) {
        throw new Error(`File exceeds the receiving limit: ${path}`);
      }
      files.push({
        filename: basename(path),
        mime: mimeForPath(path),
        size: info.size,
        lastModifiedMs: info.mtimeMs,
        sha256: await hashPath(path),
        sourcePath: path,
      });
    }
    const batch = await this.options.queue.enqueue({
      direction: "laptop_to_phone",
      origin: "laptop",
      files,
    });
    await this.activateNext();
    return this.options.queue.offer(batch.transferId);
  }

  async handleControl(
    message: TransferControlMessage,
    _sourceDeviceId: string,
  ): Promise<void> {
    switch (message.kind) {
      case "transfer_offer":
        {
          const existing = await this.acceptPhoneOffer(message.offer);
          const activated = await this.activateNext();
          if (existing) {
            this.republishPhoneProgress(
              message.offer.transferId,
              activated === undefined,
            );
          }
        }
        return;
      case "transfer_accept":
        await this.acceptReceiverOffset(
          message.transferId,
          message.fileId,
          message.confirmedOffset,
          message.maxChunkBytes,
        );
        return;
      case "transfer_progress":
        await this.options.queue.confirmProgress(
          message.transferId,
          message.fileId,
          message.confirmedOffset,
        );
        return;
      case "transfer_file_complete":
        await this.options.queue.complete(
          message.transferId,
          message.fileId,
          message.sha256,
        );
        await this.activateNext();
        return;
      case "transfer_file_failed":
        await this.options.queue.fail(
          message.transferId,
          message.fileId,
          message.code,
        );
        await this.activateNext();
        return;
      case "transfer_pause":
        await this.options.queue.pause(message.transferId, message.fileId);
        await this.activateNext();
        return;
      case "transfer_resume":
        await this.options.queue.resume(message.transferId, message.fileId);
        await this.activateNext();
        return;
      case "transfer_cancel":
        await this.options.queue.cancel(message.transferId, message.fileId);
        await this.activateNext();
    }
  }

  async activateNext(): Promise<TransferClaim | undefined> {
    const claim = await this.options.queue.claimNext();
    if (!claim) return undefined;
    if (claim.batch.direction === "phone_to_laptop") {
      this.publishPhoneAccept(claim.batch.transferId, claim.file);
    } else {
      this.options.publishControl({
        v: 1,
        kind: "transfer_offer",
        offer: this.options.queue.offer(claim.batch.transferId),
      });
    }
    return claim;
  }

  private republishPhoneProgress(
    transferId: string,
    includeActive: boolean,
  ): void {
    const batch = this.options.queue.snapshot().batches.find(
      (candidate) => candidate.transferId === transferId,
    );
    if (!batch || batch.direction !== "phone_to_laptop") return;
    for (const file of batch.files) {
      if (file.status === "completed") {
        this.publishPhoneComplete(batch.transferId, file);
      } else if (file.status === "failed") {
        this.publishPhoneFailure(batch.transferId, file);
      } else if (
        includeActive &&
        file.status === "active" &&
        (file.size === 0 || file.confirmedOffset < file.size)
      ) {
        this.publishPhoneAccept(batch.transferId, file);
      }
    }
  }

  private publishPhoneAccept(
    transferId: string,
    file: { fileId: string; confirmedOffset: number },
  ): void {
    this.options.publishControl({
      v: 1,
      kind: "transfer_accept",
      transferId,
      fileId: file.fileId,
      confirmedOffset: file.confirmedOffset,
      ...(this.options.maxChunkBytes === undefined
        ? {}
        : { maxChunkBytes: this.options.maxChunkBytes }),
    });
  }

  private publishPhoneComplete(
    transferId: string,
    file: { fileId: string; sha256: string },
  ): void {
    this.options.publishControl({
      v: 1,
      kind: "transfer_file_complete",
      transferId,
      fileId: file.fileId,
      sha256: file.sha256,
    });
  }

  private publishPhoneFailure(
    transferId: string,
    file: { fileId: string; errorCode?: string },
  ): void {
    this.options.publishControl({
      v: 1,
      kind: "transfer_file_failed",
      transferId,
      fileId: file.fileId,
      code: file.errorCode ?? "transfer_failed",
    });
  }

  private async acceptPhoneOffer(offer: TransferOffer): Promise<boolean> {
    if (!isTransferOffer(offer)) {
      throw new Error("Invalid phone transfer offer.");
    }
    if (offer.direction !== "phone_to_laptop") {
      throw new Error("Phone may only offer phone-to-laptop transfers.");
    }
    const tooLarge = offer.files.find(
      (file) => file.size > this.options.maxFileBytes,
    );
    if (tooLarge) {
      this.options.publishControl({
        v: 1,
        kind: "transfer_file_failed",
        transferId: offer.transferId,
        fileId: tooLarge.fileId,
        code: "file_too_large",
      });
      return false;
    }
    const existingBatch = this.options.queue
      .snapshot()
      .batches.find((batch) => batch.transferId === offer.transferId);
    const requiredBytes = existingBatch
      ? existingBatch.files.reduce(
          (total, file) =>
            file.status === "queued" ||
            file.status === "active" ||
            file.status === "paused"
              ? total + Math.max(0, file.size - file.confirmedOffset)
              : total,
          0,
        )
      : offer.files.reduce((total, file) => total + file.size, 0);
    const availableBytes = await (
      this.options.availableBytes ?? defaultAvailableBytes
    )(this.options.destinationDirectory);
    if (requiredBytes > availableBytes) {
      for (const file of offer.files) {
        this.options.publishControl({
          v: 1,
          kind: "transfer_file_failed",
          transferId: offer.transferId,
          fileId: file.fileId,
          code: "insufficient_storage",
        });
      }
      return false;
    }
    await mkdir(this.options.destinationDirectory, { recursive: true });
    await this.options.queue.acceptOffer(
      offer,
      new Map(
        offer.files.map((file) => [
          file.fileId,
          join(this.options.destinationDirectory, file.filename),
        ]),
      ),
    );
    return existingBatch !== undefined;
  }

  private async acceptReceiverOffset(
    transferId: string,
    fileId: string,
    confirmedOffset: number,
    maxChunkBytes?: number,
  ): Promise<void> {
    const snapshot = this.options.queue.snapshot();
    const batch = snapshot.batches.find(
      (candidate) => candidate.transferId === transferId,
    );
    const file = batch?.files.find((candidate) => candidate.fileId === fileId);
    if (!batch || !file || batch.direction !== "laptop_to_phone") {
      throw new Error("Receiver accepted an unknown laptop transfer.");
    }
    if (confirmedOffset < file.confirmedOffset || confirmedOffset > file.size) {
      throw new RangeError("Receiver offset is outside known progress.");
    }
    const negotiatedChunkBytes = maxChunkBytes === undefined
      ? undefined
      : negotiateTransferChunkBytes(
          maxChunkBytes,
          this.options.maxChunkBytes ?? legacyTransferChunkBytes,
        );
    if (
      confirmedOffset > file.confirmedOffset ||
      negotiatedChunkBytes !== undefined
    ) {
      await this.options.queue.confirmProgress(
        transferId,
        fileId,
        confirmedOffset,
        negotiatedChunkBytes,
      );
    }
  }
}

function mimeForPath(path: string): string {
  const extension = path.toLowerCase().match(/\.([a-z0-9]+)$/)?.[1];
  return ({
    txt: "text/plain",
    pdf: "application/pdf",
    json: "application/json",
    csv: "text/csv",
    png: "image/png",
    jpg: "image/jpeg",
    jpeg: "image/jpeg",
    gif: "image/gif",
    webp: "image/webp",
    mp3: "audio/mpeg",
    mp4: "video/mp4",
    zip: "application/zip",
  } as Record<string, string>)[extension ?? ""] ?? "application/octet-stream";
}

async function hashPath(path: string): Promise<string> {
  const hasher = new Bun.CryptoHasher("sha256");
  for await (const chunk of Bun.file(path).stream()) {
    hasher.update(chunk);
  }
  return hasher.digest("hex");
}

async function defaultAvailableBytes(path: string): Promise<number> {
  const info = await statfs(path);
  return info.bavail * info.bsize;
}
