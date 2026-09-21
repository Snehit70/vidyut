import { describe, expect, test } from "bun:test";
import { connectDevice } from "../src/relay/client";
import { startClipboardSync, type WatchableClipboardAdapter } from "../src/relay/clipboard-sync";
import { PayloadPool } from "../src/relay/payload-pool";
import { createRelay, type RelayHandle } from "../src/relay/relay";
import { encryptPayload } from "../src/shared/crypto";
import type { ClipboardPayload } from "../src/relay/clipboard";
import { createCaptureLogger } from "./helpers/capture-logger";
import { authenticateRawClient, connectRawWebSocket } from "./helpers/raw-ws-client";

const secret = "pairing-secret-for-tests";

async function withRelay(
  run: (relay: RelayHandle, capture: ReturnType<typeof createCaptureLogger>) => Promise<void>,
  options: { heartbeatIntervalMs?: number; staleAfterMs?: number; maxPayloadBytes?: number } = {},
): Promise<void> {
  const capture = createCaptureLogger();
  const relay = await createRelay({
    hostname: "127.0.0.1",
    port: 0,
    pairingSecret: secret,
    maxPayloadBytes: options.maxPayloadBytes ?? 1024 * 1024,
    ...(options.heartbeatIntervalMs === undefined ? {} : { heartbeatIntervalMs: options.heartbeatIntervalMs }),
    ...(options.staleAfterMs === undefined ? {} : { staleAfterMs: options.staleAfterMs }),
    logger: capture.logger,
  });
  try {
    await run(relay, capture);
  } finally {
    await relay.stop();
  }
}

function encryptTestFrame(origin: string, ts: number, text: string, pairingSecret = secret) {
  return encryptPayload({ type: "text", mime: "text/plain", origin, ts }, new TextEncoder().encode(text), pairingSecret);
}

