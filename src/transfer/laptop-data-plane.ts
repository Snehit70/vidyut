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
import { TransferQueue } from "./transfer-queue";
import { TransferHttpDataPlane } from "./http-data-plane";
import {
  legacyTransferChunkBytes,
  preferredTransferChunkBytes,
} from "./transfer-chunk-policy";

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
    const record = this.lookup(
      transferId!,
      fileId!,
      request.method === "GET" ? "laptop_to_phone" : "phone_to_laptop",
    );
    if (!record) {
      return Response.json({ code: "transfer_not_found" }, { status: 404 });
    }
    const offset = parseOffset(url.searchParams.get("offset"));
    if (offset === undefined) {
      return Response.json({ code: "invalid_offset" }, { status: 400 });
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
    if (request.method === "PUT") {
      return this.handleUpload(
        request,
        transferId!,
        fileId!,
        offset,
        record,
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
    record: TransferFileRecord,
  ): Promise<Response> {
    if (!record.destinationPath || record.status !== "active") {
      return Response.json(
        { code: "transfer_not_active" },
        { status: 409 },
      );
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
        await this.onFileTerminal();
        return Response.json(
          { code: "partial_state_missing", confirmedOffset: 0 },
          { status: 409 },
        );
      }
      throw error;
    }
    try {
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
      await destination.sync();
    } finally {
      await destination.close();
    }

    const confirmedOffset = offset + plaintext.byteLength;
    if (confirmedOffset === record.size) {
      await this.queue.beginVerification(
        transferId,
        fileId,
        confirmedOffset,
      );
    } else {
      await this.queue.confirmProgress(transferId, fileId, confirmedOffset);
    }
    this.publishControl({
      v: 1,
      kind: "transfer_progress",
      transferId,
      fileId,
      confirmedOffset,
    });

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
          await this.onFileTerminal();
          return Response.json({ code: "hash_mismatch" }, { status: 409 });
        }
        const finalizedPath = await finalizeWithoutOverwrite(
          partialPath,
          record.destinationPath,
        );
        await this.queue.setDestinationPath(
          transferId,
          fileId,
          finalizedPath,
        );
        const modified = new Date(record.lastModifiedMs);
        await utimes(finalizedPath, modified, modified).catch(() => undefined);
        await this.queue.complete(transferId, fileId, verifiedSha256);
      } catch {
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

function parseNonNegativeInteger(value: string | null): number | undefined {
  if (value === null || !/^(0|[1-9][0-9]*)$/.test(value)) return undefined;
  const parsed = Number(value);
  return Number.isSafeInteger(parsed) && parsed >= 0 ? parsed : undefined;
}

function partialPathFor(destinationPath: string, fileId: string): string {
  return join(
    dirname(destinationPath),
    `.${basename(destinationPath)}.${fileId}.vidyut-part`,
  );
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
): Promise<string> {
  const extension = extname(requestedPath);
  const stem = basename(requestedPath, extension);
  const parent = dirname(requestedPath);
  for (let suffix = 0; suffix < 10_000; suffix += 1) {
    const candidate =
      suffix === 0
        ? requestedPath
        : join(parent, `${stem} (${suffix})${extension}`);
    try {
      await link(partialPath, candidate);
      await unlink(partialPath);
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

function toArrayBuffer(bytes: Uint8Array): ArrayBuffer {
  const buffer = new ArrayBuffer(bytes.byteLength);
  new Uint8Array(buffer).set(bytes);
  return buffer;
}
