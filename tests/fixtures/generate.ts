// Regenerates crypto-fixtures.json from the TypeScript implementation:
//   bun tests/fixtures/generate.ts
// The Dart suite (app/test/crypto_fixtures_test.dart) verifies the same bytes,
// so both languages must agree on KDF, AAD encoding, nonce, and tag layout.
import { createPairingProof } from "../../src/shared/auth";
import { encryptAlternative, encryptPayload } from "../../src/shared/crypto";
import {
  createRelayProof,
  deriveSessionKey,
  SessionSealer,
  type SealDirection,
} from "../../src/shared/session-seal";
import type { PayloadMetadata, RelayMessage } from "../../src/shared/wire";

interface PayloadVectorInput {
  name: string;
  pairingSecret: string;
  metadata: PayloadMetadata;
  plaintext: Uint8Array;
  nonce: Uint8Array;
}

function nonceOf(seed: number): Uint8Array {
  return new Uint8Array(Array.from({ length: 12 }, (_, i) => (seed + i) & 0xff));
}

const payloadInputs: PayloadVectorInput[] = [
  {
    name: "text-ascii",
    pairingSecret: "fixture-secret-1",
    metadata: { type: "text", mime: "text/plain", origin: "laptop", ts: 1_800_000_000_001 },
    plaintext: new TextEncoder().encode("clipboard text fixture"),
    nonce: nonceOf(1),
  },
  {
    name: "image-binary",
    pairingSecret: "fixture-secret-2",
    metadata: { type: "image", mime: "image/png", origin: "phone", ts: 1_800_000_000_002 },
    plaintext: new Uint8Array(Array.from({ length: 256 }, (_, i) => i)),
    nonce: nonceOf(50),
  },
  {
    name: "text-unicode",
    pairingSecret: "paîring-🔑-secret",
    metadata: { type: "text", mime: "text/plain", origin: "laptop-α-📎", ts: 1_800_000_000_003 },
    plaintext: new TextEncoder().encode("unicode clipboard 📋 ✓ ñ"),
    nonce: nonceOf(100),
  },
  {
    name: "empty-plaintext",
    pairingSecret: "fixture-secret-1",
    metadata: { type: "text", mime: "text/plain", origin: "laptop", ts: 1_800_000_000_004 },
    plaintext: new Uint8Array(0),
    nonce: nonceOf(150),
  },
];

const proofInputs = [
  {
    name: "proof-ascii",
    pairingSecret: "fixture-secret-1",
    challenge: "challenge-123",
    deviceId: "device-abc",
  },
  {
    name: "proof-unicode",
    pairingSecret: "paîring-🔑-secret",
    challenge: "chällenge-456",
    deviceId: "phone-📱",
  },
];

const payloadVectors = await Promise.all(
  payloadInputs.map(async (input) => ({
    name: input.name,
    pairingSecret: input.pairingSecret,
    plaintextBase64: Buffer.from(input.plaintext).toString("base64"),
    frame: await encryptPayload(input.metadata, input.plaintext, input.pairingSecret, input.nonce),
  })),
);

// A text frame carrying its HTML formatting as a separately sealed alternative.
const alternativeInputs = [
  {
    name: "html-alternative",
    pairingSecret: "fixture-secret-1",
    metadata: { type: "text", mime: "text/plain", origin: "laptop", ts: 1_800_000_000_005 } as PayloadMetadata,
    plaintext: new TextEncoder().encode("bold ✓"),
    nonce: nonceOf(200),
    html: new TextEncoder().encode("<b>bold</b> ✓"),
    altNonce: nonceOf(220),
  },
];

const alternativeVectors = await Promise.all(
  alternativeInputs.map(async (input) => {
    const frame = await encryptPayload(input.metadata, input.plaintext, input.pairingSecret, input.nonce);
    frame.alt = await encryptAlternative(frame, "text/html", input.html, input.pairingSecret, input.altNonce);
    return {
      name: input.name,
      pairingSecret: input.pairingSecret,
      plaintextBase64: Buffer.from(input.plaintext).toString("base64"),
      altPlaintextBase64: Buffer.from(input.html).toString("base64"),
      frame,
    };
  }),
);

const pairingProofVectors = await Promise.all(
  proofInputs.map(async (input) => ({
    ...input,
    proofBase64: await createPairingProof(input.pairingSecret, input.challenge, input.deviceId),
  })),
);

const sessionInputs = [
  {
    name: "session-ascii",
    pairingSecret: "fixture-secret-1",
    challenge: "cmVsYXktY2hhbGxlbmdlLWJ5dGVzLTEyMzQ=",
    clientChallenge: "cGhvbmUtY2hhbGxlbmdlLWJ5dGVzLTU2Nzg=",
    deviceId: "phone",
    sessionFeatures: ["sealed_control"],
  },
  {
    name: "session-unicode-no-features",
    pairingSecret: "paîring-🔑-secret",
    challenge: "AAECAwQFBgcICQoLDA0ODxAREhMUFRYX",
    clientChallenge: "GBkaGxwdHh8gISIjJCUmJygpKissLS4v",
    deviceId: "phone-📱:2",
    sessionFeatures: [] as string[],
  },
];

const sessionVectors = sessionInputs.map((input) => ({
  ...input,
  relayProofBase64: createRelayProof(
    input.pairingSecret,
    input.challenge,
    input.clientChallenge,
    input.sessionFeatures,
    input.deviceId,
  ),
  sessionKeyBase64: Buffer.from(
    deriveSessionKey(input.pairingSecret, input.challenge, input.clientChallenge, input.deviceId),
  ).toString("base64"),
}));

// Each vector is the `index`-th message one side seals in a session, so the
// counter in the nonce is exercised past zero.
const sealInputs: Array<{ name: string; direction: SealDirection; index: number; message: RelayMessage }> = [
  {
    name: "relay-telemetry-first",
    direction: "relay_to_phone",
    index: 0,
    message: {
      v: 1,
      kind: "telemetry",
      ts: 1_800_000_000_100,
      batteryPercent: 81,
      batteryState: "charging",
      memoryUsedBytes: 1024,
      memoryTotalBytes: 4096,
      storageUsedBytes: null,
      storageTotalBytes: null,
      cpuUsagePercent: 12.5,
      cpuTemperatureCelsius: null,
    },
  },
  {
    name: "phone-transfer-third",
    direction: "phone_to_relay",
    index: 2,
    message: {
      v: 1,
      kind: "transfer_progress",
      transferId: "transfer-ü-1",
      fileId: "file-1",
      confirmedOffset: 65536,
    },
  },
];

const sessionKey = deriveSessionKey(
  sessionInputs[0]!.pairingSecret,
  sessionInputs[0]!.challenge,
  sessionInputs[0]!.clientChallenge,
  sessionInputs[0]!.deviceId,
);
const sealVectors = sealInputs.map((input) => {
  const sealer = new SessionSealer(sessionKey, input.direction);
  let sealed = sealer.seal(input.message);
  for (let i = 0; i < input.index; i++) sealed = sealer.seal(input.message);
  return {
    name: input.name,
    sessionKeyBase64: Buffer.from(sessionKey).toString("base64"),
    direction: input.direction,
    index: input.index,
    plaintextJson: JSON.stringify(input.message),
    sealed,
  };
});

const outPath = new URL("crypto-fixtures.json", import.meta.url).pathname;
await Bun.write(
  outPath,
  `${JSON.stringify({ payloadVectors, alternativeVectors, pairingProofVectors, sessionVectors, sealVectors }, null, 2)}\n`,
);
console.log(`wrote ${outPath}`);
