import { describe, expect, test } from "bun:test";
import {
  startClipboardSync,
  type ClipboardHealth,
  type WatchableClipboardAdapter,
} from "../src/relay/clipboard-sync";
import { connectDevice } from "../src/relay/client";
import { PayloadPool } from "../src/relay/payload-pool";
import { createRelay } from "../src/relay/relay";
import { decryptAlternative, decryptPayload, encryptPayload } from "../src/shared/crypto";
import type { ClipboardPayload } from "../src/relay/clipboard";

class FakeClipboard implements WatchableClipboardAdapter {
  payload: ClipboardPayload | undefined;
  writes: ClipboardPayload[] = [];
  private onChange: (() => Promise<void> | void) | undefined;
  private onReady: (() => void) | undefined;
  private onFailure: ((error: Error) => void) | undefined;

  async read() {
    return this.payload;
  }

  async write(payload: ClipboardPayload): Promise<ClipboardPayload | void> {
    this.writes.push(payload);
    this.payload = payload;
  }

  watch(
    onChange: () => Promise<void> | void,
    onReady?: () => void,
    onFailure?: (error: Error) => void,
  ) {
    this.onChange = onChange;
    this.onReady = onReady;
    this.onFailure = onFailure;
    return () => {
      this.onChange = undefined;
      this.onReady = undefined;
      this.onFailure = undefined;
    };
  }

  async changeTo(payload: ClipboardPayload) {
    this.payload = payload;
    await this.onChange?.();
  }

  becomeReady() {
    this.onReady?.();
  }

  fail(error: Error) {
    this.onFailure?.(error);
  }
}

