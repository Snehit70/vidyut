import { describe, expect, test } from "bun:test";
import {
  isTransferControlMessage,
  isTransferOffer,
  type TransferOffer,
} from "../src/shared/wire";

const fileOffer = {
  fileId: "file_1234567890123",
  filename: "report.pdf",
  mime: "application/pdf",
  size: 42,
  lastModifiedMs: 1_753_689_500_000,
  sha256: "a".repeat(64),
};

const offer: TransferOffer = {
  transferId: "transfer_1234567890",
  batchId: "batch_123456789012",
  origin: "laptop",
  direction: "laptop_to_phone",
  createdAtMs: 1_753_689_600_000,
  files: [fileOffer],
};

describe("transfer wire contract", () => {
  test("accepts a valid multi-file offer with empty files", () => {
    expect(
      isTransferOffer({
        ...offer,
        files: [
          ...offer.files,
          {
            fileId: "file_ABCDEFGHIJKLM",
            filename: "empty.txt",
            mime: "text/plain",
            size: 0,
            lastModifiedMs: 0,
            sha256: "e".repeat(64),
          },
        ],
      }),
    ).toBe(true);
  });

  test("rejects path traversal and duplicate file ids", () => {
    expect(
      isTransferOffer({
        ...offer,
        files: [{ ...fileOffer, filename: "../secret" }],
      }),
    ).toBe(false);
    expect(
      isTransferOffer({
        ...offer,
        files: [fileOffer, { ...fileOffer, filename: "copy.pdf" }],
      }),
    ).toBe(false);
  });

  test("rejects unsafe sizes and malformed hashes", () => {
    expect(
      isTransferOffer({
        ...offer,
        files: [{ ...fileOffer, size: Number.MAX_SAFE_INTEGER + 1 }],
      }),
    ).toBe(false);
    expect(
      isTransferOffer({
        ...offer,
        files: [{ ...fileOffer, sha256: "ABC" }],
      }),
    ).toBe(false);
  });

  test("validates receiver-confirmed progress and terminal messages", () => {
    expect(
      isTransferControlMessage({
        v: 1,
        kind: "transfer_progress",
        transferId: offer.transferId,
        fileId: fileOffer.fileId,
        confirmedOffset: 4096,
      }),
    ).toBe(true);
    expect(
      isTransferControlMessage({
        v: 1,
        kind: "transfer_progress",
        transferId: offer.transferId,
        fileId: fileOffer.fileId,
        confirmedOffset: -1,
      }),
    ).toBe(false);
    expect(
      isTransferControlMessage({
        v: 1,
        kind: "transfer_file_complete",
        transferId: offer.transferId,
        fileId: fileOffer.fileId,
        sha256: "b".repeat(64),
      }),
    ).toBe(true);
  });
});
