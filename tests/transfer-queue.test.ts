import { describe, expect, test } from "bun:test";
import { link, mkdtemp, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  JsonTransferQueueStorage,
  TransferQueue,
  type EnqueueTransferFile,
} from "../src/transfer/transfer-queue";
import type { TransferOffer } from "../src/shared/wire";
import { partialPathFor } from "../src/transfer/transfer-paths";

const file = (
  filename: string,
  size = 10,
): EnqueueTransferFile => ({
  filename,
  mime: "application/octet-stream",
  size,
  lastModifiedMs: 1_753_689_500_000,
  sha256: filename[0]!.repeat(64),
  sourcePath: `/source/${filename}`,
});

describe("durable transfer queue", () => {
  test("persists FIFO batches and resumes confirmed progress after restart", async () => {
    const dir = await mkdtemp(join(tmpdir(), "vidyut-transfer-queue-"));
    const path = join(dir, "queue.json");
    let sequence = 0;
    const id = (prefix: string) => `${prefix}_${String(++sequence).padStart(16, "0")}`;
    const storage = new JsonTransferQueueStorage(path);
    const first = await TransferQueue.open({ storage, id });
    const batchA = await first.enqueue({
      direction: "laptop_to_phone",
      origin: "laptop",
      files: [file("alpha.bin")],
    });
    const batchB = await first.enqueue({
      direction: "laptop_to_phone",
      origin: "laptop",
      files: [file("beta.bin")],
    });

    const claim = await first.claimNext();
    expect(claim?.batch.transferId).toBe(batchA.transferId);
    await first.confirmProgress(batchA.transferId, batchA.files[0]!.fileId, 4);

    const restarted = await TransferQueue.open({ storage, id });
    const snapshot = restarted.snapshot();
    expect(snapshot.batches.map((batch) => batch.transferId)).toEqual([
      batchA.transferId,
      batchB.transferId,
    ]);
    expect(snapshot.batches[0]!.files[0]!.confirmedOffset).toBe(4);
    const resumed = await restarted.claimNext();
    expect(resumed?.batch.transferId).toBe(batchA.transferId);
    expect(resumed?.file.confirmedOffset).toBe(4);

    await rm(dir, { recursive: true, force: true });
  });

  test("enforces monotonic bounded progress and verified completion", async () => {
    const queue = await memoryQueue();
    const batch = await queue.enqueue({
      direction: "phone_to_laptop",
      origin: "phone",
      files: [file("alpha.bin")],
    });
    const fileRecord = batch.files[0]!;
    await queue.claimNext();
    await queue.confirmProgress(batch.transferId, fileRecord.fileId, 10);

    await expect(
      queue.confirmProgress(batch.transferId, fileRecord.fileId, 9),
    ).rejects.toThrow(/monotonic/);
    await expect(
      queue.complete(batch.transferId, fileRecord.fileId, "b".repeat(64)),
    ).rejects.toThrow(/hash/);
    await queue.complete(
      batch.transferId,
      fileRecord.fileId,
      fileRecord.sha256,
    );

    expect(queue.snapshot().batches[0]!.status).toBe("completed");
  });

  test("persists verification separately from an untouched active file", async () => {
    const queue = await memoryQueue();
    const batch = await queue.enqueue({
      direction: "phone_to_laptop",
      origin: "phone",
      files: [file("empty.bin", 0)],
    });
    const fileId = batch.files[0]!.fileId;
    await queue.claimNext();

    expect(queue.snapshot().batches[0]!.files[0]!.status).toBe("active");
    await queue.beginVerification(batch.transferId, fileId, 0);
    expect(queue.snapshot().batches[0]!.files[0]!.status).toBe("verifying");

    await queue.complete(batch.transferId, fileId, batch.files[0]!.sha256);
    expect(queue.snapshot().batches[0]!.files[0]!.status).toBe("completed");
  });

  test("recovers an untouched empty file without inventing verification", async () => {
    const dir = await mkdtemp(join(tmpdir(), "vidyut-empty-recovery-"));
    const path = join(dir, "queue.json");
    const storage = new JsonTransferQueueStorage(path);
    const queue = await TransferQueue.open({ storage });
    const batch = await queue.enqueue({
      direction: "phone_to_laptop",
      origin: "phone",
      files: [file("empty.bin", 0)],
    });
    await queue.claimNext();

    const restarted = await TransferQueue.open({ storage });
    const recovered = restarted.snapshot().batches[0]!.files[0]!;
    expect(recovered.status).toBe("queued");
    expect(recovered.errorCode).toBeUndefined();
    expect((await restarted.claimNext())!.file.fileId).toBe(
      batch.files[0]!.fileId,
    );
    await rm(dir, { recursive: true, force: true });
  });

  test("removes an abandoned partial after interrupted verification", async () => {
    const dir = await mkdtemp(join(tmpdir(), "vidyut-verify-recovery-"));
    const path = join(dir, "queue.json");
    const destination = join(dir, "report.bin");
    const storage = new JsonTransferQueueStorage(path);
    const queue = await TransferQueue.open({ storage });
    const batch = await queue.enqueue({
      direction: "phone_to_laptop",
      origin: "phone",
      files: [{ ...file("report.bin"), destinationPath: destination }],
    });
    const claimed = (await queue.claimNext())!;
    const partial = partialPathFor(destination, claimed.file.fileId);
    await writeFile(partial, new Uint8Array(10));
    await queue.beginVerification(
      batch.transferId,
      claimed.file.fileId,
      claimed.file.size,
    );

    const restarted = await TransferQueue.open({ storage });
    expect(restarted.snapshot().batches[0]!.files[0]!.status).toBe("failed");
    await expect(stat(partial)).rejects.toThrow();
    await rm(dir, { recursive: true, force: true });
  });

  test("recovers a verified file linked before queue completion", async () => {
    const dir = await mkdtemp(join(tmpdir(), "vidyut-finalize-recovery-"));
    const path = join(dir, "queue.json");
    const destination = join(dir, "report.bin");
    const finalized = join(dir, "report (1).bin");
    const storage = new JsonTransferQueueStorage(path);
    const queue = await TransferQueue.open({ storage });
    const batch = await queue.enqueue({
      direction: "phone_to_laptop",
      origin: "phone",
      files: [{ ...file("report.bin"), destinationPath: destination }],
    });
    const claimed = (await queue.claimNext())!;
    const partial = partialPathFor(destination, claimed.file.fileId);
    await writeFile(partial, new Uint8Array(10));
    await queue.beginVerification(
      batch.transferId,
      claimed.file.fileId,
      claimed.file.size,
    );
    await queue.beginFinalization(
      batch.transferId,
      claimed.file.fileId,
      finalized,
    );
    await link(partial, finalized);

    let persistedBeforePartialRemoval = false;
    const restarted = await TransferQueue.open({
      storage: {
        load: () => storage.load(),
        async save(snapshot) {
          if (snapshot.batches[0]!.files[0]!.status === "completed") {
            persistedBeforePartialRemoval = (await stat(partial)).isFile();
          }
          await storage.save(snapshot);
        },
      },
    });
    const recovered = restarted.snapshot().batches[0]!.files[0]!;
    expect(recovered.status).toBe("completed");
    expect(recovered.destinationPath).toBe(finalized);
    expect(persistedBeforePartialRemoval).toBe(true);
    await expect(stat(partial)).rejects.toThrow();
    expect((await stat(finalized)).size).toBe(10);
    await rm(dir, { recursive: true, force: true });
  });

  test("continues a batch after one file fails and retries only failures", async () => {
    const queue = await memoryQueue();
    const batch = await queue.enqueue({
      direction: "laptop_to_phone",
      origin: "laptop",
      files: [file("alpha.bin"), file("beta.bin")],
    });
    const first = (await queue.claimNext())!;
    await queue.fail(batch.transferId, first.file.fileId, "source_unavailable");
    const second = (await queue.claimNext())!;
    expect(second.file.filename).toBe("beta.bin");
    await queue.confirmProgress(batch.transferId, second.file.fileId, 10);
    await queue.complete(
      batch.transferId,
      second.file.fileId,
      second.file.sha256,
    );
    expect(queue.snapshot().batches[0]!.status).toBe(
      "completed_with_issues",
    );

    await queue.retry(batch.transferId);
    expect(queue.snapshot().batches[0]!.status).toBe("queued");
    expect((await queue.claimNext())!.file.filename).toBe("alpha.bin");
  });

  test("pauses, resumes and cancels without discarding confirmed progress", async () => {
    const queue = await memoryQueue();
    const batch = await queue.enqueue({
      direction: "phone_to_laptop",
      origin: "phone",
      files: [file("alpha.bin")],
    });
    const fileId = batch.files[0]!.fileId;
    await queue.claimNext();
    await queue.confirmProgress(batch.transferId, fileId, 4);
    await queue.pause(batch.transferId);
    expect(queue.snapshot().batches[0]!.status).toBe("paused");
    await queue.resume(batch.transferId);
    expect((await queue.claimNext())!.file.confirmedOffset).toBe(4);
    await queue.cancel(batch.transferId);
    expect(queue.snapshot().batches[0]!.status).toBe("cancelled");
  });

  test("expires unfinished work after seven days but retains history", async () => {
    let now = 1_753_689_600_000;
    const queue = await memoryQueue(() => now);
    await queue.enqueue({
      direction: "laptop_to_phone",
      origin: "laptop",
      files: [file("alpha.bin")],
    });

    now += 7 * 24 * 60 * 60 * 1000 + 1;
    await queue.expire();

    const batch = queue.snapshot().batches[0]!;
    expect(batch.status).toBe("expired");
    expect(batch.files[0]!.errorCode).toBe("transfer_expired");
  });

  test("accepts an idempotent remote offer with resolved destinations", async () => {
    const queue = await memoryQueue();
    const offer: TransferOffer = {
      transferId: "transfer_remote_1234",
      batchId: "batch_remote_123456",
      origin: "phone",
      direction: "phone_to_laptop",
      createdAtMs: 1_753_689_600_000,
      files: [
        {
          fileId: "file_remote_123456",
          filename: "report.pdf",
          mime: "application/pdf",
          size: 10,
          lastModifiedMs: 1_753_689_500_000,
          sha256: "a".repeat(64),
        },
        {
          fileId: "file_remote_654321",
          filename: "notes.txt",
          mime: "text/plain",
          size: 5,
          lastModifiedMs: 1_753_689_500_000,
          sha256: "b".repeat(64),
        },
      ],
    };
    const destinations = new Map([
      [offer.files[0]!.fileId, "/downloads/report.pdf"],
      [offer.files[1]!.fileId, "/downloads/notes.txt"],
    ]);

    const accepted = await queue.acceptOffer(offer, destinations);
    const duplicate = await queue.acceptOffer(
      { ...offer, files: [...offer.files].reverse() },
      destinations,
    );

    expect(accepted.files[0]!.destinationPath).toBe("/downloads/report.pdf");
    expect(duplicate).toEqual(accepted);
    expect(queue.snapshot().batches).toHaveLength(1);
  });
});

async function memoryQueue(now: () => number = Date.now) {
  let snapshot:
    | ReturnType<TransferQueue["snapshot"]>
    | undefined;
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
    now,
    id(prefix) {
      return `${prefix}_${String(++sequence).padStart(16, "0")}`;
    },
  });
}
