import { createCipheriv, createDecipheriv, createHmac, timingSafeEqual } from "node:crypto";
import type { RelayMessage, SealedMessage } from "./wire";

/**
 * Mutual auth and sealed control for one Relay WebSocket session (ADR 0023).
 *
 * The phone's `auth` proves it holds the pairing secret; `relayProof` in
 * `auth_ok` proves the Relay does too, over both challenges and the features
 * the session settled on, so neither side can be impersonated or have its
 * features stripped in transit. With `sealed_control`, every later message
 * except `publish`/`payload` (already encrypted end to end) travels as
 * AES-256-GCM under a key unique to the session.
 */

/** clientChallenge is base64 of 16–48 random bytes; nothing else is signed. */
const clientChallengePattern = /^[A-Za-z0-9+/]{22,64}={0,2}$/;

export function isClientChallenge(value: unknown): value is string {
  return typeof value === "string" && clientChallengePattern.test(value);
}

/**
 * The challenges are base64 and the features come from a fixed set, so none
 * contains `:`; deviceId goes last so its own colons cannot shift a field.
 */
export function createRelayProof(
  pairingSecret: string,
  challenge: string,
  clientChallenge: string,
  sessionFeatures: readonly string[],
  deviceId: string,
): string {
  return createHmac("sha256", pairingSecret)
    .update(`vidyut-relay-proof-v1:${challenge}:${clientChallenge}:${sessionFeatures.join(",")}:${deviceId}`)
    .digest("base64");
}

export function verifyRelayProof(
  pairingSecret: string,
  challenge: string,
  clientChallenge: string,
  sessionFeatures: readonly string[],
  deviceId: string,
  proof: string,
): boolean {
  const expected = Buffer.from(
    createRelayProof(pairingSecret, challenge, clientChallenge, sessionFeatures, deviceId),
  );
  const actual = Buffer.from(proof);
  return expected.byteLength === actual.byteLength && timingSafeEqual(expected, actual);
}

export function deriveSessionKey(
  pairingSecret: string,
  challenge: string,
  clientChallenge: string,
  deviceId: string,
): Uint8Array {
  return new Uint8Array(
    createHmac("sha256", pairingSecret)
      .update(`vidyut-session-v1:${challenge}:${clientChallenge}:${deviceId}`)
      .digest(),
  );
}

export type SealDirection = "relay_to_phone" | "phone_to_relay";

const directionByte: Record<SealDirection, number> = {
  relay_to_phone: 0,
  phone_to_relay: 1,
};

/** Messages that stay in the clear on a sealed session: their frames carry their own encryption. */
export function travelsUnsealed(message: RelayMessage): boolean {
  return message.kind === "publish" || message.kind === "payload";
}

/**
 * One direction pair of a sealed session. Nonces are the direction byte, three
 * zero bytes, then a 64-bit big-endian counter, so a nonce never repeats under
 * a key and a dropped, replayed, reordered or reflected message fails to open.
 */
export class SessionSealer {
  readonly #key: Uint8Array;
  readonly #sendDirection: SealDirection;
  readonly #receiveDirection: SealDirection;
  #sent = 0n;
  #received = 0n;

  constructor(key: Uint8Array, sendDirection: SealDirection) {
    this.#key = key;
    this.#sendDirection = sendDirection;
    this.#receiveDirection = sendDirection === "relay_to_phone" ? "phone_to_relay" : "relay_to_phone";
  }

  seal(message: RelayMessage): SealedMessage {
    const nonce = sealNonce(this.#sendDirection, this.#sent);
    this.#sent += 1n;
    const cipher = createCipheriv("aes-256-gcm", this.#key, nonce);
    const ciphertext = Buffer.concat([
      cipher.update(JSON.stringify(message), "utf8"),
      cipher.final(),
      cipher.getAuthTag(),
    ]);
    return {
      v: 1,
      kind: "sealed",
      nonce: Buffer.from(nonce).toString("base64"),
      payload: ciphertext.toString("base64"),
    };
  }

  /** Throws when the message is not the next one from the peer, or was altered. */
  open(sealed: SealedMessage): RelayMessage {
    const expected = sealNonce(this.#receiveDirection, this.#received);
    if (typeof sealed.nonce !== "string" || typeof sealed.payload !== "string") {
      throw new Error("sealed message is malformed");
    }
    if (!Buffer.from(sealed.nonce, "base64").equals(expected)) {
      throw new Error("sealed message is out of sequence");
    }
    const bytes = Buffer.from(sealed.payload, "base64");
    if (bytes.byteLength < 16) throw new Error("sealed message is too short");
    const decipher = createDecipheriv("aes-256-gcm", this.#key, expected);
    decipher.setAuthTag(bytes.subarray(bytes.byteLength - 16));
    const plaintext = Buffer.concat([
      decipher.update(bytes.subarray(0, bytes.byteLength - 16)),
      decipher.final(),
    ]);
    this.#received += 1n;
    return JSON.parse(plaintext.toString("utf8")) as RelayMessage;
  }
}

export function sealNonce(direction: SealDirection, counter: bigint): Buffer {
  const nonce = Buffer.alloc(12);
  nonce.writeUInt8(directionByte[direction], 0);
  nonce.writeBigUInt64BE(counter, 4);
  return nonce;
}
