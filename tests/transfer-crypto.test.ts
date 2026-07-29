import { describe, expect, test } from "bun:test";
import {
  decryptTransferChunk,
  encryptTransferChunk,
  sha256Hex,
} from "../src/shared/transfer-crypto";

const metadata = {
  transferId: "transfer_1234567890",
  fileId: "file_1234567890123",
  offset: 4096,
  plaintextBytes: 5,
};

describe("transfer chunk crypto", () => {
  test("round-trips an independently authenticated chunk", async () => {
    const plaintext = new Uint8Array([1, 2, 3, 4, 5]);
    const chunk = await encryptTransferChunk(
      metadata,
      plaintext,
      "pairing-secret",
      new Uint8Array(12).fill(7),
    );

    await expect(
      decryptTransferChunk(chunk, "pairing-secret"),
    ).resolves.toEqual(plaintext);
  });

  test("binds ciphertext to transfer, file, offset and byte count", async () => {
    const chunk = await encryptTransferChunk(
      metadata,
      new Uint8Array([1, 2, 3, 4, 5]),
      "pairing-secret",
    );

    await expect(
      decryptTransferChunk({ ...chunk, offset: 0 }, "pairing-secret"),
    ).rejects.toThrow();
    await expect(
      decryptTransferChunk(
        { ...chunk, fileId: "file_DIFFERENT_1234" },
        "pairing-secret",
      ),
    ).rejects.toThrow();
  });

  test("rejects mismatched plaintext size before encryption", async () => {
    await expect(
      encryptTransferChunk(
        metadata,
        new Uint8Array([1, 2]),
        "pairing-secret",
      ),
    ).rejects.toThrow(/byte count/);
  });

  test("produces a lowercase whole-file SHA-256", async () => {
    await expect(sha256Hex(new TextEncoder().encode("abc"))).resolves.toBe(
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
    );
  });
});

