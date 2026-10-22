import type { PayloadFrame, PayloadMetadata } from "./wire";

const textEncoder = new TextEncoder();
const kdfSalt = textEncoder.encode("vidyut-v1-pairing-secret");
const kdfIterations = 200_000;
// PBKDF2 at 200k iterations costs ~100 ms, and every clipboard copy in either
// direction derives the same key. Keyed by secret so a rotation derives fresh;
// the bound keeps a long-running Relay from holding every secret it has used.
const keyCache = new Map<string, Promise<CryptoKey>>();
const keyCacheLimit = 4;

export async function encryptPayload(
  metadata: PayloadMetadata,
  plaintext: Uint8Array,
  pairingSecret: string,
  nonceBytes: Uint8Array = crypto.getRandomValues(new Uint8Array(12)),
): Promise<PayloadFrame> {
  const nonce = toBase64(nonceBytes);
  const frameMetadata = { v: 1 as const, ...metadata, nonce };
  const key = await derivePayloadKey(pairingSecret);
  const ciphertext = await crypto.subtle.encrypt(
    {
      name: "AES-GCM",
      iv: toArrayBuffer(nonceBytes),
      additionalData: associatedData(frameMetadata),
    },
    key,
    toArrayBuffer(plaintext),
  );

  return {
    ...frameMetadata,
    payload: toBase64(new Uint8Array(ciphertext)),
  };
}

export async function decryptPayload(frame: PayloadFrame, pairingSecret: string): Promise<Uint8Array> {
  const key = await derivePayloadKey(pairingSecret);
  const plaintext = await crypto.subtle.decrypt(
    {
      name: "AES-GCM",
      iv: toArrayBuffer(fromBase64(frame.nonce)),
      additionalData: associatedData(frame),
    },
    key,
    toArrayBuffer(fromBase64(frame.payload)),
  );
  return new Uint8Array(plaintext);
}

function derivePayloadKey(pairingSecret: string): Promise<CryptoKey> {
  const cached = keyCache.get(pairingSecret);
  if (cached) return cached;
  const key = (async () => {
    const baseKey = await crypto.subtle.importKey(
      "raw",
      textEncoder.encode(pairingSecret),
      "PBKDF2",
      false,
      ["deriveKey"],
    );

    return crypto.subtle.deriveKey(
      {
        name: "PBKDF2",
        salt: kdfSalt,
        iterations: kdfIterations,
        hash: "SHA-256",
      },
      baseKey,
      { name: "AES-GCM", length: 256 },
      false,
      ["encrypt", "decrypt"],
    );
  })();
  // A failed derivation must not poison every later payload.
  key.catch(() => {
    if (keyCache.get(pairingSecret) === key) keyCache.delete(pairingSecret);
  });
  keyCache.set(pairingSecret, key);
  while (keyCache.size > keyCacheLimit) {
    keyCache.delete(keyCache.keys().next().value as string);
  }
  return key;
}

function associatedData(frame: Omit<PayloadFrame, "payload">): ArrayBuffer {
  return toArrayBuffer(textEncoder.encode(
    JSON.stringify({
      v: frame.v,
      type: frame.type,
      mime: frame.mime,
      origin: frame.origin,
      ts: frame.ts,
      nonce: frame.nonce,
    }),
  ));
}

function toBase64(bytes: Uint8Array): string {
  return Buffer.from(bytes).toString("base64");
}

function fromBase64(value: string): Uint8Array {
  return new Uint8Array(Buffer.from(value, "base64"));
}

function toArrayBuffer(bytes: Uint8Array): ArrayBuffer {
  const buffer = new ArrayBuffer(bytes.byteLength);
  new Uint8Array(buffer).set(bytes);
  return buffer;
}
