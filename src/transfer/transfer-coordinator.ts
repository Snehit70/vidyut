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
        await this.acceptPhoneOffer(message.offer);
        if (!await this.activateNext()) {
          this.republishActivePhoneFile(message.offer.transferId);
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
      this.options.publishControl({
        v: 1,
        kind: "transfer_accept",
        transferId: claim.batch.transferId,
        fileId: claim.file.fileId,
        confirmedOffset: claim.file.confirmedOffset,
        ...(this.options.maxChunkBytes === undefined
          ? {}
          : { maxChunkBytes: this.options.maxChunkBytes }),
      });
    } else {
      this.options.publishControl({
        v: 1,
        kind: "transfer_offer",
        offer: this.options.queue.offer(claim.batch.transferId),
      });
    }
    return claim;
  }

  private republishActivePhoneFile(transferId: string): boolean {
    const batch = this.options.queue.snapshot().batches.find(
      (candidate) => candidate.transferId === transferId,
    );
    const file = batch?.files.find((candidate) => candidate.status === "active");
    if (!batch || !file || batch.direction !== "phone_to_laptop") return false;
    this.options.publishControl({
      v: 1,
      kind: "transfer_accept",
      transferId: batch.transferId,
      fileId: file.fileId,
      confirmedOffset: file.confirmedOffset,
      ...(this.options.maxChunkBytes === undefined
        ? {}
        : { maxChunkBytes: this.options.maxChunkBytes }),
    });
    return true;
  }

  private async acceptPhoneOffer(offer: TransferOffer): Promise<void> {
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
      return;
    }
    const totalBytes = offer.files.reduce((total, file) => total + file.size, 0);
    const availableBytes = await (
      this.options.availableBytes ?? defaultAvailableBytes
    )(this.options.destinationDirectory);
    if (totalBytes > availableBytes) {
      for (const file of offer.files) {
        this.options.publishControl({
          v: 1,
          kind: "transfer_file_failed",
          transferId: offer.transferId,
          fileId: file.fileId,
          code: "insufficient_storage",
        });
      }
      return;
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
