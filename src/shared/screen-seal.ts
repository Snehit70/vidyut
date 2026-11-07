import { createCipheriv, createDecipheriv } from "node:crypto";

/**
 * Records of one screen mirror stream (ADR 0030).
 *
 * The phone writes its H.264 stream as binary WebSocket messages, one record
 * each. A record is AES-256-GCM ciphertext with the 16-byte tag at the end.
 * The key is fresh for every stream and the nonce is four zero bytes and a
 * 64-bit big-endian record counter, so a nonce never repeats under a key and
 * a dropped, replayed or reordered record fails to open.
 */

export const screenKeyBytes = 32;
export const screenTagBytes = 16;

/** The largest sealed record the relay accepts: a 1080p keyframe is far smaller. */
export const maxScreenRecordBytes = 4 * 1024 * 1024;

export function screenNonce(counter: bigint): Buffer {
  const nonce = Buffer.alloc(12);
  nonce.writeBigUInt64BE(counter, 4);
  return nonce;
}

/** Seals one record. The phone does this in Kotlin; the relay only in tests. */
export function sealScreenRecord(key: Uint8Array, counter: bigint, plaintext: Uint8Array): Buffer {
  const cipher = createCipheriv("aes-256-gcm", key, screenNonce(counter));
  return Buffer.concat([cipher.update(plaintext), cipher.final(), cipher.getAuthTag()]);
}

/** Opens the records of one stream in order. Throws on a bad or out-of-order record. */
export class ScreenRecordOpener {
  readonly #key: Uint8Array;
  #counter = 0n;

  constructor(key: Uint8Array) {
    if (key.byteLength !== screenKeyBytes) throw new Error("screen key must be 32 bytes");
    this.#key = key;
  }

  /** Records opened so far. */
  get records(): bigint {
    return this.#counter;
  }

  open(record: Uint8Array): Buffer {
    if (record.byteLength < screenTagBytes || record.byteLength > maxScreenRecordBytes) {
      throw new Error(`screen record has a bad length (${record.byteLength})`);
    }
    const sealed = Buffer.from(record.buffer, record.byteOffset, record.byteLength);
    const decipher = createDecipheriv("aes-256-gcm", this.#key, screenNonce(this.#counter));
    decipher.setAuthTag(sealed.subarray(sealed.byteLength - screenTagBytes));
    const plaintext = Buffer.concat([
      decipher.update(sealed.subarray(0, sealed.byteLength - screenTagBytes)),
      decipher.final(),
    ]);
    this.#counter += 1n;
    return plaintext;
  }
}
