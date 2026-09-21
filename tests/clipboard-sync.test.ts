import { describe, expect, test } from "bun:test";
import {
  startClipboardSync,
  type ClipboardHealth,
  type WatchableClipboardAdapter,
} from "../src/relay/clipboard-sync";
import { connectDevice } from "../src/relay/client";
import { PayloadPool } from "../src/relay/payload-pool";
import { createRelay } from "../src/relay/relay";
import { decryptPayload, encryptPayload } from "../src/shared/crypto";
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

  async write(payload: ClipboardPayload) {
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