describe("clipboard sync", () => {
  test("publishes local clipboard changes into the encrypted pool", async () => {
    const pool = new PayloadPool();
    const clipboard = new FakeClipboard();
    const stop = startClipboardSync({
      clipboard,
      pool,
      pairingSecret: "pairing-secret",
      origin: "laptop",
      now: () => 1_800_000_020_000,
    });

    await clipboard.changeTo({
      type: "text",
      mime: "text/plain",
      data: new TextEncoder().encode("from laptop"),
    });

    expect(pool.current).toMatchObject({
      type: "text",
      mime: "text/plain",
      origin: "laptop",
      ts: 1_800_000_020_000,
    });
    expect(await decryptPayload(pool.current!, "pairing-secret")).toEqual(new TextEncoder().encode("from laptop"));

    stop();
  });

  test("publishes a copy's formatting alongside its plain text", async () => {
    const pool = new PayloadPool();
    const clipboard = new FakeClipboard();
    const stop = startClipboardSync({
      clipboard,
      pool,
      pairingSecret: "pairing-secret",
      origin: "laptop",
      now: () => 1_800_000_020_001,
    });

    await clipboard.changeTo({
      type: "text",
      mime: "text/plain",
      data: new TextEncoder().encode("bold"),
      alternative: { mime: "text/html", data: new TextEncoder().encode("<b>bold</b>") },
    });

    const frame = pool.current!;
    expect(await decryptPayload(frame, "pairing-secret")).toEqual(new TextEncoder().encode("bold"));
    expect(frame.alt?.mime).toBe("text/html");
    expect(await decryptAlternative(frame, frame.alt!, "pairing-secret")).toEqual(
      new TextEncoder().encode("<b>bold</b>"),
    );

    stop();
  });

  test("writes incoming device payloads into the laptop clipboard", async () => {
    const pool = new PayloadPool();
    const clipboard = new FakeClipboard();
    const stop = startClipboardSync({
      clipboard,
      pool,
      pairingSecret: "pairing-secret",
      origin: "laptop",
      now: () => 1_800_000_020_001,
    });
    const frame = await encryptPayload(
      { type: "image", mime: "image/png", origin: "phone", ts: 1_800_000_020_002 },
      new Uint8Array([137, 80, 78, 71]),
      "pairing-secret",
    );

    await pool.publish(frame);
    await waitUntil(() => clipboard.writes.length === 1, "clipboard write");

    expect(clipboard.writes).toEqual([
      {
        type: "image",
        mime: "image/png",
        data: new Uint8Array([137, 80, 78, 71]),
      },
    ]);

    stop();
  });

  test("neither publishes nor writes while paused, and syncs again after", async () => {
    const pool = new PayloadPool();
    const clipboard = new FakeClipboard();
    let paused = true;
    const stop = startClipboardSync({
      clipboard,
      pool,
      pairingSecret: "pairing-secret",
      origin: "laptop",
      now: () => 1_800_000_020_020,
      isPaused: () => paused,
    });
    const text = (value: string): ClipboardPayload => ({
      type: "text",
      mime: "text/plain",
      data: new TextEncoder().encode(value),
    });

    await clipboard.changeTo(text("private"));
    await pool.publish(
      await encryptPayload(
        { type: "text", mime: "text/plain", origin: "phone", ts: 1_800_000_020_019 },
        new TextEncoder().encode("from phone"),
        "pairing-secret",
      ),
    );
    await Bun.sleep(5);
    expect(clipboard.writes).toEqual([]);
    expect(pool.current?.origin).toBe("phone");

    paused = false;
    await clipboard.changeTo(text("shared"));
    expect(pool.current?.origin).toBe("laptop");
    expect(await decryptPayload(pool.current!, "pairing-secret")).toEqual(new TextEncoder().encode("shared"));

    stop();
  });

  test("drops the change its own incoming write provokes, by content", async () => {
    const pool = new PayloadPool();
    const clipboard = new FakeClipboard();
    const stop = startClipboardSync({
      clipboard,
      pool,
      pairingSecret: "pairing-secret",
      origin: "laptop",
      now: () => 1_800_000_020_010,
    });
    const frame = await encryptPayload(
      { type: "text", mime: "text/plain", origin: "phone", ts: 1_800_000_020_005 },
      new TextEncoder().encode("from phone"),
      "pairing-secret",
    );
    await pool.publish(frame);
    await waitUntil(() => clipboard.writes.length === 1, "clipboard write");

    // wl-paste --watch reports the write: same bytes, so it is not republished.
    await clipboard.changeTo(clipboard.writes[0]!);
    expect(pool.current?.nonce).toBe(frame.nonce);

    // The user then copies something else; that publishes.
    await clipboard.changeTo({
      type: "text",
      mime: "text/plain",
      data: new TextEncoder().encode("typed on laptop"),
    });
    expect(pool.current?.origin).toBe("laptop");
    stop();
  });

  test("a write that never fires the watcher does not swallow the next real copy", async () => {
    const pool = new PayloadPool();
    const clipboard = new FakeClipboard();
    const stop = startClipboardSync({
      clipboard,
      pool,
      pairingSecret: "pairing-secret",
      origin: "laptop",
      now: () => 1_800_000_020_020,
    });
    await pool.publish(
      await encryptPayload(
        { type: "text", mime: "text/plain", origin: "phone", ts: 1_800_000_020_015 },
        new TextEncoder().encode("from phone"),
        "pairing-secret",
      ),
    );
    await waitUntil(() => clipboard.writes.length === 1, "clipboard write");

    await clipboard.changeTo({
      type: "text",
      mime: "text/plain",
      data: new TextEncoder().encode("a different copy"),
    });
    expect(pool.current?.origin).toBe("laptop");
    stop();
  });

  test("recognises an image echo after the write re-encoded it to PNG", async () => {
    const pool = new PayloadPool();
    const png = new Uint8Array([137, 80, 78, 71, 1]);
    const clipboard = new (class extends FakeClipboard {
      override async write(payload: ClipboardPayload) {
        await super.write(payload);
        this.payload = { type: "image", mime: "image/png", data: png };
        return this.payload;
      }
    })();
    const stop = startClipboardSync({
      clipboard,
      pool,
      pairingSecret: "pairing-secret",
      origin: "laptop",
      now: () => 1_800_000_020_030,
    });
    const frame = await encryptPayload(
      { type: "image", mime: "image/jpeg", origin: "phone", ts: 1_800_000_020_031 },
      new Uint8Array([255, 216, 255]),
      "pairing-secret",
    );
    await pool.publish(frame);
    await waitUntil(() => clipboard.writes.length === 1, "clipboard write");

    await clipboard.changeTo({ type: "image", mime: "image/png", data: png });
    expect(pool.current?.nonce).toBe(frame.nonce);
    stop();
  });

  test("reports watcher readiness and degradation", () => {
    const pool = new PayloadPool();
    const clipboard = new FakeClipboard();
    const health: ClipboardHealth[] = [];
    const stop = startClipboardSync({
      clipboard,
      pool,
      pairingSecret: "pairing-secret",
      origin: "laptop",
      now: Date.now,
      onHealthChange: (next) => health.push(next),
    });

    clipboard.becomeReady();
    clipboard.fail(new Error("wl-paste --watch failed: unsupported protocol"));

    expect(health).toEqual([
      { enabled: true, status: "healthy", watcher: "wl-paste --watch" },
      {
        enabled: true,
        status: "degraded",
        watcher: "wl-paste --watch",
        error: "wl-paste --watch failed: unsupported protocol",
      },
    ]);
    stop();
  });

  test("keeps publishing local changes after a clipboard read throws", async () => {
    const pool = new PayloadPool();
    const clipboard = new FakeClipboard();
    let reads = 0;
    clipboard.read = async () => {
      reads += 1;
      if (reads === 1) throw new Error("wl-paste --list-types hung then failed");
      return clipboard.payload;
    };
    const stop = startClipboardSync({
      clipboard,
      pool,
      pairingSecret: "pairing-secret",
      origin: "laptop",
      now: () => 1_800_000_020_000 + reads,
    });

    await clipboard.changeTo({
      type: "text",
      mime: "text/plain",
      data: new TextEncoder().encode("first copy dies"),
    });
    expect(pool.current).toBeUndefined();

    await clipboard.changeTo({
      type: "text",
      mime: "text/plain",
      data: new TextEncoder().encode("second copy lives"),
    });
    expect(await decryptPayload(pool.current!, "pairing-secret")).toEqual(
      new TextEncoder().encode("second copy lives"),
    );

    stop();
  });

  test("a hung laptop clipboard write does not block the phone's publish ack", async () => {
    const relay = await createRelay({
      hostname: "127.0.0.1",
      port: 0,
      pairingSecret: "pairing-secret",
      maxPayloadBytes: 1024 * 1024,
    });
    const clipboard = new FakeClipboard();
    let releaseWrite = () => {};
    clipboard.write = () => new Promise<void>((resolve) => {
      releaseWrite = () => resolve();
    });
    const stop = startClipboardSync({
      clipboard,
      pool: relay.pool,
      pairingSecret: "pairing-secret",
      origin: "laptop",
      now: Date.now,
    });
    const phone = await connectDevice({
      url: relay.url,
      pairingSecret: "pairing-secret",
      deviceId: "phone",
    });
    const frame = await encryptPayload(
      { type: "text", mime: "text/plain", origin: "phone", ts: Date.now() },
      new TextEncoder().encode("from phone"),
      "pairing-secret",
    );

    const outcome = await Promise.race([
      phone.publish(frame).then(() => "acked" as const),
      Bun.sleep(500).then(() => "hung" as const),
    ]);

    releaseWrite();
    phone.close();
    stop();
    await relay.stop();

    expect(outcome).toBe("acked");
  });
});

async function waitUntil(predicate: () => boolean, label: string): Promise<void> {
  const deadline = Date.now() + 1000;
  while (!predicate() && Date.now() < deadline) {
    await Bun.sleep(1);
  }
  if (!predicate()) throw new Error(`timed out waiting for ${label}`);
}
