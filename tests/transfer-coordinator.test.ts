import { describe, expect, test } from "bun:test";
import { mkdtemp, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { sha256Hex } from "../src/shared/transfer-crypto";
import type { TransferControlMessage } from "../src/shared/wire";
import { TransferCoordinator } from "../src/transfer/transfer-coordinator";
import { TransferQueue } from "../src/transfer/transfer-queue";
import {
  ReceiverProgressSessions,
} from "../src/transfer/laptop-data-plane";
import { partialPathFor } from "../src/transfer/transfer-paths";

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
    expect(queue.snapshot().batches[0]!.sourceDeviceId).toBe("phone");
    await rm(dir, { recursive: true, force: true });
  });

  test("fails only the disconnected peer's active transfer", async () => {
    const dir = await mkdtemp(join(tmpdir(), "vidyut-coordinator-peers-"));
    const firstPath = join(dir, "first.bin");
    const secondPath = join(dir, "second.bin");
    await writeFile(firstPath, new Uint8Array([1]));
    await writeFile(secondPath, new Uint8Array([2]));
    const queue = await memoryQueue();
    const controls: TransferControlMessage[] = [];
    const coordinator = new TransferCoordinator({
      queue,
      destinationDirectory: join(dir, "downloads"),
      maxFileBytes: 1024,
      publishControl: (message) => controls.push(message),
    });

    const first = await coordinator.enqueueLaptopFiles([firstPath]);
    const second = await coordinator.enqueueLaptopFiles([secondPath]);
    await coordinator.handleControl(
      {
        v: 1,
        kind: "transfer_accept",
        transferId: first.transferId,
        fileId: first.files[0]!.fileId,
        confirmedOffset: 0,
      },
      "phone-a",
    );
    await queue.associateSourceDevice(second.transferId, "phone-b");

    await coordinator.handleDeviceDisconnected("phone-b");
    expect(queue.snapshot().batches[0]!.files[0]!.status).toBe("active");
    expect(controls).not.toContainEqual(
      expect.objectContaining({
        kind: "transfer_file_failed",
        transferId: first.transferId,
      }),
    );

    await coordinator.handleDeviceDisconnected("phone-a");
    expect(queue.snapshot().batches[0]!.files[0]!.status).toBe("failed");
    expect(queue.snapshot().batches[1]!.files[0]!.status).toBe("queued");
    await coordinator.handleDeviceConnected("phone-b");
    expect(queue.snapshot().batches[1]!.files[0]!.status).toBe("active");
    await rm(dir, { recursive: true, force: true });
  });

  test("republishes an unaccepted laptop offer after reconnect", async () => {
    const dir = await mkdtemp(join(tmpdir(), "vidyut-coordinator-reconnect-"));
    const path = join(dir, "report.pdf");
    await writeFile(path, new Uint8Array([1]));
    const queue = await memoryQueue();
    const controls: TransferControlMessage[] = [];
    const coordinator = new TransferCoordinator({
      queue,
      destinationDirectory: join(dir, "downloads"),
      maxFileBytes: 1024,
      publishControl: (message) => controls.push(message),
    });

    const offer = await coordinator.enqueueLaptopFiles([path]);
    controls.length = 0;
    await coordinator.handleDeviceConnected("phone");

    expect(controls).toEqual([{ v: 1, kind: "transfer_offer", offer }]);
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

  test("checkpoints before pause and removes the partial on cancellation", async () => {
    const dir = await mkdtemp(join(tmpdir(), "vidyut-coordinator-progress-"));
    const queue = await memoryQueue();
    const sessions = new ReceiverProgressSessions({ now: () => 100 });
    const coordinator = new TransferCoordinator({
      queue,
      destinationDirectory: dir,
      maxFileBytes: 1024,
      maxChunkBytes: 1024 * 1024,
      availableBytes: async () => 2048,
      publishControl: () => undefined,
      progressSessions: sessions,
    });
    const offer = {
      transferId: "transfer_pause_1234",
      batchId: "batch_pause_123456",
      origin: "phone",
      direction: "phone_to_laptop" as const,
      createdAtMs: 1_753_689_600_000,
      files: [{
        fileId: "file_pause_123456",
        filename: "report.bin",
        mime: "application/octet-stream",
        size: 6,
        lastModifiedMs: 1_753_689_500_000,
        sha256: "a".repeat(64),
      }],
    };
    await coordinator.handleControl(
      { v: 1, kind: "transfer_offer", offer },
      "phone",
    );
    const file = queue.snapshot().batches[0]!.files[0]!;
    const session = sessions.sessionFor(offer.transferId, file);
    const partialPath = partialPathFor(file.destinationPath!, file.fileId);
    await writeFile(partialPath, new Uint8Array([1, 2]));
    session.markAccepted(2);
    await coordinator.handleControl(
      {
        v: 1,
        kind: "transfer_pause",
        transferId: offer.transferId,
        fileId: file.fileId,
      },
      "phone",
    );

    expect(queue.snapshot().batches[0]!.files[0]!.confirmedOffset).toBe(2);
    expect(queue.snapshot().batches[0]!.files[0]!.status).toBe("paused");
    await expect(stat(partialPath)).resolves.toBeTruthy();

    await coordinator.handleControl(
      {
        v: 1,
        kind: "transfer_resume",
        transferId: offer.transferId,
        fileId: file.fileId,
      },
      "phone",
    );
    await coordinator.handleControl(
      {
        v: 1,
        kind: "transfer_cancel",
        transferId: offer.transferId,
        fileId: file.fileId,
      },
      "phone",
    );
    expect(queue.snapshot().batches[0]!.files[0]!.status).toBe("cancelled");
    await expect(stat(partialPath)).rejects.toThrow();
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

  test("reactivates a cancelled phone offer when the phone retries it", async () => {
    const dir = await mkdtemp(join(tmpdir(), "vidyut-coordinator-cancel-retry-"));
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
    const offer = {
      transferId: "transfer_cancel_retry_1234",
      batchId: "batch_cancel_retry_123456",
      origin: "phone",
      direction: "phone_to_laptop" as const,
      createdAtMs: 1_753_689_600_000,
      files: [{
        fileId: "file_cancel_retry_123456",
        filename: "report.pdf",
        mime: "application/pdf",
        size: 3,
        lastModifiedMs: 1_753_689_500_000,
        sha256: "a".repeat(64),
      }],
    };

    await coordinator.handleControl(
      { v: 1, kind: "transfer_offer", offer },
      "phone",
    );
    await coordinator.handleControl(
      {
        v: 1,
        kind: "transfer_cancel",
        transferId: offer.transferId,
        fileId: offer.files[0]!.fileId,
      },
      "phone",
    );
    expect(queue.snapshot().batches[0]!.status).toBe("cancelled");
    controls.length = 0;

    await coordinator.handleControl(
      { v: 1, kind: "transfer_offer", offer },
      "phone",
    );

    expect(controls).toEqual([{
      v: 1,
      kind: "transfer_accept",
      transferId: offer.transferId,
      fileId: offer.files[0]!.fileId,
      confirmedOffset: 0,
      maxChunkBytes: 1024 * 1024,
    }]);
    expect(queue.snapshot().batches[0]!.files[0]!.status).toBe("active");
    await rm(dir, { recursive: true, force: true });
  });

  test("reactivates a cancelled file in a batch with completed files", async () => {
    const dir = await mkdtemp(join(tmpdir(), "vidyut-coordinator-cancel-mixed-"));
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
    const offer = {
      transferId: "transfer_cancel_mixed_1234",
      batchId: "batch_cancel_mixed_123456",
      origin: "phone",
      direction: "phone_to_laptop" as const,
      createdAtMs: 1_753_689_600_000,
      files: [
        {
          fileId: "file_cancel_mixed_done",
          filename: "done.pdf",
          mime: "application/pdf",
          size: 1,
          lastModifiedMs: 1_753_689_500_000,
          sha256: "d".repeat(64),
        },
        {
          fileId: "file_cancel_mixed_pending",
          filename: "pending.pdf",
          mime: "application/pdf",
          size: 3,
          lastModifiedMs: 1_753_689_400_000,
          sha256: "e".repeat(64),
        },
      ],
    };

    await coordinator.handleControl(
      { v: 1, kind: "transfer_offer", offer },
      "phone",
    );
    await coordinator.handleControl(
      {
        v: 1,
        kind: "transfer_progress",
        transferId: offer.transferId,
        fileId: offer.files[0]!.fileId,
        confirmedOffset: offer.files[0]!.size,
      },
      "phone",
    );
    await coordinator.handleControl(
      {
        v: 1,
        kind: "transfer_file_complete",
        transferId: offer.transferId,
        fileId: offer.files[0]!.fileId,
        sha256: offer.files[0]!.sha256,
      },
      "phone",
    );
    await coordinator.handleControl(
      {
        v: 1,
        kind: "transfer_cancel",
        transferId: offer.transferId,
        fileId: offer.files[1]!.fileId,
      },
      "phone",
    );
    expect(queue.snapshot().batches[0]!.status).toBe("completed_with_issues");
    controls.length = 0;

    await coordinator.handleControl(
      { v: 1, kind: "transfer_offer", offer },
      "phone",
    );

    expect(queue.snapshot().batches[0]!.files[0]!.status).toBe("completed");
    expect(queue.snapshot().batches[0]!.files[1]!.status).toBe("active");
    expect(controls).toContainEqual({
      v: 1,
      kind: "transfer_accept",
      transferId: offer.transferId,
      fileId: offer.files[1]!.fileId,
      confirmedOffset: 0,
      maxChunkBytes: 1024 * 1024,
    });
    await rm(dir, { recursive: true, force: true });
  });

  test("keeps a cancelled file terminal when a retry offer runs out of space", async () => {
    const dir = await mkdtemp(join(tmpdir(), "vidyut-coordinator-cancel-storage-"));
    const queue = await memoryQueue();
    const controls: TransferControlMessage[] = [];
    let availableBytes = 3;
    const coordinator = new TransferCoordinator({
      queue,
      destinationDirectory: dir,
      maxFileBytes: 1024,
      maxChunkBytes: 1024 * 1024,
      availableBytes: async () => availableBytes,
      publishControl: (message) => controls.push(message),
    });
    const offer = {
      transferId: "transfer_cancel_storage_1234",
      batchId: "batch_cancel_storage_123456",
      origin: "phone",
      direction: "phone_to_laptop" as const,
      createdAtMs: 1_753_689_600_000,
      files: [{
        fileId: "file_cancel_storage_123456",
        filename: "report.pdf",
        mime: "application/pdf",
        size: 3,
        lastModifiedMs: 1_753_689_500_000,
        sha256: "a".repeat(64),
      }],
    };

    await coordinator.handleControl(
      { v: 1, kind: "transfer_offer", offer },
      "phone",
    );
    await coordinator.handleControl(
      {
        v: 1,
        kind: "transfer_cancel",
        transferId: offer.transferId,
        fileId: offer.files[0]!.fileId,
      },
      "phone",
    );
    controls.length = 0;
    availableBytes = 0;

    await coordinator.handleControl(
      { v: 1, kind: "transfer_offer", offer },
      "phone",
    );

    expect(controls).toEqual([]);
    expect(queue.snapshot().batches[0]!.status).toBe("cancelled");
    expect(queue.snapshot().batches[0]!.files[0]!.status).toBe("cancelled");
    await rm(dir, { recursive: true, force: true });
  });

  test("checks only remaining bytes when a phone retries an offer", async () => {
    const dir = await mkdtemp(join(tmpdir(), "vidyut-coordinator-storage-"));
    const queue = await memoryQueue();
    const controls: TransferControlMessage[] = [];
    let availableBytes = 3;
    const coordinator = new TransferCoordinator({
      queue,
      destinationDirectory: dir,
      maxFileBytes: 1024,
      maxChunkBytes: 1024 * 1024,
      availableBytes: async () => availableBytes,
      publishControl: (message) => controls.push(message),
    });
    const bytes = new Uint8Array([1, 2, 3]);
    const offer = {
      transferId: "transfer_storage_1234",
      batchId: "batch_storage_123456",
      origin: "phone",
      direction: "phone_to_laptop" as const,
      createdAtMs: 1_753_689_600_000,
      files: [
        {
          fileId: "file_storage_123456",
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
    availableBytes = 0;

    await coordinator.handleControl(
      { v: 1, kind: "transfer_offer", offer },
      "phone",
    );

    expect(controls).toEqual([
      {
        v: 1,
        kind: "transfer_file_failed",
        transferId: offer.transferId,
        fileId: offer.files[0]!.fileId,
        code: "insufficient_storage",
      },
    ]);
    expect(queue.snapshot().batches[0]!.files[0]!.status).toBe("failed");
    await rm(dir, { recursive: true, force: true });
  });

  test("recomputes remaining bytes after an asynchronous storage check", async () => {
    const dir = await mkdtemp(join(tmpdir(), "vidyut-coordinator-storage-race-"));
    const queue = await memoryQueue();
    const controls: TransferControlMessage[] = [];
    const bytes = new Uint8Array([1, 2, 3]);
    const offer = {
      transferId: "transfer_storage_race_1234",
      batchId: "batch_storage_race_123456",
      origin: "phone",
      direction: "phone_to_laptop" as const,
      createdAtMs: 1_753_689_600_000,
      files: [{
        fileId: "file_storage_race_123456",
        filename: "report.pdf",
        mime: "application/pdf",
        size: bytes.length,
        lastModifiedMs: 1_753_689_500_000,
        sha256: await sha256Hex(bytes),
      }],
    };
    let storageChecks = 0;
    const coordinator = new TransferCoordinator({
      queue,
      destinationDirectory: dir,
      maxFileBytes: 1024,
      maxChunkBytes: 1024 * 1024,
      availableBytes: async () => {
        storageChecks += 1;
        if (storageChecks === 2) {
          await queue.confirmProgress(
            offer.transferId,
            offer.files[0]!.fileId,
            2,
          );
        }
        return storageChecks === 1 ? 3 : 1;
      },
      publishControl: (message) => controls.push(message),
    });

    await coordinator.handleControl(
      { v: 1, kind: "transfer_offer", offer },
      "phone",
    );
    controls.length = 0;

    await coordinator.handleControl(
      { v: 1, kind: "transfer_offer", offer },
      "phone",
    );

    expect(controls).toEqual([{
      v: 1,
      kind: "transfer_accept",
      transferId: offer.transferId,
      fileId: offer.files[0]!.fileId,
      confirmedOffset: 2,
      maxChunkBytes: 1024 * 1024,
    }]);
    expect(queue.snapshot().batches[0]!.files[0]!.status).toBe("active");
    await rm(dir, { recursive: true, force: true });
  });

  test("replays a persisted offer despite a lower current size limit", async () => {
    const dir = await mkdtemp(join(tmpdir(), "vidyut-coordinator-limit-"));
    const queue = await memoryQueue();
    const controls: TransferControlMessage[] = [];
    const offer = {
      transferId: "transfer_limit_1234",
      batchId: "batch_limit_123456",
      origin: "phone",
      direction: "phone_to_laptop" as const,
      createdAtMs: 1_753_689_600_000,
      files: [
        {
          fileId: "file_limit_123456",
          filename: "report.pdf",
          mime: "application/pdf",
          size: 3,
          lastModifiedMs: 1_753_689_500_000,
          sha256: await sha256Hex(new Uint8Array([1, 2, 3])),
        },
      ],
    };
    const createCoordinator = (maxFileBytes: number) =>
      new TransferCoordinator({
        queue,
        destinationDirectory: dir,
        maxFileBytes,
        maxChunkBytes: 1024 * 1024,
        availableBytes: async () => 2048,
        publishControl: (message) => controls.push(message),
      });

    await createCoordinator(1024).handleControl(
      { v: 1, kind: "transfer_offer", offer },
      "phone",
    );
    controls.length = 0;

    await createCoordinator(1).handleControl(
      { v: 1, kind: "transfer_offer", offer },
      "phone",
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

  test("re-advertises a file completed before its response was interrupted", async () => {
    const dir = await mkdtemp(join(tmpdir(), "vidyut-coordinator-complete-"));
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
    const firstBytes = new Uint8Array([1, 2, 3]);
    const secondBytes = new Uint8Array([4, 5]);
    const offer = {
      transferId: "transfer_completed_1234",
      batchId: "batch_completed_123456",
      origin: "phone",
      direction: "phone_to_laptop" as const,
      createdAtMs: 1_753_689_600_000,
      files: [
        {
          fileId: "file_completed_123456",
          filename: "first.bin",
          mime: "application/octet-stream",
          size: firstBytes.length,
          lastModifiedMs: 1_753_689_500_000,
          sha256: await sha256Hex(firstBytes),
        },
        {
          fileId: "file_queued_12345678",
          filename: "second.bin",
          mime: "application/octet-stream",
          size: secondBytes.length,
          lastModifiedMs: 1_753_689_500_000,
          sha256: await sha256Hex(secondBytes),
        },
      ],
    };

    await coordinator.handleControl(
      { v: 1, kind: "transfer_offer", offer },
      "phone",
    );
    await coordinator.handleControl(
      {
        v: 1,
        kind: "transfer_progress",
        transferId: offer.transferId,
        fileId: offer.files[0]!.fileId,
        confirmedOffset: firstBytes.length,
      },
      "phone",
    );
    await coordinator.handleControl(
      {
        v: 1,
        kind: "transfer_file_complete",
        transferId: offer.transferId,
        fileId: offer.files[0]!.fileId,
        sha256: offer.files[0]!.sha256,
      },
      "phone",
    );
    controls.length = 0;

    await coordinator.handleControl(
      { v: 1, kind: "transfer_offer", offer },
      "phone",
    );

    expect(controls).toEqual([
      {
        v: 1,
        kind: "transfer_file_complete",
        transferId: offer.transferId,
        fileId: offer.files[0]!.fileId,
        sha256: offer.files[0]!.sha256,
      },
      {
        v: 1,
        kind: "transfer_accept",
        transferId: offer.transferId,
        fileId: offer.files[1]!.fileId,
        confirmedOffset: 0,
        maxChunkBytes: 1024 * 1024,
      },
    ]);
    await rm(dir, { recursive: true, force: true });
  });

  test("waits for terminal verification before re-advertising full progress", async () => {
    const dir = await mkdtemp(join(tmpdir(), "vidyut-coordinator-verify-"));
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
      transferId: "transfer_verifying_1234",
      batchId: "batch_verifying_123456",
      origin: "phone",
      direction: "phone_to_laptop" as const,
      createdAtMs: 1_753_689_600_000,
      files: [
        {
          fileId: "file_verifying_123456",
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
    await queue.beginVerification(
      offer.transferId,
      offer.files[0]!.fileId,
      bytes.length,
    );
    controls.length = 0;

    await coordinator.handleControl(
      { v: 1, kind: "transfer_offer", offer },
      "phone",
    );
    expect(controls).toEqual([]);

    await queue.complete(
      offer.transferId,
      offer.files[0]!.fileId,
      offer.files[0]!.sha256,
    );
    await coordinator.handleControl(
      { v: 1, kind: "transfer_offer", offer },
      "phone",
    );
    expect(controls).toEqual([
      {
        v: 1,
        kind: "transfer_file_complete",
        transferId: offer.transferId,
        fileId: offer.files[0]!.fileId,
        sha256: offer.files[0]!.sha256,
      },
    ]);
    await rm(dir, { recursive: true, force: true });
  });

  test("waits for terminal verification before re-advertising an empty file", async () => {
    const dir = await mkdtemp(join(tmpdir(), "vidyut-coordinator-empty-"));
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
    const offer = {
      transferId: "transfer_empty_1234",
      batchId: "batch_empty_123456",
      origin: "phone",
      direction: "phone_to_laptop" as const,
      createdAtMs: 1_753_689_600_000,
      files: [
        {
          fileId: "file_empty_123456",
          filename: "empty.bin",
          mime: "application/octet-stream",
          size: 0,
          lastModifiedMs: 1_753_689_500_000,
          sha256: await sha256Hex(new Uint8Array()),
        },
      ],
    };

    await coordinator.handleControl(
      { v: 1, kind: "transfer_offer", offer },
      "phone",
    );
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
        confirmedOffset: 0,
        maxChunkBytes: 1024 * 1024,
      },
    ]);

    await queue.beginVerification(
      offer.transferId,
      offer.files[0]!.fileId,
      0,
    );
    controls.length = 0;
    await coordinator.handleControl(
      { v: 1, kind: "transfer_offer", offer },
      "phone",
    );
    expect(controls).toEqual([]);

    await queue.complete(
      offer.transferId,
      offer.files[0]!.fileId,
      offer.files[0]!.sha256,
    );
    await coordinator.handleControl(
      { v: 1, kind: "transfer_offer", offer },
      "phone",
    );
    expect(controls).toEqual([
      {
        v: 1,
        kind: "transfer_file_complete",
        transferId: offer.transferId,
        fileId: offer.files[0]!.fileId,
        sha256: offer.files[0]!.sha256,
      },
    ]);
    await rm(dir, { recursive: true, force: true });
  });

  test("re-advertises a persisted file failure when a phone retries", async () => {
    const dir = await mkdtemp(join(tmpdir(), "vidyut-coordinator-failed-"));
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
      transferId: "transfer_failed_1234",
      batchId: "batch_failed_123456",
      origin: "phone",
      direction: "phone_to_laptop" as const,
      createdAtMs: 1_753_689_600_000,
      files: [
        {
          fileId: "file_failed_123456",
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
    await queue.fail(
      offer.transferId,
      offer.files[0]!.fileId,
      "hash_mismatch",
    );
    controls.length = 0;

    await coordinator.handleControl(
      { v: 1, kind: "transfer_offer", offer },
      "phone",
    );

    expect(controls).toEqual([
      {
        v: 1,
        kind: "transfer_file_failed",
        transferId: offer.transferId,
        fileId: offer.files[0]!.fileId,
        code: "hash_mismatch",
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
