import { describe, expect, test } from "bun:test";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { sha256Hex } from "../src/shared/transfer-crypto";
import type { TransferControlMessage } from "../src/shared/wire";
import { TransferCoordinator } from "../src/transfer/transfer-coordinator";
import { TransferQueue } from "../src/transfer/transfer-queue";

describe("transfer coordinator", () => {
  test("offers a selected laptop batch and waits for receiver progress", async () => {
    const dir = await mkdtemp(join(tmpdir(), "vidyut-coordinator-send-"));
    const path = join(dir, "report.pdf");
    await writeFile(path, new Uint8Array([1, 2, 3]));
    const queue = await memoryQueue();
    const controls: TransferControlMessage[] = [];
    const coordinator = new TransferCoordinator({
      queue,
      destinationDirectory: join(dir, "downloads"),
      maxFileBytes: 1024,
      maxChunkBytes: 1024 * 1024,
      publishControl: (message) => controls.push(message),
    });

    const offer = await coordinator.enqueueLaptopFiles([path]);

    expect(offer.direction).toBe("laptop_to_phone");
    expect(controls).toEqual([{ v: 1, kind: "transfer_offer", offer }]);
    expect(queue.snapshot().batches[0]!.files[0]!.status).toBe("active");
    await coordinator.handleControl(
      {
        v: 1,
        kind: "transfer_accept",
        transferId: offer.transferId,
        fileId: offer.files[0]!.fileId,
        confirmedOffset: 0,
        maxChunkBytes: 2 * 1024 * 1024,
      },
      "phone",
    );
    expect(queue.snapshot().batches[0]!.files[0]!.maxChunkBytes).toBe(
      1024 * 1024,
    );
    await rm(dir, { recursive: true, force: true });
  });

  test("accepts a phone offer after size and storage checks", async () => {
    const dir = await mkdtemp(join(tmpdir(), "vidyut-coordinator-receive-"));
    const queue = await memoryQueue();
    const controls: TransferControlMessage[] = [];
    const coordinator = new TransferCoordinator({
      queue,
      destinationDirectory: dir,
      maxFileBytes: 1024,
      maxChunkBytes: 1024 * 1024,
      availableBytes: async () => 2048,
      publishControl: (message) => controls.push(message),
    });
    const bytes = new Uint8Array([1, 2, 3]);
    const offer = {
      transferId: "transfer_remote_1234",
      batchId: "batch_remote_123456",
      origin: "phone",
      direction: "phone_to_laptop" as const,
      createdAtMs: 1_753_689_600_000,
      files: [
        {
          fileId: "file_remote_123456",
          filename: "report.pdf",
          mime: "application/pdf",
          size: bytes.length,
          lastModifiedMs: 1_753_689_500_000,
          sha256: await sha256Hex(bytes),
        },
      ],
    };

    await coordinator.handleControl(
      { v: 1, kind: "transfer_offer", offer },
      "phone",
    );

    expect(queue.snapshot().batches[0]!.files[0]!.destinationPath).toBe(
      join(dir, "report.pdf"),
    );
    expect(controls).toEqual([
      {
        v: 1,
        kind: "transfer_accept",
        transferId: offer.transferId,
        fileId: offer.files[0]!.fileId,
        confirmedOffset: 0,
        maxChunkBytes: 1024 * 1024,
      },
    ]);
    await rm(dir, { recursive: true, force: true });
  });

  test("re-advertises persisted progress when a phone retries an active offer", async () => {
    const dir = await mkdtemp(join(tmpdir(), "vidyut-coordinator-resume-"));
    const queue = await memoryQueue();
    const controls: TransferControlMessage[] = [];
    const coordinator = new TransferCoordinator({
      queue,
      destinationDirectory: dir,
      maxFileBytes: 1024,
      maxChunkBytes: 1024 * 1024,
      availableBytes: async () => 2048,
      publishControl: (message) => controls.push(message),
    });
    const bytes = new Uint8Array([1, 2, 3]);
    const offer = {
      transferId: "transfer_retry_1234",
      batchId: "batch_retry_123456",
      origin: "phone",
      direction: "phone_to_laptop" as const,
      createdAtMs: 1_753_689_600_000,
      files: [
        {
          fileId: "file_retry_123456",
          filename: "report.pdf",
          mime: "application/pdf",
          size: bytes.length,
          lastModifiedMs: 1_753_689_500_000,
          sha256: await sha256Hex(bytes),
        },
      ],
    };

    await coordinator.handleControl(
      { v: 1, kind: "transfer_offer", offer },
      "phone",
    );
    await queue.confirmProgress(offer.transferId, offer.files[0]!.fileId, 2);
    controls.length = 0;

    await coordinator.handleControl(
      { v: 1, kind: "transfer_offer", offer },
      "phone",
    );

    expect(controls).toEqual([
      {
        v: 1,
        kind: "transfer_accept",
        transferId: offer.transferId,
        fileId: offer.files[0]!.fileId,
        confirmedOffset: 2,
        maxChunkBytes: 1024 * 1024,
      },
    ]);
    await rm(dir, { recursive: true, force: true });
  });

  test("rejects over-limit offers without persisting them", async () => {
    const queue = await memoryQueue();
    const controls: TransferControlMessage[] = [];
    const coordinator = new TransferCoordinator({
      queue,
      destinationDirectory: "/unused",
      maxFileBytes: 2,
      availableBytes: async () => 2048,
      publishControl: (message) => controls.push(message),
    });
    const offer = {
      transferId: "transfer_remote_5678",
      batchId: "batch_remote_567890",
      origin: "phone",
      direction: "phone_to_laptop" as const,
      createdAtMs: 1_753_689_600_000,
      files: [
        {
          fileId: "file_remote_567890",
          filename: "large.bin",
          mime: "application/octet-stream",
          size: 3,
          lastModifiedMs: 0,
          sha256: "a".repeat(64),
        },
      ],
    };

    await coordinator.handleControl(
      { v: 1, kind: "transfer_offer", offer },
      "phone",
    );

    expect(queue.snapshot().batches).toHaveLength(0);
    expect(controls).toMatchObject([
      { kind: "transfer_file_failed", code: "file_too_large" },
    ]);
  });
});

async function memoryQueue() {
  let snapshot: ReturnType<TransferQueue["snapshot"]> | undefined;
  let sequence = 0;
  return TransferQueue.open({
    storage: {
      async load() {
        return snapshot;
      },
      async save(value) {
        snapshot = structuredClone(value);
      },
    },
    id(prefix) {
      return `${prefix}_${String(++sequence).padStart(16, "0")}`;
    },
  });
}
