import { afterEach, describe, expect, test } from "bun:test";
import { createRelay } from "../src/relay/relay";
import type {
  TransferControlMessage,
  TransferOffer,
} from "../src/shared/wire";
import {
  authenticateRawClient,
  connectRawWebSocket,
} from "./helpers/raw-ws-client";

const secret = "pairing-secret-for-transfer-tests";
const offer: TransferOffer = {
  transferId: "transfer_1234567890",
  batchId: "batch_123456789012",
  origin: "phone",
  direction: "phone_to_laptop",
  createdAtMs: 1_753_689_600_000,
  files: [
    {
      fileId: "file_1234567890123",
      filename: "report.pdf",
      mime: "application/pdf",
      size: 42,
      lastModifiedMs: 1_753_689_500_000,
      sha256: "a".repeat(64),
    },
  ],
};

let relay: Awaited<ReturnType<typeof createRelay>> | undefined;

afterEach(async () => {
  await relay?.stop();
  relay = undefined;
});

describe("relay transfer control", () => {
  test("delivers phone control to the local transfer module", async () => {
    const seen: Array<{
      message: TransferControlMessage;
      sourceDeviceId: string;
    }> = [];
    relay = await createRelay({
      hostname: "127.0.0.1",
      port: 0,
      pairingSecret: secret,
      maxPayloadBytes: 1024,
      transferControl(message, sourceDeviceId) {
        seen.push({ message, sourceDeviceId });
      },
    });
    const phone = await connectRawWebSocket(relay.url);
    await authenticateRawClient(phone, secret, "phone");

    phone.send({ v: 1, kind: "transfer_offer", offer });
    await Bun.sleep(10);

    expect(seen).toEqual([
      {
        message: { v: 1, kind: "transfer_offer", offer },
        sourceDeviceId: "phone",
      },
    ]);
    phone.close();
  });

  test("routes local receiver control to the authenticated phone", async () => {
    relay = await createRelay({
      hostname: "127.0.0.1",
      port: 0,
      pairingSecret: secret,
      maxPayloadBytes: 1024,
    });
    const phone = await connectRawWebSocket(relay.url);
    await authenticateRawClient(phone, secret, "phone");

    relay.publishTransferControl({
      v: 1,
      kind: "transfer_accept",
      transferId: offer.transferId,
      fileId: offer.files[0]!.fileId,
      confirmedOffset: 0,
    });

    await expect(phone.next()).resolves.toEqual({
      v: 1,
      kind: "transfer_accept",
      transferId: offer.transferId,
      fileId: offer.files[0]!.fileId,
      confirmedOffset: 0,
    });
    phone.close();
  });

  test("rejects malformed transfer control before the module sees it", async () => {
    let calls = 0;
    relay = await createRelay({
      hostname: "127.0.0.1",
      port: 0,
      pairingSecret: secret,
      maxPayloadBytes: 1024,
      transferControl() {
        calls++;
      },
    });
    const phone = await connectRawWebSocket(relay.url);
    await authenticateRawClient(phone, secret, "phone");

    phone.send({
      v: 1,
      kind: "transfer_offer",
      offer: {
        ...offer,
        files: [{ ...offer.files[0], filename: "../secret" }],
      },
    });

    await expect(phone.next()).resolves.toMatchObject({
      kind: "error",
      code: "bad_message",
    });
    expect(calls).toBe(0);
    phone.close();
  });
});