describe("relay observability", () => {
  test("logs the full connection story: connect, auth, publish, broadcast, disconnect", async () => {
    await withRelay(async (relay, capture) => {
      const laptop = await connectDevice({ url: relay.url, pairingSecret: secret, deviceId: "laptop" });
      const phone = await connectDevice({ url: relay.url, pairingSecret: secret, deviceId: "phone" });

      const seen = phone.nextPayload();
      const frameTs = Date.now();
      await laptop.publish(await encryptTestFrame("laptop", frameTs, "hello"));
      await seen;

      const connected = capture.named("device_connected");
      expect(connected).toHaveLength(2);
      for (const event of connected) {
        expect(event.level).toBe("info");
        expect(event.connId).toMatch(/^[0-9a-f]{8}$/);
        expect(event.remote).toMatch(/^127\.0\.0\.1:\d+$/);
      }
      expect(new Set(connected.map((event) => event.connId)).size).toBe(2);

      const authOk = capture.named("auth_ok");
      expect(authOk.map((event) => event.deviceId).sort()).toEqual(["laptop", "phone"]);
      for (const event of authOk) {
        expect(connected.map((c) => c.connId)).toContain(event.connId);
        expect(event.msSinceConnect).toBeGreaterThanOrEqual(0);
      }

      const [published] = capture.named("payload_published");
      const laptopConnId = authOk.find((event) => event.deviceId === "laptop")?.connId;
      expect(published).toMatchObject({
        level: "info",
        connId: laptopConnId,
        deviceId: "laptop",
        type: "text",
        mime: "text/plain",
        frameTs,
      });
      expect(published?.bytes).toBeGreaterThan(0);
      expect(published?.nonce).toBeString();
      expect(published?.relayLagMs).toBeGreaterThanOrEqual(0);

      expect(capture.named("payload_broadcast")).toEqual([
        expect.objectContaining({
          level: "info",
          nonce: published?.nonce,
          frameTs,
          recipients: 1,
          replay: false,
        }),
      ]);

      phone.close();
      const [disconnected] = await capture.waitFor("device_disconnected");
      expect(disconnected).toMatchObject({ level: "info", deviceId: "phone", authenticated: true });
      expect(disconnected?.durationMs).toBeGreaterThanOrEqual(0);
      expect(disconnected?.wsCode).toBeNumber();

      laptop.close();
    });
  });

  test("logs the replay to a late joiner as payload_broadcast{replay: true} after its auth_ok", async () => {
    await withRelay(async (relay, capture) => {
      const laptop = await connectDevice({ url: relay.url, pairingSecret: secret, deviceId: "laptop" });
      const frame = await encryptTestFrame("laptop", Date.now(), "replayed");
      await laptop.publish(frame);

      const phone = await connectDevice({ url: relay.url, pairingSecret: secret, deviceId: "phone" });
      await phone.nextPayload();

      const replays = capture.named("payload_broadcast").filter((event) => event.replay === true);
      expect(replays).toEqual([
        expect.objectContaining({ nonce: frame.nonce, frameTs: frame.ts, recipients: 1, replay: true }),
      ]);
      const phoneAuthIndex = capture.events.findIndex(
        (event) => event.message === "auth_ok" && event.deviceId === "phone",
      );
      expect(phoneAuthIndex).toBeGreaterThanOrEqual(0);
      expect(capture.events.indexOf(replays[0]!)).toBeGreaterThan(phoneAuthIndex);

      laptop.close();
      phone.close();
    });
  });

  test("logs a rejected proof as auth_failed{proof_rejected} plus client_error_sent", async () => {
    await withRelay(async (relay, capture) => {
      await expect(
        connectDevice({ url: relay.url, pairingSecret: "wrong-secret", deviceId: "phone" }),
      ).rejects.toThrow(/auth_failed/);

      expect(capture.named("auth_failed")).toEqual([
        expect.objectContaining({
          level: "warn",
          reason: "proof_rejected",
          connId: expect.stringMatching(/^[0-9a-f]{8}$/),
          remote: expect.stringMatching(/^127\.0\.0\.1:\d+$/),
        }),
      ]);
      expect(capture.named("client_error_sent")).toEqual([
        expect.objectContaining({ level: "warn", code: "auth_failed" }),
      ]);
    });
  });

  test("logs a non-auth first message as auth_failed{not_auth_message}", async () => {
    await withRelay(async (relay, capture) => {
      const client = await connectRawWebSocket(relay.url);
      await client.next(); // hello
      client.send({ v: 1, kind: "publish", frame: {} });
      await client.closed;

      expect(capture.named("auth_failed")).toEqual([
        expect.objectContaining({ level: "warn", reason: "not_auth_message" }),
      ]);
      expect(capture.named("client_error_sent")).toEqual([
        expect.objectContaining({ level: "warn", code: "auth_required" }),
      ]);
    });
  });

  test("logs oversized and malformed publishes as client_error_sent with the sent code", async () => {
    await withRelay(
      async (relay, capture) => {
        const laptop = await connectDevice({ url: relay.url, pairingSecret: secret, deviceId: "laptop" });
        await expect(laptop.publish(await encryptTestFrame("laptop", Date.now(), "far too large"))).rejects.toThrow(
          /payload_too_large/,
        );

        expect(capture.named("client_error_sent")).toEqual([
          expect.objectContaining({ level: "warn", deviceId: "laptop", code: "payload_too_large" }),
        ]);
        laptop.close();
      },
      { maxPayloadBytes: 8 },
    );
  });

  test("logs a stale frame as payload_stale_dropped with the winning currentTs", async () => {
    await withRelay(async (relay, capture) => {
      const laptop = await connectDevice({ url: relay.url, pairingSecret: secret, deviceId: "laptop" });
      const phone = await connectDevice({ url: relay.url, pairingSecret: secret, deviceId: "phone" });

      const latest = await encryptTestFrame("laptop", 1_800_000_000_020, "latest");
      const older = await encryptTestFrame("phone", 1_800_000_000_010, "older");
      await laptop.publish(latest);
      await phone.nextPayload();
      await phone.publish(older);

      expect(capture.named("payload_stale_dropped")).toEqual([
        expect.objectContaining({
          level: "warn",
          deviceId: "phone",
          nonce: older.nonce,
          frameTs: older.ts,
          currentTs: latest.ts,
        }),
      ]);
      expect(capture.named("payload_published")).toHaveLength(1);

      laptop.close();
      phone.close();
    });
  });

  test("logs a silent peer as socket_reaped — and as the only terminal event", async () => {
    await withRelay(
      async (relay, capture) => {
        const vanished = await connectRawWebSocket(relay.url, { respondToPings: false });
        await authenticateRawClient(vanished, secret, "phone");
        await vanished.closed;

        const [reaped] = await capture.waitFor("socket_reaped");
        expect(reaped).toMatchObject({ level: "warn", deviceId: "phone", staleAfterMs: 120 });
        expect(reaped?.idleMs).toBeGreaterThan(120);

        // terminate() may also fire the close handler; the reaped socket must
        // not get a second terminal event.
        await Bun.sleep(100);
        expect(capture.named("device_disconnected")).toHaveLength(0);
        expect(capture.named("socket_reaped")).toHaveLength(1);
      },
      { heartbeatIntervalMs: 50, staleAfterMs: 120 },
    );
  });

  test("logs a locally published frame as payload_published{origin: local}", async () => {
    await withRelay(async (relay, capture) => {
      const frame = await encryptTestFrame("laptop-device-id", Date.now(), "from local clipboard");
      await relay.pool.publish(frame, "laptop-device-id");

      expect(capture.named("payload_published")).toEqual([
        expect.objectContaining({ origin: "local", nonce: frame.nonce, frameTs: frame.ts }),
      ]);
      expect(capture.named("payload_broadcast")).toEqual([
        expect.objectContaining({ nonce: frame.nonce, recipients: 0, replay: false }),
      ]);
    });
  });
});

