import { describe, expect, test } from "bun:test";
import { decryptPayload, encryptPayload } from "../src/shared/crypto";

describe("payload crypto", () => {
  test("round-trips encrypted text payloads", async () => {
    const secret = "pairing-secret";
    const plaintext = new TextEncoder().encode("clipboard text");

    const frame = await encryptPayload(
      { type: "text", mime: "text/plain", origin: "laptop", ts: 1_800_000_010_000 },
      plaintext,
      secret,
    );

    await expect(decryptPayload(frame, secret)).resolves.toEqual(plaintext);
  });

  test("rejects the wrong pairing secret", async () => {
    const frame = await encryptPayload(
      { type: "text", mime: "text/plain", origin: "laptop", ts: 1_800_000_010_001 },
      new TextEncoder().encode("private clipboard text"),
      "correct-secret",
    );

    await expect(decryptPayload(frame, "wrong-secret")).rejects.toThrow();
  });

  test("rejects tampered metadata", async () => {
    const frame = await encryptPayload(
      { type: "image", mime: "image/png", origin: "phone", ts: 1_800_000_010_002 },
      new Uint8Array([137, 80, 78, 71]),
      "pairing-secret",
    );

    await expect(decryptPayload({ ...frame, mime: "image/jpeg" }, "pairing-secret")).rejects.toThrow();
  });

  test("derives the key once per secret so repeat payloads skip PBKDF2", async () => {
    const secret = "pairing-secret-cache-check";
    const metadata = { type: "text" as const, mime: "text/plain", origin: "laptop", ts: 1_800_000_010_003 };
    const plaintext = new TextEncoder().encode("x");
    const first = performance.now();
    await encryptPayload(metadata, plaintext, secret);
    const cold = performance.now() - first;
    const second = performance.now();
    for (let index = 0; index < 5; index += 1) {
      await encryptPayload(metadata, plaintext, secret);
    }
    const warm = (performance.now() - second) / 5;
    expect(warm).toBeLessThan(cold / 4);
  });

  test("a rotated secret still decrypts with its own key", async () => {
    const metadata = { type: "text" as const, mime: "text/plain", origin: "laptop", ts: 1_800_000_010_004 };
    const plaintext = new TextEncoder().encode("rotated");
    await encryptPayload(metadata, plaintext, "before-rotation");
    const frame = await encryptPayload(metadata, plaintext, "after-rotation");
    await expect(decryptPayload(frame, "after-rotation")).resolves.toEqual(plaintext);
    await expect(decryptPayload(frame, "before-rotation")).rejects.toThrow();
  });
});
