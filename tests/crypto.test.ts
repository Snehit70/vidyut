import { describe, expect, test } from "bun:test";
import { decryptAlternative, decryptPayload, encryptAlternative, encryptPayload } from "../src/shared/crypto";
import { encodedPayloadBytes, isPayloadFrame } from "../src/shared/wire";

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

  test("round-trips a formatted alternative bound to its frame", async () => {
    const secret = "pairing-secret";
    const metadata = { type: "text" as const, mime: "text/plain", origin: "laptop", ts: 1_800_000_010_010 };
    const frame = await encryptPayload(metadata, new TextEncoder().encode("hi"), secret);
    const html = new TextEncoder().encode("<b>hi</b>");
    const alt = await encryptAlternative(frame, "text/html", html, secret);

    await expect(decryptAlternative(frame, alt, secret)).resolves.toEqual(html);
    await expect(decryptAlternative(frame, alt, "wrong-secret")).rejects.toThrow();

    // Lifted onto another frame, the alternative no longer opens.
    const other = await encryptPayload(metadata, new TextEncoder().encode("hi"), secret);
    await expect(decryptAlternative(other, alt, secret)).rejects.toThrow();
  });
});

describe("payload frame shape", () => {
  const frame = { v: 1, type: "text", mime: "text/plain", origin: "laptop", ts: 1, nonce: "AA==", payload: "AAAA" };

  test("accepts a frame with or without a well-formed alternative", () => {
    expect(isPayloadFrame(frame)).toBe(true);
    expect(isPayloadFrame({ ...frame, alt: { mime: "text/html", nonce: "AA==", payload: "AAAA" } })).toBe(true);
  });

  test("rejects a malformed alternative", () => {
    expect(isPayloadFrame({ ...frame, alt: { mime: "text/rtf", nonce: "AA==", payload: "AAAA" } })).toBe(false);
    expect(isPayloadFrame({ ...frame, alt: { mime: "text/html", nonce: "AA==" } })).toBe(false);
    expect(isPayloadFrame({ ...frame, alt: "AAAA" })).toBe(false);
  });

  test("counts the alternative against the payload size", () => {
    const withAlt = { ...frame, alt: { mime: "text/html" as const, nonce: "AA==", payload: "AAAAAAAA" } };
    expect(encodedPayloadBytes(frame as never)).toBe(3);
    expect(encodedPayloadBytes(withAlt as never)).toBe(9);
  });
});
