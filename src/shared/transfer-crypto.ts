const textEncoder = new TextEncoder();
const kdfSaltPrefix = "vidyut-v1-file-transfer";
const kdfIterations = 200_000;
const keyCache = new Map<string, Promise<CryptoKey>>();

export interface TransferChunkMetadata {
  transferId: string;
  fileId: string;
  offset: number;
  plaintextBytes: number;
}

export interface EncryptedTransferChunk extends TransferChunkMetadata {
  nonce: string;
  ciphertext: Uint8Array;
}

export async function encryptTransferChunk(
  metadata: TransferChunkMetadata,
  plaintext: Uint8Array,
  pairingSecret: string,
  nonceBytes: Uint8Array = crypto.getRandomValues(new Uint8Array(12)),
): Promise<EncryptedTransferChunk> {
  if (plaintext.byteLength !== metadata.plaintextBytes) {
    throw new RangeError("Chunk byte count does not match its metadata.");
  }
  const nonce = toBase64(nonceBytes);
  const ciphertext = await crypto.subtle.encrypt(
    {
      name: "AES-GCM",
      iv: toArrayBuffer(nonceBytes),
      additionalData: associatedData(metadata, nonce),
    },
    await deriveTransferKey(pairingSecret, metadata.transferId),
    toArrayBuffer(plaintext),
  );
  return {
    ...metadata,
    nonce,
    ciphertext: new Uint8Array(ciphertext),
  };
}

export async function decryptTransferChunk(
  chunk: EncryptedTransferChunk,
  pairingSecret: string,
): Promise<Uint8Array> {
  const plaintext = new Uint8Array(
    await crypto.subtle.decrypt(
      {
        name: "AES-GCM",
        iv: toArrayBuffer(fromBase64(chunk.nonce)),
        additionalData: associatedData(chunk, chunk.nonce),
      },
      await deriveTransferKey(pairingSecret, chunk.transferId),
      toArrayBuffer(chunk.ciphertext),
    ),
  );
  if (plaintext.byteLength !== chunk.plaintextBytes) {
    throw new Error("Decrypted chunk byte count does not match its metadata.");
  }
  return plaintext;
}

export async function sha256Hex(bytes: Uint8Array): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", toArrayBuffer(bytes));
  return Buffer.from(digest).toString("hex");
}

function deriveTransferKey(
  pairingSecret: string,
  transferId: string,
): Promise<CryptoKey> {
  const cacheKey = `${pairingSecret}\u0000${transferId}`;
  let key = keyCache.get(cacheKey);
  if (key) return key;
  key = (async () => {
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
        salt: textEncoder.encode(`${kdfSaltPrefix}\u0000${transferId}`),
        iterations: kdfIterations,
        hash: "SHA-256",
      },
      baseKey,
      { name: "AES-GCM", length: 256 },
      false,
      ["encrypt", "decrypt"],
    );
  })();
  keyCache.set(cacheKey, key);
  return key;
}

function associatedData(
  metadata: TransferChunkMetadata,
  nonce: string,
): ArrayBuffer {
  return toArrayBuffer(
    textEncoder.encode(
      JSON.stringify({
        v: 1,
        transferId: metadata.transferId,
        fileId: metadata.fileId,
        offset: metadata.offset,
        plaintextBytes: metadata.plaintextBytes,
        nonce,
      }),
    ),
  );
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