class FakeClipboard implements WatchableClipboardAdapter {
  payload: ClipboardPayload | undefined;
  failWrites = false;
  private onChange: (() => Promise<void> | void) | undefined;

  async read() {
    return this.payload;
  }

  async write(payload: ClipboardPayload) {
    if (this.failWrites) {
      throw new Error("wl-copy exited with code 1");
    }
    this.payload = payload;
  }

  watch(onChange: () => Promise<void> | void) {
    this.onChange = onChange;
    return () => {
      this.onChange = undefined;
    };
  }

  async changeTo(payload: ClipboardPayload) {
    this.payload = payload;
    await this.onChange?.();
  }
}

describe("clipboard sync observability", () => {
  test("logs a local clipboard change as clipboard_published", async () => {
    const capture = createCaptureLogger();
    const pool = new PayloadPool();
    const clipboard = new FakeClipboard();
    const stop = startClipboardSync({
      clipboard,
      pool,
      pairingSecret: secret,
      origin: "laptop",
      now: () => 1_800_000_020_000,
      logger: capture.logger,
    });

    await clipboard.changeTo({ type: "text", mime: "text/plain", data: new TextEncoder().encode("from laptop") });

    expect(capture.named("clipboard_published")).toEqual([
      expect.objectContaining({
        level: "info",
        type: "text",
        mime: "text/plain",
        nonce: pool.current?.nonce,
        frameTs: 1_800_000_020_000,
      }),
    ]);
    stop();
  });

  test("logs a remote frame landing on the clipboard as clipboard_write{e2eMs}", async () => {
    const capture = createCaptureLogger();
    const pool = new PayloadPool();
    const stop = startClipboardSync({
      clipboard: new FakeClipboard(),
      pool,
      pairingSecret: secret,
      origin: "laptop",
      now: () => 1_800_000_020_500,
      logger: capture.logger,
    });
    const frame = await encryptTestFrame("phone", 1_800_000_020_000, "from phone");

    await pool.publish(frame);
    await capture.waitFor("clipboard_write");

    expect(capture.named("clipboard_write")).toEqual([
      expect.objectContaining({
        level: "info",
        type: "text",
        mime: "text/plain",
        nonce: frame.nonce,
        frameTs: 1_800_000_020_000,
        e2eMs: 500,
      }),
    ]);
    expect(capture.named("clipboard_write_failed")).toHaveLength(0);
    stop();
  });

  test("logs a decrypt failure as clipboard_write_failed{stage: decrypt} instead of swallowing it", async () => {
    const capture = createCaptureLogger();
    const pool = new PayloadPool();
    const clipboard = new FakeClipboard();
    const stop = startClipboardSync({
      clipboard,
      pool,
      pairingSecret: secret,
      origin: "laptop",
      now: Date.now,
      logger: capture.logger,
    });
    const frame = await encryptTestFrame("phone", 1_800_000_021_000, "wrong key", "a-different-secret");

    await pool.publish(frame);
    await capture.waitFor("clipboard_write_failed");

    expect(capture.named("clipboard_write_failed")).toEqual([
      expect.objectContaining({
        level: "error",
        nonce: frame.nonce,
        frameTs: 1_800_000_021_000,
        stage: "decrypt",
        error: expect.any(String),
      }),
    ]);
    expect(capture.named("clipboard_write")).toHaveLength(0);
    expect(clipboard.payload).toBeUndefined();
    stop();
  });

  test("logs a clipboard write failure as clipboard_write_failed{stage: write}", async () => {
    const capture = createCaptureLogger();
    const pool = new PayloadPool();
    const clipboard = new FakeClipboard();
    clipboard.failWrites = true;
    const stop = startClipboardSync({
      clipboard,
      pool,
      pairingSecret: secret,
      origin: "laptop",
      now: Date.now,
      logger: capture.logger,
    });
    const frame = await encryptTestFrame("phone", 1_800_000_022_000, "will not land");

    await pool.publish(frame);
    await capture.waitFor("clipboard_write_failed");

    expect(capture.named("clipboard_write_failed")).toEqual([
      expect.objectContaining({
        level: "error",
        nonce: frame.nonce,
        stage: "write",
        error: "wl-copy exited with code 1",
      }),
    ]);
    expect(capture.named("clipboard_write")).toHaveLength(0);
    stop();
  });
});
