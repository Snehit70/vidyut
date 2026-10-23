import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { connectDevice } from "../src/relay/client";
import { createRelay } from "../src/relay/relay";
import { createAuthMessage } from "../src/shared/auth";
import { encryptPayload } from "../src/shared/crypto";
import {
  deriveSessionKey,
  SessionSealer,
  verifyRelayProof,
} from "../src/shared/session-seal";
import type { RelayMessage } from "../src/shared/wire";
import {
  authenticateRawClient,
  connectRawWebSocket,
  type RawWebSocketClient,
} from "./helpers/raw-ws-client";

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

  test("accepts payloads past Bun's 16 MiB default message cap", async () => {
    await relay.stop();
    const maxPayloadBytes = 20 * 1024 * 1024;
    relay = await createRelay({
      hostname: "127.0.0.1",
      port: 0,
      pairingSecret: secret,
      maxPayloadBytes,
    });
    const laptop = await connectDevice({ url: relay.url, pairingSecret: secret, deviceId: "laptop" });
    const metadata = { type: "image" as const, mime: "image/png", origin: "laptop" };
    // 18 MiB of ciphertext is ~24 MiB of base64 on the wire.
    const fits = await encryptPayload(
      { ...metadata, ts: 1_800_000_000_040 },
      new Uint8Array(18 * 1024 * 1024),
      secret,
    );
    await expect(laptop.publish(fits)).resolves.toBeUndefined();

    const over = await encryptPayload(
      { ...metadata, ts: 1_800_000_000_041 },
      new Uint8Array(maxPayloadBytes + 1024),
      secret,
    );
    await expect(laptop.publish(over)).rejects.toThrow(/payload_too_large/);

    laptop.close();
  });

  test("closes a socket that never authenticates", async () => {
    await relay.stop();
    relay = await createRelay({
      hostname: "127.0.0.1",
      port: 0,
      pairingSecret: secret,
      maxPayloadBytes: 1024,
      authTimeoutMs: 50,
    });
    const socket = new WebSocket(relay.url);
    const closed = await new Promise<{ code: number; reason: string }>((resolve) => {
      socket.addEventListener("close", (event) => resolve({ code: event.code, reason: event.reason }));
    });
    expect(closed).toEqual({ code: 1008, reason: "auth_timeout" });

    // An authenticated device outlives the deadline.
    const laptop = await connectDevice({ url: relay.url, pairingSecret: secret, deviceId: "laptop" });
    await Bun.sleep(120);
    const frame = await encryptPayload(
      { type: "text", mime: "text/plain", origin: "laptop", ts: 1_800_000_000_050 },
      new TextEncoder().encode("hi"),
      secret,
    );
    await expect(laptop.publish(frame)).resolves.toBeUndefined();
    laptop.close();
  });

  test("orders a phone's frame on the relay clock, not the phone's", async () => {
    const hour = 60 * 60 * 1000;
    const phone = await connectRawWebSocket(relay.url);
    await authenticateRawClient(phone, secret, "phone");
    const text = (value: string) => new TextEncoder().encode(value);
    const publishFromPhone = async (copiedAt: number, sentAt: number) => {
      const frame = await encryptPayload(
        { type: "text", mime: "text/plain", origin: "phone", ts: copiedAt },
        text(`phone ${copiedAt}`),
        secret,
      );
      phone.send({ v: 1, kind: "publish", frame, sentAt });
      return phone.next((message) => message.kind === "ack");
    };

    // Phone clock an hour ahead. It copied 10s before the laptop did but the
    // frame arrives after: the laptop's newer copy must win.
    await relay.pool.publish(
      await encryptPayload(
        { type: "text", mime: "text/plain", origin: "laptop", ts: Date.now() },
        text("laptop"),
        secret,
      ),
      "laptop",
    );
    const aheadNow = Date.now() + hour;
    expect(await publishFromPhone(aheadNow - 10_000, aheadNow)).toMatchObject({
      kind: "ack",
      stale: true,
    });
    expect(relay.pool.current?.origin).toBe("laptop");

    // Phone clock an hour behind. It copied after the laptop: it must win even
    // though its ts is an hour older than the laptop's.
    const behindNow = Date.now() - hour;
    const ack = await publishFromPhone(behindNow, behindNow);
    expect(ack).toMatchObject({ kind: "ack", ts: behindNow });
    expect(ack).not.toHaveProperty("stale");
    expect(relay.pool.current?.origin).toBe("phone");

    phone.close();
  });

  test("sends telemetry only to phones that asked for it", async () => {
    await relay.stop();
    let samples = 0;
    relay = await createRelay({
      hostname: "127.0.0.1",
      port: 0,
      pairingSecret: secret,
      maxPayloadBytes: 1024,
      telemetry: async () => ({
        v: 1,
        kind: "telemetry",
        ts: ++samples,
        batteryPercent: null,
        batteryState: null,
        memoryUsedBytes: null,
        memoryTotalBytes: null,
        storageUsedBytes: null,
        storageTotalBytes: null,
        cpuUsagePercent: null,
        cpuTemperatureCelsius: null,
      }),
    });

    const phone = await connectRawWebSocket(relay.url);
    const hello = await phone.next();
    if (hello.kind !== "hello") throw new Error("expected hello");
    expect(hello.features).toContain("telemetry_subscribe");
    phone.send({
      ...(await createAuthMessage(secret, hello.challenge, "phone")),
      features: ["telemetry_subscribe"],
    });
    await phone.next((message) => message.kind === "auth_ok");
    await Bun.sleep(50);
    expect(samples).toBe(0);

    phone.send({ v: 1, kind: "telemetry_subscribe", active: true });
    expect(await phone.next((message) => message.kind === "telemetry")).toMatchObject({ ts: 1 });

    // A phone that predates the feature keeps the always-on stream.
    const legacy = await connectRawWebSocket(relay.url);
    await authenticateRawClient(legacy, secret, "legacy");
    expect(await legacy.next((message) => message.kind === "telemetry")).toMatchObject({
      kind: "telemetry",
    });

    phone.close();
    legacy.close();
  });

  describe("mutual auth and sealed control", () => {
    async function sealedPhone(deviceId = "phone") {
      const phone = await connectRawWebSocket(relay.url);
      const hello = await phone.next();
      if (hello.kind !== "hello") throw new Error("expected hello");
      expect(hello.features).toEqual(expect.arrayContaining(["relay_proof", "sealed_control"]));
      const clientChallenge = Buffer.from(crypto.getRandomValues(new Uint8Array(24))).toString("base64");
      phone.send({
        ...(await createAuthMessage(secret, hello.challenge, deviceId)),
        clientChallenge,
        features: ["telemetry_subscribe", "sealed_control"],
      });
      const authOk = await phone.next((message) => message.kind === "auth_ok");
      if (authOk.kind !== "auth_ok") throw new Error("expected auth_ok");
      const sealer = new SessionSealer(
        deriveSessionKey(secret, hello.challenge, clientChallenge, deviceId),
        "phone_to_relay",
      );
      return { phone, sealer, authOk, challenge: hello.challenge, clientChallenge };
    }

    async function nextOpened(phone: RawWebSocketClient, sealer: SessionSealer): Promise<RelayMessage> {
      const sealed = await phone.next((message) => message.kind === "sealed");
      if (sealed.kind !== "sealed") throw new Error("expected sealed");
      return sealer.open(sealed);
    }

    test("proves the relay holds the secret, over the negotiated features", async () => {
      const { phone, authOk, challenge, clientChallenge } = await sealedPhone();

      expect(authOk.features).toEqual(["sealed_control"]);
      expect(
        verifyRelayProof(secret, challenge, clientChallenge, ["sealed_control"], "phone", authOk.relayProof ?? ""),
      ).toBe(true);
      // Stripping the feature in transit would not survive the proof.
      expect(
        verifyRelayProof(secret, challenge, clientChallenge, [], "phone", authOk.relayProof ?? ""),
      ).toBe(false);
      expect(
        verifyRelayProof("other-secret", challenge, clientChallenge, ["sealed_control"], "phone", authOk.relayProof ?? ""),
      ).toBe(false);
      phone.close();
    });

    test("seals control both ways and leaves payload frames as they are", async () => {
      const { phone, sealer } = await sealedPhone();

      phone.send(sealer.seal({ v: 1, kind: "telemetry_subscribe", active: true }));
      expect(await nextOpened(phone, sealer)).toMatchObject({ kind: "telemetry" });

      const frame = await encryptPayload(
        { type: "text", mime: "text/plain", origin: "phone", ts: Date.now() },
        new TextEncoder().encode("sealed session"),
        secret,
      );
      phone.send({ v: 1, kind: "publish", frame });
      expect(await nextOpened(phone, sealer)).toEqual({ v: 1, kind: "ack", ts: frame.ts });

      relay.publishHealth();
      expect(await nextOpened(phone, sealer)).toMatchObject({ kind: "health" });

      const other = await connectRawWebSocket(relay.url);
      await authenticateRawClient(other, secret, "laptop-tool");
      const fromOther = await encryptPayload(
        { type: "text", mime: "text/plain", origin: "laptop", ts: Date.now() + 1 },
        new TextEncoder().encode("to the phone"),
        secret,
      );
      other.send({ v: 1, kind: "publish", frame: fromOther });
      expect(await phone.next((message) => message.kind === "payload")).toEqual({
        v: 1,
        kind: "payload",
        frame: fromOther,
      });
      phone.close();
      other.close();
    });

    test("ends a sealed session on an unsealed control message", async () => {
      const { phone } = await sealedPhone();

      phone.send({ v: 1, kind: "telemetry_subscribe", active: true });

      await phone.closed;
      expect(phone.isClosed()).toBe(true);
    });

    test("ends a sealed session on a replayed message", async () => {
      const { phone, sealer } = await sealedPhone();
      const subscribe = sealer.seal({ v: 1, kind: "telemetry_subscribe", active: false });

      phone.send(subscribe);
      phone.send(subscribe);

      await phone.closed;
      expect(phone.isClosed()).toBe(true);
    });

    test("keeps the one-way handshake for a phone without a client challenge", async () => {
      const legacy = await connectRawWebSocket(relay.url);
      await authenticateRawClient(legacy, secret, "legacy");

      relay.publishHealth();
      expect(await legacy.next((message) => message.kind === "health")).toMatchObject({ kind: "health" });
      legacy.close();
    });
  });
});
