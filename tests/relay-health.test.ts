import { describe, expect, test } from "bun:test";
import { connectDevice } from "../src/relay/client";
import { createRelay, type RelayHandle } from "../src/relay/relay";
import { encryptPayload } from "../src/shared/crypto";

const secret = "pairing-secret-for-tests";

async function withRelay(run: (relay: RelayHandle) => Promise<void>): Promise<void> {
  const relay = await createRelay({
    hostname: "127.0.0.1",
    port: 0,
    pairingSecret: secret,
    maxPayloadBytes: 1024 * 1024,
  });
  try {
    await run(relay);
  } finally {
    await relay.stop();
  }
}

async function fetchHealth(relay: RelayHandle): Promise<Record<string, any>> {
  const response = await fetch(`${relay.url.replace("ws://", "http://")}/health`);
  expect(response.status).toBe(200);
  return (await response.json()) as Record<string, any>;
}

describe("relay /health", () => {
  test("reports ok with no devices and an empty pool", async () => {
    await withRelay(async (relay) => {
      const health = await fetchHealth(relay);

      expect(health.status).toBe("ok");
      expect(health.uptimeSeconds).toBeGreaterThanOrEqual(0);
      expect(health.devices).toEqual([]);
      expect(health.pool).toBeNull();
    });
  });

  test("lists authenticated devices and the current pool payload", async () => {
    await withRelay(async (relay) => {
      const phone = await connectDevice({ url: relay.url, pairingSecret: secret, deviceId: "phone" });
      const frame = await encryptPayload(
        { type: "text", mime: "text/plain", origin: "phone", ts: Date.now() },
        new TextEncoder().encode("hello"),
        secret,
      );
      await phone.publish(frame);

      const health = await fetchHealth(relay);

      expect(health.devices).toHaveLength(1);
      const device = health.devices[0];
      expect(device.deviceId).toBe("phone");
      expect(device.remote).toMatch(/^127\.0\.0\.1:\d+$/);
      expect(device.connectedSeconds).toBeGreaterThanOrEqual(0);
      expect(device.lastSeenSecondsAgo).toBeGreaterThanOrEqual(0);

      expect(health.pool).toEqual({
        type: "text",
        mime: "text/plain",
        bytes: expect.any(Number),
        origin: "phone",
        ageSeconds: expect.any(Number),
      });
      // Identity and age only: the payload body must never leak.
      expect(JSON.stringify(health)).not.toContain(frame.payload);
    });
  });

  test("excludes connected-but-unauthenticated sockets", async () => {
    await withRelay(async (relay) => {
      const socket = new WebSocket(relay.url);
      await new Promise((resolve) => socket.addEventListener("open", resolve));

      const health = await fetchHealth(relay);

      expect(health.devices).toEqual([]);
      socket.close();
    });
  });

  test("other paths still answer with the banner", async () => {
    await withRelay(async (relay) => {
      const response = await fetch(relay.url.replace("ws://", "http://"));
      expect(await response.text()).toBe("Vidyut relay");
    });
  });

  test("reports degraded while the network relay remains available when clipboard watch fails", async () => {
    const relay = await createRelay({
      hostname: "127.0.0.1",
      port: 0,
      pairingSecret: secret,
      maxPayloadBytes: 1024 * 1024,
      clipboardHealth: () => ({
        enabled: true,
        status: "degraded",
        watcher: "wl-paste --watch",
        error: "wl-paste --watch failed: unsupported protocol",
      }),
    });
    try {
      const health = await fetchHealth(relay);

      expect(health.status).toBe("degraded");
      expect(health.clipboard).toEqual({
        enabled: true,
        status: "degraded",
        watcher: "wl-paste --watch",
        error: "wl-paste --watch failed: unsupported protocol",
      });
      expect(await (await fetch(relay.url.replace("ws://", "http://"))).text()).toBe("Vidyut relay");
    } finally {
      await relay.stop();
    }
  });

  test("sends relay identity and health after authentication", async () => {
    const relay = await createRelay({
      hostname: "127.0.0.1",
      port: 0,
      pairingSecret: secret,
      maxPayloadBytes: 1024 * 1024,
      relayName: "framework",
      clipboardHealth: () => ({
        enabled: true,
        status: "healthy",
        watcher: "wl-paste --watch",
      }),
    });
    try {
      const socket = new WebSocket(relay.url);
      const messages: any[] = [];
      socket.addEventListener("message", (event) => messages.push(JSON.parse(String(event.data))));
      await new Promise<void>((resolve) => socket.addEventListener("open", () => resolve()));
      while (!messages.length) await Bun.sleep(1);
      const hello = messages[0];
      const { createPairingProof } = await import("../src/shared/auth");
      socket.send(JSON.stringify({
        v: 1,
        kind: "auth",
        deviceId: "phone",
        proof: await createPairingProof(secret, hello.challenge, "phone"),
      }));
      while (messages.length < 2) await Bun.sleep(1);
      expect(messages[1].health).toEqual({
        status: "ok",
        relayName: "framework",
        clipboard: {
          enabled: true,
          status: "healthy",
          watcher: "wl-paste --watch",
        },
      });
      socket.close();
    } finally {
      await relay.stop();
    }
  });
});
