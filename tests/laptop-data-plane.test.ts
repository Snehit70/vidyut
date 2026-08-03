import { describe, expect, test } from "bun:test";
import { chmod, mkdtemp, rm, stat, unlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  decryptTransferChunk,
  encryptTransferChunk,
  sha256Hex,
} from "../src/shared/transfer-crypto";
import { createTransferHttpAuth } from "../src/shared/transfer-http-auth";
import { LaptopTransferDataPlane } from "../src/transfer/laptop-data-plane";
import {
  JsonTransferQueueStorage,
  TransferQueue,
} from "../src/transfer/transfer-queue";

const secret = "pairing-secret-for-laptop-data-plane";

describe("laptop transfer data plane", () => {
  test("serves encrypted chunks from the last confirmed offset", async () => {
    const fixture = await createFixture(new Uint8Array([1, 2, 3, 4, 5, 6]));
    const { queue, batch } = fixture;
    const file = batch.files[0]!;
    await queue.claimNext();
    const plane = new LaptopTransferDataPlane(secret, queue, 4);

    const first = await getChunk(plane, batch.transferId, file.fileId, 0);
    expect(first.response.status).toBe(200);
    expect(first.response.headers.get("x-vidyut-eof")).toBe("false");
    expect(await decryptResponse(first.response, batch.transferId, file.fileId))
      .toEqual(new Uint8Array([1, 2, 3, 4]));

    const ahead = await getChunk(plane, batch.transferId, file.fileId, 4);
    expect(ahead.response.status).toBe(409);
    await expect(ahead.response.json()).resolves.toEqual({
      code: "offset_not_confirmed",
      confirmedOffset: 0,
    });

    await queue.confirmProgress(batch.transferId, file.fileId, 4);
    const resumed = await getChunk(plane, batch.transferId, file.fileId, 4);
    expect(resumed.response.headers.get("x-vidyut-eof")).toBe("true");
    expect(
      await decryptResponse(resumed.response, batch.transferId, file.fileId),
    ).toEqual(new Uint8Array([5, 6]));

    await fixture.cleanup();
  });

  test("supports authenticated zero-byte files", async () => {
    const fixture = await createFixture(new Uint8Array(0));
    const file = fixture.batch.files[0]!;
    await fixture.queue.claimNext();
    const plane = new LaptopTransferDataPlane(secret, fixture.queue, 4);

    const chunk = await getChunk(
      plane,
      fixture.batch.transferId,
      file.fileId,
      0,
    );

    expect(chunk.response.status).toBe(200);
    expect(chunk.response.headers.get("x-vidyut-plaintext-bytes")).toBe("0");
    expect(chunk.response.headers.get("x-vidyut-eof")).toBe("true");
    expect(
      await decryptResponse(
        chunk.response,
        fixture.batch.transferId,
        file.fileId,
      ),
    ).toEqual(new Uint8Array(0));
    await fixture.cleanup();
  });

  test("serves the receiver-negotiated chunk size", async () => {
    const fixture = await createFixture(
      new Uint8Array([1, 2, 3, 4, 5, 6]),
    );
    const file = fixture.batch.files[0]!;
    await fixture.queue.claimNext();
    await fixture.queue.confirmProgress(
      fixture.batch.transferId,
      file.fileId,
      0,
      2,
    );
    const plane = new LaptopTransferDataPlane(secret, fixture.queue, 4);

    const chunk = await getChunk(
      plane,
      fixture.batch.transferId,
      file.fileId,
      0,
    );

    expect(
      await decryptResponse(
        chunk.response,
        fixture.batch.transferId,
        file.fileId,
      ),
    ).toEqual(new Uint8Array([1, 2]));
    await fixture.cleanup();
  });

  test("rejects a source that changed after enqueue", async () => {
    const fixture = await createFixture(new Uint8Array([1, 2, 3]));
    const file = fixture.batch.files[0]!;
    await fixture.queue.claimNext();
    await writeFile(fixture.path, new Uint8Array([9, 9, 9, 9]));
    const plane = new LaptopTransferDataPlane(secret, fixture.queue, 4);

    const chunk = await getChunk(
      plane,
      fixture.batch.transferId,
      file.fileId,
      0,
    );

    expect(chunk.response.status).toBe(409);
    await expect(chunk.response.json()).resolves.toEqual({
      code: "source_changed",
    });
    await fixture.cleanup();
  });

  test("receives, verifies and atomically finalizes phone chunks", async () => {
    const dir = await mkdtemp(join(tmpdir(), "vidyut-laptop-destination-"));
    const destination = join(dir, "report.bin");
    const bytes = new Uint8Array([1, 2, 3, 4, 5, 6]);
    const queue = await emptyQueue();
    const offer = {
      transferId: "transfer_remote_1234",
      batchId: "batch_remote_123456",
      origin: "phone",
      direction: "phone_to_laptop" as const,
      createdAtMs: 1_753_689_600_000,
      files: [
        {
          fileId: "file_remote_123456",
          filename: "report.bin",
          mime: "application/octet-stream",
          size: bytes.byteLength,
          lastModifiedMs: 1_753_689_500_000,
          sha256: await sha256Hex(bytes),
        },
      ],
    };
    await queue.acceptOffer(
      offer,
      new Map([[offer.files[0]!.fileId, destination]]),
    );
    await queue.claimNext();
    const controls: unknown[] = [];
    const plane = new LaptopTransferDataPlane(
      secret,
      queue,
      4,
      (message) => controls.push(message),
    );

    const first = await putChunk(
      plane,
      offer.transferId,
      offer.files[0]!.fileId,
      0,
      bytes.slice(0, 4),
    );
    expect(first.status).toBe(200);
    await expect(first.json()).resolves.toEqual({
      confirmedOffset: 4,
      complete: false,
    });

    const second = await putChunk(
      plane,
      offer.transferId,
      offer.files[0]!.fileId,
      4,
      bytes.slice(4),
    );
    expect(second.status).toBe(200);
    await expect(second.json()).resolves.toEqual({
      confirmedOffset: 6,
      complete: true,
    });
    expect(new Uint8Array(await Bun.file(destination).arrayBuffer())).toEqual(
      bytes,
    );
    expect(queue.snapshot().batches[0]!.status).toBe("completed");
    expect(controls).toMatchObject([
      { kind: "transfer_progress", confirmedOffset: 6 },
      { kind: "transfer_file_complete" },
    ]);
    await rm(dir, { recursive: true, force: true });
  });

  test("coalesces queue checkpoints and routine progress publication", async () => {
    const dir = await mkdtemp(join(tmpdir(), "vidyut-laptop-coalesce-"));
    const destination = join(dir, "report.bin");
    const bytes = new Uint8Array([1, 2, 3, 4, 5, 6]);
    let persisted: ReturnType<TransferQueue["snapshot"]> | undefined;
    const persistedOffsets: number[] = [];
    const queue = await TransferQueue.open({
      storage: {
        async load() {
          return persisted;
        },
        async save(value) {
          persisted = structuredClone(value);
          persistedOffsets.push(
            value.batches[0]?.files[0]?.confirmedOffset ?? -1,
          );
        },
      },
      id: (() => {
        let sequence = 0;
        return (prefix: string) => `${prefix}_coalesce_${++sequence}`;
      })(),
    });
    const offer = {
      transferId: "transfer_coalesce_1234",
      batchId: "batch_coalesce_123456",
      origin: "phone",
      direction: "phone_to_laptop" as const,
      createdAtMs: 1_753_689_600_000,
      files: [{
        fileId: "file_coalesce_123456",
        filename: "report.bin",
        mime: "application/octet-stream",
        size: bytes.length,
        lastModifiedMs: 1_753_689_500_000,
        sha256: await sha256Hex(bytes),
      }],
    };
    await queue.acceptOffer(
      offer,
      new Map([[offer.files[0]!.fileId, destination]]),
    );
    await queue.claimNext();
    const controls: unknown[] = [];
    let now = 0;
    const plane = new LaptopTransferDataPlane(
      secret,
      queue,
      2,
      (message) => controls.push(message),
      undefined,
      undefined,
      {
        now: () => now,
        checkpointBytes: 4,
        checkpointIntervalMs: 1_000,
        publishIntervalMs: 1_000,
      },
    );

    const first = await putChunk(
      plane,
      offer.transferId,
      offer.files[0]!.fileId,
      0,
      bytes.slice(0, 2),
    );
    expect(first.status).toBe(200);
    expect(await first.json()).toEqual({
      confirmedOffset: 2,
      complete: false,
    });
    expect(persisted!.batches[0]!.files[0]!.confirmedOffset).toBe(0);
    expect(controls).toEqual([]);

    now = 100;
    const second = await putChunk(
      plane,
      offer.transferId,
      offer.files[0]!.fileId,
      2,
      bytes.slice(2, 4),
    );
    expect(second.status).toBe(200);
    expect(await second.json()).toEqual({
      confirmedOffset: 4,
      complete: false,
    });
    expect(persisted!.batches[0]!.files[0]!.confirmedOffset).toBe(4);
    expect(controls).toMatchObject([
      { kind: "transfer_progress", confirmedOffset: 4 },
    ]);

    now = 200;
    const final = await putChunk(
      plane,
      offer.transferId,
      offer.files[0]!.fileId,
      4,
      bytes.slice(4),
    );
    expect(final.status).toBe(200);
    expect(await final.json()).toEqual({
      confirmedOffset: 6,
      complete: true,
    });
    expect(controls).toMatchObject([
      { kind: "transfer_progress", confirmedOffset: 4 },
      { kind: "transfer_progress", confirmedOffset: 6 },
      { kind: "transfer_file_complete" },
    ]);
    expect(persistedOffsets).not.toContain(2);
    expect(persistedOffsets).toContain(4);
    expect(persistedOffsets).toContain(6);
    expect(queue.snapshot().batches[0]!.files[0]!.status).toBe("completed");
    await rm(dir, { recursive: true, force: true });
  });

  test("serializes same-file PUTs and rejects the stale request", async () => {
    const dir = await mkdtemp(join(tmpdir(), "vidyut-laptop-serialize-"));
    const destination = join(dir, "report.bin");
    const bytes = new Uint8Array([1, 2, 3, 4]);
    const queue = await emptyQueue();
    const offer = {
      transferId: "transfer_serialize_1234",
      batchId: "batch_serialize_123456",
      origin: "phone",
      direction: "phone_to_laptop" as const,
      createdAtMs: 1_753_689_600_000,
      files: [{
        fileId: "file_serialize_123456",
        filename: "report.bin",
        mime: "application/octet-stream",
        size: bytes.length,
        lastModifiedMs: 1_753_689_500_000,
        sha256: await sha256Hex(bytes),
      }],
    };
    await queue.acceptOffer(
      offer,
      new Map([[offer.files[0]!.fileId, destination]]),
    );
    await queue.claimNext();
    const plane = new LaptopTransferDataPlane(secret, queue, 2, undefined, undefined, undefined, {
      checkpointBytes: 4,
      checkpointIntervalMs: 1_000,
      publishIntervalMs: 1_000,
    });

    const [first, duplicate] = await Promise.all([
      putChunk(
        plane,
        offer.transferId,
        offer.files[0]!.fileId,
        0,
        bytes.slice(0, 2),
      ),
      putChunk(
        plane,
        offer.transferId,
        offer.files[0]!.fileId,
        0,
        bytes.slice(0, 2),
      ),
    ]);
    const statuses = [first.status, duplicate.status].sort();
    expect(statuses).toEqual([200, 409]);
    const stale = first.status === 409 ? first : duplicate;
    await expect(stale.json()).resolves.toEqual({
      code: "offset_not_confirmed",
      confirmedOffset: 2,
    });
    await rm(dir, { recursive: true, force: true });
  });

  test("uses time checkpoints independently from routine publication", async () => {
    const dir = await mkdtemp(join(tmpdir(), "vidyut-laptop-time-checkpoint-"));
    const destination = join(dir, "report.bin");
    const bytes = new Uint8Array([1, 2, 3, 4, 5, 6, 7, 8]);
    let persisted: ReturnType<TransferQueue["snapshot"]> | undefined;
    const persistedOffsets: number[] = [];
    const queue = await TransferQueue.open({
      storage: {
        async load() {
          return persisted;
        },
        async save(value) {
          persisted = structuredClone(value);
          persistedOffsets.push(
            value.batches[0]?.files[0]?.confirmedOffset ?? -1,
          );
        },
      },
      id: (() => {
        let sequence = 0;
        return (prefix: string) => `${prefix}_time_${++sequence}`;
      })(),
    });
    const offer = {
      transferId: "transfer_time_1234",
      batchId: "batch_time_123456",
      origin: "phone",
      direction: "phone_to_laptop" as const,
      createdAtMs: 1_753_689_600_000,
      files: [{
        fileId: "file_time_123456",
        filename: "report.bin",
        mime: "application/octet-stream",
        size: bytes.length,
        lastModifiedMs: 1_753_689_500_000,
        sha256: await sha256Hex(bytes),
      }],
    };
    await queue.acceptOffer(
      offer,
      new Map([[offer.files[0]!.fileId, destination]]),
    );
    await queue.claimNext();
    const controls: unknown[] = [];
    let now = 0;
    const plane = new LaptopTransferDataPlane(
      secret,
      queue,
      2,
      (message) => controls.push(message),
      undefined,
      undefined,
      {
        now: () => now,
        checkpointBytes: 100,
        checkpointIntervalMs: 1_000,
        publishIntervalMs: 500,
      },
    );

    await putChunk(plane, offer.transferId, offer.files[0]!.fileId, 0, bytes.slice(0, 2));
    now = 600;
    await putChunk(plane, offer.transferId, offer.files[0]!.fileId, 2, bytes.slice(2, 4));
    expect(persisted!.batches[0]!.files[0]!.confirmedOffset).toBe(0);
    expect(controls).toMatchObject([
      { kind: "transfer_progress", confirmedOffset: 4 },
    ]);

    now = 1_000;
    await putChunk(plane, offer.transferId, offer.files[0]!.fileId, 4, bytes.slice(4, 6));
    expect(persisted!.batches[0]!.files[0]!.confirmedOffset).toBe(6);
    expect(persistedOffsets).toContain(6);
    expect(controls).toMatchObject([
      { kind: "transfer_progress", confirmedOffset: 4 },
      { kind: "transfer_progress", confirmedOffset: 6 },
    ]);

    now = 1_100;
    const final = await putChunk(
      plane,
      offer.transferId,
      offer.files[0]!.fileId,
      6,
      bytes.slice(6),
    );
    expect(final.status).toBe(200);
    expect(await final.json()).toEqual({
      confirmedOffset: 8,
      complete: true,
    });
    await rm(dir, { recursive: true, force: true });
  });

  test("restarts from the durable checkpoint and safely overwrites the tail", async () => {
    const dir = await mkdtemp(join(tmpdir(), "vidyut-laptop-restart-"));
    const queuePath = join(dir, "queue.json");
    const destination = join(dir, "report.bin");
    const bytes = new Uint8Array([1, 2, 3, 4]);
    const storage = new JsonTransferQueueStorage(queuePath);
    const queue = await TransferQueue.open({ storage });
    const offer = {
      transferId: "transfer_restart_1234",
      batchId: "batch_restart_123456",
      origin: "phone",
      direction: "phone_to_laptop" as const,
      createdAtMs: 1_753_689_600_000,
      files: [{
        fileId: "file_restart_123456",
        filename: "report.bin",
        mime: "application/octet-stream",
        size: bytes.length,
        lastModifiedMs: 1_753_689_500_000,
        sha256: await sha256Hex(bytes),
      }],
    };
    await queue.acceptOffer(
      offer,
      new Map([[offer.files[0]!.fileId, destination]]),
    );
    await queue.claimNext();
    const firstPlane = new LaptopTransferDataPlane(
      secret,
      queue,
      2,
      undefined,
      undefined,
      undefined,
      {
        checkpointBytes: 4,
        checkpointIntervalMs: 1_000,
        publishIntervalMs: 1_000,
      },
    );
    const first = await putChunk(
      firstPlane,
      offer.transferId,
      offer.files[0]!.fileId,
      0,
      bytes.slice(0, 2),
    );
    expect(await first.json()).toEqual({
      confirmedOffset: 2,
      complete: false,
    });
    const persistedAfterFirst = await storage.load();
    expect(persistedAfterFirst!.batches[0]!.files[0]!.confirmedOffset).toBe(0);

    const restarted = await TransferQueue.open({ storage });
    await restarted.claimNext();
    const secondPlane = new LaptopTransferDataPlane(
      secret,
      restarted,
      2,
      undefined,
      undefined,
      undefined,
      {
        checkpointBytes: 4,
        checkpointIntervalMs: 1_000,
        publishIntervalMs: 1_000,
      },
    );
    await putChunk(
      secondPlane,
      offer.transferId,
      offer.files[0]!.fileId,
      0,
      bytes.slice(0, 2),
    );
    const final = await putChunk(
      secondPlane,
      offer.transferId,
      offer.files[0]!.fileId,
      2,
      bytes.slice(2),
    );
    expect(await final.json()).toEqual({
      confirmedOffset: 4,
      complete: true,
    });
    expect(new Uint8Array(await Bun.file(destination).arrayBuffer())).toEqual(
      bytes,
    );
    await rm(dir, { recursive: true, force: true });
  });

  test("preserves an existing destination by collision-safe renaming", async () => {
    const dir = await mkdtemp(join(tmpdir(), "vidyut-laptop-collision-"));
    const destination = join(dir, "report.bin");
    await writeFile(destination, new Uint8Array([9]));
    const bytes = new Uint8Array([1, 2]);
    const queue = await emptyQueue();
    const offer = {
      transferId: "transfer_remote_5678",
      batchId: "batch_remote_567890",
      origin: "phone",
      direction: "phone_to_laptop" as const,
      createdAtMs: 1_753_689_600_000,
      files: [
        {
          fileId: "file_remote_567890",
          filename: "report.bin",
          mime: "application/octet-stream",
          size: bytes.length,
          lastModifiedMs: 1_753_689_500_000,
          sha256: await sha256Hex(bytes),
        },
      ],
    };
    await queue.acceptOffer(
      offer,
      new Map([[offer.files[0]!.fileId, destination]]),
    );
    await queue.claimNext();
    const plane = new LaptopTransferDataPlane(secret, queue, 4);

    const response = await putChunk(
      plane,
      offer.transferId,
      offer.files[0]!.fileId,
      0,
      bytes,
    );

    expect(response.status).toBe(200);
    expect(new Uint8Array(await Bun.file(destination).arrayBuffer())).toEqual(
      new Uint8Array([9]),
    );
    expect(
      new Uint8Array(
        await Bun.file(join(dir, "report (1).bin")).arrayBuffer(),
      ),
    ).toEqual(bytes);
    expect(
      queue.snapshot().batches[0]!.files[0]!.destinationPath,
    ).toBe(join(dir, "report (1).bin"));
    await rm(dir, { recursive: true, force: true });
  });

  test("fails a resumed upload when its persisted partial is missing", async () => {
    const dir = await mkdtemp(join(tmpdir(), "vidyut-laptop-missing-partial-"));
    const destination = join(dir, "report.bin");
    const bytes = new Uint8Array([1, 2, 3, 4, 5, 6]);
    const queue = await emptyQueue();
    const offer = {
      transferId: "transfer_missing_1234",
      batchId: "batch_missing_123456",
      origin: "phone",
      direction: "phone_to_laptop" as const,
      createdAtMs: 1_753_689_600_000,
      files: [{
        fileId: "file_missing_123456",
        filename: "report.bin",
        mime: "application/octet-stream",
        size: bytes.length,
        lastModifiedMs: 1_753_689_500_000,
        sha256: await sha256Hex(bytes),
      }],
    };
    await queue.acceptOffer(
      offer,
      new Map([[offer.files[0]!.fileId, destination]]),
    );
    await queue.claimNext();
    let terminalCalls = 0;
    const plane = new LaptopTransferDataPlane(
      secret,
      queue,
      4,
      undefined,
      () => {
        terminalCalls += 1;
      },
    );
    expect(
      (await putChunk(plane, offer.transferId, offer.files[0]!.fileId, 0, bytes.slice(0, 4))).status,
    ).toBe(200);
    await unlink(join(dir, `.report.bin.${offer.files[0]!.fileId}.vidyut-part`));

    const resumed = await putChunk(
      plane,
      offer.transferId,
      offer.files[0]!.fileId,
      4,
      bytes.slice(4),
    );

    expect(resumed.status).toBe(409);
    expect(queue.snapshot().batches[0]!.files[0]!.status).toBe("failed");
    expect(terminalCalls).toBe(1);
    await rm(dir, { recursive: true, force: true });
  });

  test("fails cleanly when terminal processing throws", async () => {
    const dir = await mkdtemp(join(tmpdir(), "vidyut-laptop-terminal-fail-"));
    const destination = join(dir, "report.bin");
    const bytes = new Uint8Array([1, 2, 3, 4, 5, 6]);
    const queue = await emptyQueue();
    const offer = {
      transferId: "transfer_terminal_1234",
      batchId: "batch_terminal_123456",
      origin: "phone",
      direction: "phone_to_laptop" as const,
      createdAtMs: 1_753_689_600_000,
      files: [{
        fileId: "file_terminal_123456",
        filename: "report.bin",
        mime: "application/octet-stream",
        size: bytes.length,
        lastModifiedMs: 1_753_689_500_000,
        sha256: await sha256Hex(bytes),
      }],
    };
    await queue.acceptOffer(
      offer,
      new Map([[offer.files[0]!.fileId, destination]]),
    );
    await queue.claimNext();
    const controls: unknown[] = [];
    let terminalCalls = 0;
    const plane = new LaptopTransferDataPlane(
      secret,
      queue,
      4,
      (message) => controls.push(message),
      () => {
        terminalCalls += 1;
      },
    );
    try {
      expect(
        (await putChunk(
          plane,
          offer.transferId,
          offer.files[0]!.fileId,
          0,
          bytes.slice(0, 4),
        )).status,
      ).toBe(200);
      await chmod(dir, 0o500);

      const response = await putChunk(
        plane,
        offer.transferId,
        offer.files[0]!.fileId,
        4,
        bytes.slice(4),
      );

      expect(response.status).toBe(500);
      expect(queue.snapshot().batches[0]!.files[0]!.status).toBe("failed");
      expect(controls.at(-1)).toMatchObject({
        kind: "transfer_file_failed",
        code: "terminal_processing_failed",
      });
      expect(terminalCalls).toBe(1);
    } finally {
      await chmod(dir, 0o700);
      await rm(dir, { recursive: true, force: true });
    }
  });

  test("queues signed local file-manager requests without exposing another port", async () => {
    const queue = await emptyQueue();
    const seen: string[][] = [];
    const plane = new LaptopTransferDataPlane(
      secret,
      queue,
      4,
      undefined,
      undefined,
      async (paths) => {
        seen.push(paths);
        return { transferId: "transfer_local_1234" };
      },
    );
    const body = new TextEncoder().encode(
      JSON.stringify(["/home/user/report.pdf"]),
    );
    const digest = await sha256Hex(body);
    const path = `/transfer/v1/local/enqueue?digest=${digest}`;
    const auth = await createTransferHttpAuth({
      pairingSecret: secret,
      method: "POST",
      pathAndQuery: path,
    });

    const response = await plane.handle(
      new Request(`http://relay${path}`, {
        method: "POST",
        headers: {
          "x-vidyut-date": auth.date,
          authorization: auth.authorization,
        },
        body: exactArrayBuffer(body),
      }),
      { isLoopback: true },
    );

    expect(response?.status).toBe(202);
    expect(seen).toEqual([["/home/user/report.pdf"]]);

    const remote = await plane.handle(
      new Request(`http://relay${path}`, {
        method: "POST",
        headers: {
          "x-vidyut-date": auth.date,
          authorization: auth.authorization,
        },
        body: exactArrayBuffer(body),
      }),
    );
    expect(remote?.status).toBe(403);
  });
});

