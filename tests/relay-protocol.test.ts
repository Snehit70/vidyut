import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { connectDevice } from "../src/relay/client";
import { createRelay } from "../src/relay/relay";
import { encryptPayload } from "../src/shared/crypto";
import { authenticateRawClient, connectRawWebSocket } from "./helpers/raw-ws-client";

const secret = "pairing-secret-for-tests";

let relay: Awaited<ReturnType<typeof createRelay>>;

beforeEach(async () => {
  relay = await createRelay({
    hostname: "127.0.0.1",
    port: 0,
    pairingSecret: secret,
    maxPayloadBytes: 1024 * 1024,
  });
});

afterEach(async () => {
  await relay.stop();
});

describe("relay protocol", () => {
  test("rejects a device that cannot prove the pairing secret", async () => {
    await expect(
      connectDevice({ url: relay.url, pairingSecret: "wrong-secret", deviceId: "phone" }),
    ).rejects.toThrow(/auth_failed/);
  });

  test("broadcasts a published payload to another paired device", async () => {
    const laptop = await connectDevice({ url: relay.url, pairingSecret: secret, deviceId: "laptop" });
    const phone = await connectDevice({ url: relay.url, pairingSecret: secret, deviceId: "phone" });

    const seen = phone.nextPayload();
    const frame = await encryptPayload(
      {
        type: "text",
        mime: "text/plain",
        origin: "laptop",
        ts: 1_800_000_000_001,
      },
      new TextEncoder().encode("hello from laptop"),
      secret,
    );

    await laptop.publish(frame);

    await expect(seen).resolves.toMatchObject({
      type: "text",
      mime: "text/plain",
      origin: "laptop",
      ts: 1_800_000_000_001,
    });

    laptop.close();
    phone.close();
  });

  test("sends the current pool payload to a paired device that joins late", async () => {
    const laptop = await connectDevice({ url: relay.url, pairingSecret: secret, deviceId: "laptop" });
    const frame = await encryptPayload(
      {
        type: "text",
        mime: "text/plain",
        origin: "laptop",
        ts: 1_800_000_000_002,
      },
      new TextEncoder().encode("latest payload"),
      secret,
    );

    await laptop.publish(frame);
    const phone = await connectDevice({ url: relay.url, pairingSecret: secret, deviceId: "phone" });

    const currentPoolPayload = await phone.nextPayload();
    expect(currentPoolPayload).toMatchObject({
      origin: "laptop",
      ts: 1_800_000_000_002,
    });

    laptop.close();
    phone.close();
  });

  test("keeps the latest payload when an older payload arrives later", async () => {
    const laptop = await connectDevice({ url: relay.url, pairingSecret: secret, deviceId: "laptop" });
    const phone = await connectDevice({ url: relay.url, pairingSecret: secret, deviceId: "phone" });

    const latest = await encryptPayload(
      {
        type: "text",
        mime: "text/plain",
        origin: "laptop",
        ts: 1_800_000_000_020,
      },
      new TextEncoder().encode("latest"),
      secret,
    );
    const older = await encryptPayload(
      {
        type: "text",
        mime: "text/plain",
        origin: "phone",
        ts: 1_800_000_000_010,
      },
      new TextEncoder().encode("older"),
      secret,
    );

    await laptop.publish(latest);
    await phone.nextPayload();
    await phone.publish(older);

    const lateJoiner = await connectDevice({ url: relay.url, pairingSecret: secret, deviceId: "tablet" });
    const currentPoolPayload = await lateJoiner.nextPayload();

    expect(currentPoolPayload).toMatchObject({ origin: "laptop", ts: 1_800_000_000_020 });

    laptop.close();
    phone.close();
    lateJoiner.close();
  });

  test("reaps a stale socket that stops answering heartbeat pings", async () => {
    await relay.stop();
    relay = await createRelay({
      hostname: "127.0.0.1",
      port: 0,
      pairingSecret: secret,
      maxPayloadBytes: 1024 * 1024,
      heartbeatIntervalMs: 50,
      staleAfterMs: 120,
    });

    // A peer that vanished (WiFi drop, killed process): TCP stays open,
    // but nothing — not even pongs — ever comes back.
    const vanished = await connectRawWebSocket(relay.url, { respondToPings: false });

    await expect(vanished.closed).resolves.toBeUndefined();
  });

  test("keeps a pong-answering device connected across stale windows", async () => {
    await relay.stop();
    relay = await createRelay({
      hostname: "127.0.0.1",
      port: 0,
      pairingSecret: secret,
      maxPayloadBytes: 1024 * 1024,
      heartbeatIntervalMs: 50,
      staleAfterMs: 120,
    });

    const phone = await connectRawWebSocket(relay.url);
    await authenticateRawClient(phone, secret, "phone");

    // Sit through several heartbeat + stale windows; pongs keep it alive.
    await Bun.sleep(400);
    expect(phone.isClosed()).toBe(false);

    // And the connection still works end-to-end: a publish is acked.
    const frame = await encryptPayload(
      {
        type: "text",
        mime: "text/plain",
        origin: "phone",
        ts: 1_800_000_000_040,
      },
      new TextEncoder().encode("still alive"),
      secret,
    );
    phone.send({ v: 1, kind: "publish", frame });
    await expect(phone.next((m) => m.kind === "ack")).resolves.toMatchObject({ kind: "ack", ts: 1_800_000_000_040 });

    phone.close();
  });

  test("counts inbound client pings as liveness", async () => {
    await relay.stop();
    relay = await createRelay({
      hostname: "127.0.0.1",
      port: 0,
      pairingSecret: secret,
      maxPayloadBytes: 1024 * 1024,
      heartbeatIntervalMs: 50,
      staleAfterMs: 120,
    });

    // A peer that never answers the relay's pings but sends its own
    // keepalive pings (the phone's 30s pingInterval): inbound pings must
    // refresh lastSeen, so it survives the stale windows.
    const phone = await connectRawWebSocket(relay.url, { respondToPings: false });
    const keepalive = setInterval(() => phone.ping(), 40);

    await Bun.sleep(400);
    clearInterval(keepalive);
    expect(phone.isClosed()).toBe(false);

    phone.close();
  });

  test("re-syncs the pool to a device that reconnects after a drop", async () => {
    const laptop = await connectDevice({ url: relay.url, pairingSecret: secret, deviceId: "laptop" });
    const phone = await connectRawWebSocket(relay.url);
    await authenticateRawClient(phone, secret, "phone");

    const frame = await encryptPayload(
      {
        type: "text",
        mime: "text/plain",
        origin: "laptop",
        ts: 1_800_000_000_050,
      },
      new TextEncoder().encode("survives reconnect"),
      secret,
    );
    await laptop.publish(frame);
    await expect(phone.next((m) => m.kind === "payload")).resolves.toMatchObject({
      kind: "payload",
      frame: { origin: "laptop", ts: 1_800_000_000_050 },
    });

    phone.close();
    const phoneAgain = await connectRawWebSocket(relay.url);
    await authenticateRawClient(phoneAgain, secret, "phone");

    await expect(phoneAgain.next((m) => m.kind === "payload")).resolves.toMatchObject({
      kind: "payload",
      frame: { origin: "laptop", ts: 1_800_000_000_050 },
    });

    laptop.close();
    phoneAgain.close();
  });

  test("rejects oversized payloads with a clear error", async () => {
    await relay.stop();
    relay = await createRelay({
      hostname: "127.0.0.1",
      port: 0,
      pairingSecret: secret,
      maxPayloadBytes: 8,
    });
    const laptop = await connectDevice({ url: relay.url, pairingSecret: secret, deviceId: "laptop" });
    const frame = await encryptPayload(
      {
        type: "text",
        mime: "text/plain",
        origin: "laptop",
        ts: 1_800_000_000_030,
      },
      new TextEncoder().encode("this payload is too large"),
      secret,
    );

    await expect(laptop.publish(frame)).rejects.toThrow(/payload_too_large/);

    laptop.close();
  });
});
