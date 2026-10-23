import { describe, expect, test } from "bun:test";
import { createPairingProof } from "../src/shared/auth";
import { decryptAlternative, decryptPayload, encryptAlternative, encryptPayload } from "../src/shared/crypto";
import {
  createRelayProof,
  deriveSessionKey,
  SessionSealer,
  type SealDirection,
} from "../src/shared/session-seal";
import type { PayloadFrame, SealedMessage } from "../src/shared/wire";
import fixtures from "./fixtures/crypto-fixtures.json";

interface PayloadVector {
  name: string;
  pairingSecret: string;
  plaintextBase64: string;
  frame: PayloadFrame;
}

interface AlternativeVector extends PayloadVector {
  altPlaintextBase64: string;
  frame: PayloadFrame & { alt: NonNullable<PayloadFrame["alt"]> };
}

const payloadVectors = fixtures.payloadVectors as PayloadVector[];
const alternativeVectors = fixtures.alternativeVectors as AlternativeVector[];
const firstVector = payloadVectors[0];
if (!firstVector) throw new Error("crypto-fixtures.json has no payload vectors");

describe("cross-language crypto fixtures", () => {
  for (const vector of payloadVectors) {
    test(`decrypts payload vector ${vector.name}`, async () => {
      const plaintext = await decryptPayload(vector.frame, vector.pairingSecret);
      expect(Buffer.from(plaintext).toString("base64")).toBe(vector.plaintextBase64);
    });

    test(`re-encrypts payload vector ${vector.name} byte-for-byte`, async () => {
      const { type, mime, origin, ts } = vector.frame;
      const frame = await encryptPayload(
        { type, mime, origin, ts },
        new Uint8Array(Buffer.from(vector.plaintextBase64, "base64")),
        vector.pairingSecret,
        new Uint8Array(Buffer.from(vector.frame.nonce, "base64")),
      );
      expect(frame).toEqual(vector.frame);
    });
  }

  for (const vector of alternativeVectors) {
    test(`decrypts alternative vector ${vector.name}`, async () => {
      const plaintext = await decryptPayload(vector.frame, vector.pairingSecret);
      expect(Buffer.from(plaintext).toString("base64")).toBe(vector.plaintextBase64);
      const alt = await decryptAlternative(vector.frame, vector.frame.alt, vector.pairingSecret);
      expect(Buffer.from(alt).toString("base64")).toBe(vector.altPlaintextBase64);
    });

    test(`re-encrypts alternative vector ${vector.name} byte-for-byte`, async () => {
      const { alt, ...frame } = vector.frame;
      const sealed = await encryptAlternative(
        frame,
        alt.mime,
        new Uint8Array(Buffer.from(vector.altPlaintextBase64, "base64")),
        vector.pairingSecret,
        new Uint8Array(Buffer.from(alt.nonce, "base64")),
      );
      expect(sealed).toEqual(alt);
    });
  }

  test("rejects a fixture frame with the wrong pairing secret", async () => {
    await expect(decryptPayload(firstVector.frame, "wrong-secret")).rejects.toThrow();
  });

  test("rejects a fixture frame with tampered metadata", async () => {
    await expect(
      decryptPayload({ ...firstVector.frame, ts: firstVector.frame.ts + 1 }, firstVector.pairingSecret),
    ).rejects.toThrow();
  });

  test("rejects a fixture frame with tampered ciphertext", async () => {
    const bytes = Buffer.from(firstVector.frame.payload, "base64");
    bytes.writeUInt8(bytes.readUInt8(0) ^ 0xff, 0);
    await expect(
      decryptPayload({ ...firstVector.frame, payload: bytes.toString("base64") }, firstVector.pairingSecret),
    ).rejects.toThrow();
  });

  for (const vector of fixtures.pairingProofVectors) {
    test(`reproduces pairing proof vector ${vector.name}`, async () => {
      const proof = await createPairingProof(vector.pairingSecret, vector.challenge, vector.deviceId);
      expect(proof).toBe(vector.proofBase64);
    });
  }

  for (const vector of fixtures.sessionVectors) {
    test(`reproduces relay proof and session key vector ${vector.name}`, () => {
      const { pairingSecret, challenge, clientChallenge, deviceId, sessionFeatures } = vector;
      expect(createRelayProof(pairingSecret, challenge, clientChallenge, sessionFeatures, deviceId)).toBe(
        vector.relayProofBase64,
      );
      expect(Buffer.from(deriveSessionKey(pairingSecret, challenge, clientChallenge, deviceId)).toString("base64")).toBe(
        vector.sessionKeyBase64,
      );
    });
  }

  for (const vector of fixtures.sealVectors) {
    const key = new Uint8Array(Buffer.from(vector.sessionKeyBase64, "base64"));
    const direction = vector.direction as SealDirection;
    const peer: SealDirection = direction === "relay_to_phone" ? "phone_to_relay" : "relay_to_phone";
    const message = JSON.parse(vector.plaintextJson);

    test(`opens seal vector ${vector.name} as message ${vector.index} and nothing else`, () => {
      const sender = new SessionSealer(key, direction);
      const receiver = new SessionSealer(key, peer);
      for (let i = 0; i < vector.index; i++) receiver.open(sender.seal(message));
      expect(receiver.open(vector.sealed as SealedMessage)).toEqual(message);
      expect(() => new SessionSealer(key, direction).open(vector.sealed as SealedMessage)).toThrow();
    });
  }
});