async function createFixture(bytes: Uint8Array) {
  const dir = await mkdtemp(join(tmpdir(), "vidyut-laptop-source-"));
  const path = join(dir, "source.bin");
  await writeFile(path, bytes);
  const sourceStat = await stat(path);
  let sequence = 0;
  let snapshot: ReturnType<TransferQueue["snapshot"]> | undefined;
  const queue = await TransferQueue.open({
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
  const batch = await queue.enqueue({
    direction: "laptop_to_phone",
    origin: "laptop",
    files: [
      {
        filename: "source.bin",
        mime: "application/octet-stream",
        size: bytes.byteLength,
        lastModifiedMs: sourceStat.mtimeMs,
        sha256: await sha256Hex(bytes),
        sourcePath: path,
      },
    ],
  });
  return {
    queue,
    batch,
    path,
    async cleanup() {
      await rm(dir, { recursive: true, force: true });
    },
  };
}

async function getChunk(
  plane: LaptopTransferDataPlane,
  transferId: string,
  fileId: string,
  offset: number,
) {
  const path = `/transfer/v1/${transferId}/${fileId}?offset=${offset}`;
  const auth = await createTransferHttpAuth({
    pairingSecret: secret,
    method: "GET",
    pathAndQuery: path,
  });
  const response = await plane.handle(
    new Request(`http://relay${path}`, {
      headers: {
        "x-vidyut-date": auth.date,
        authorization: auth.authorization,
      },
    }),
  );
  if (!response) throw new Error("Expected transfer response.");
  return { response };
}

async function putChunk(
  plane: LaptopTransferDataPlane,
  transferId: string,
  fileId: string,
  offset: number,
  plaintext: Uint8Array,
): Promise<Response> {
  const path = `/transfer/v1/${transferId}/${fileId}?offset=${offset}`;
  const encrypted = await encryptTransferChunk(
    { transferId, fileId, offset, plaintextBytes: plaintext.length },
    plaintext,
    secret,
  );
  const auth = await createTransferHttpAuth({
    pairingSecret: secret,
    method: "PUT",
    pathAndQuery: path,
  });
  const response = await plane.handle(
    new Request(`http://relay${path}`, {
      method: "PUT",
      headers: {
        "x-vidyut-date": auth.date,
        authorization: auth.authorization,
        "x-vidyut-nonce": encrypted.nonce,
        "x-vidyut-plaintext-bytes": String(plaintext.length),
      },
      body: exactArrayBuffer(encrypted.ciphertext),
    }),
  );
  if (!response) throw new Error("Expected transfer response.");
  return response;
}

async function decryptResponse(
  response: Response,
  transferId: string,
  fileId: string,
): Promise<Uint8Array> {
  return decryptTransferChunk(
    {
      transferId,
      fileId,
      offset: Number(response.headers.get("x-vidyut-offset")),
      plaintextBytes: Number(
        response.headers.get("x-vidyut-plaintext-bytes"),
      ),
      nonce: response.headers.get("x-vidyut-nonce")!,
      ciphertext: new Uint8Array(await response.arrayBuffer()),
    },
    secret,
  );
}

async function emptyQueue() {
  let snapshot: ReturnType<TransferQueue["snapshot"]> | undefined;
  return TransferQueue.open({
    storage: {
      async load() {
        return snapshot;
      },
      async save(value) {
        snapshot = structuredClone(value);
      },
    },
  });
}

function exactArrayBuffer(bytes: Uint8Array): ArrayBuffer {
  const buffer = new ArrayBuffer(bytes.byteLength);
  new Uint8Array(buffer).set(bytes);
  return buffer;
}
