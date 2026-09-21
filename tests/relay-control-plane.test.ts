import { afterEach, describe, expect, test } from "bun:test";
import { mkdtemp, readFile, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { connectDevice } from "../src/relay/client";
import {
  loadOrCreateRelayConfig,
  writeRelayConfig,
  type RelayConfig,
} from "../src/relay/config";
import { getLanIPv4Addresses } from "../src/relay/network";
import { createRelay, type RelayHandle } from "../src/relay/relay";
import { encryptPayload } from "../src/shared/crypto";

const secret = "pairing-secret-CONTROL-PLANE-xyz";
const pairingHost = "10.0.0.4";
const lanHost = getLanIPv4Addresses()[0];

let relay: RelayHandle | undefined;

afterEach(async () => {
  await relay?.stop();
  relay = undefined;
});

async function startRelay(
  options: Partial<Parameters<typeof createRelay>[0]> = {},
): Promise<RelayHandle> {
  relay = await createRelay({
    hostname: "0.0.0.0",
    port: 0,
    pairingSecret: { value: secret },
    maxPayloadBytes: 1024 * 1024,
    pairingHost,
    relayName: "framework",
    ...options,
  });
  return relay;
}

function httpUrl(handle: RelayHandle, host: string, path: string): string {
  const url = new URL(handle.url.replace("ws://", "http://"));
  return `http://${host}:${url.port}${path}`;
}

async function fetchPath(
  handle: RelayHandle,
  host: string,
  path: string,
  init?: RequestInit,
): Promise<Response> {
  return fetch(httpUrl(handle, host, path), init);
}

describe("relay loopback control plane", () => {
  test("loopback GET /control/v1/state is 200 and includes the pairing secret", async () => {
    const handle = await startRelay({
      clipboardHealth: () => ({
        enabled: true,
        status: "healthy",
        watcher: "wl-paste --watch",
      }),
    });
    const phone = await connectDevice({
      url: handle.url.replace("0.0.0.0", "127.0.0.1"),
      pairingSecret: secret,
      deviceId: "phone",
    });
    const frame = await encryptPayload(
      { type: "text", mime: "text/plain", origin: "phone", ts: Date.now() },
      new TextEncoder().encode("hello"),
      secret,
    );
    await phone.publish(frame);

    const response = await fetchPath(handle, "127.0.0.1", "/control/v1/state");
    expect(response.status).toBe(200);
    const state = (await response.json()) as Record<string, unknown>;
    expect(state.relayName).toBe("framework");
    expect(state.host).toBe(pairingHost);
    expect(state.port).toBe(Number(new URL(handle.url.replace("ws://", "http://")).port));
    expect(state.pairingSecret).toBe(secret);
    expect(state.manual).toBe(
      `host=${pairingHost} port=${state.port} secret=${secret}`,
    );
    expect(state.syncState).toBe("ready");
    expect(state.clipboard).toEqual({
      enabled: true,
      status: "healthy",
      watcher: "wl-paste --watch",
    });
    expect(state.authenticatedDeviceCount).toBe(1);
    expect(state.pool).toEqual({
      type: "text",
      mime: "text/plain",
      bytes: expect.any(Number),
      origin: "phone",
      ageSeconds: expect.any(Number),
    });
    expect(JSON.stringify(state.pool)).not.toContain(frame.payload);
    phone.close();
  });

  test("a non-loopback client gets 404 and the body has no pairing secret", async () => {
    const handle = await startRelay();
    const loopback = await fetchPath(handle, "127.0.0.1", "/control/v1/state");
    expect(loopback.status).toBe(200);
    expect(JSON.stringify(await loopback.json())).toContain(secret);

    if (!lanHost) return;
    const remote = await fetchPath(handle, lanHost, "/control/v1/state");
    expect(remote.status).toBe(404);
    const body = await remote.text();
    expect(body).not.toContain(secret);
  });

  test("GET / and GET /ui/ are branded HTML on loopback and 404 off loopback", async () => {
    const handle = await startRelay();
    for (const path of ["/", "/ui/", "/ui"]) {
      const local = await fetchPath(handle, "127.0.0.1", path);
      expect(local.status).toBe(200);
      expect(local.headers.get("content-type")).toMatch(/text\/html/);
      const html = await local.text();
      expect(html).toContain("Vidyut");
      expect(html).toContain(secret);
      expect(html).toContain("/control/v1/qr.svg");
      expect(html).toContain("Plus Jakarta Sans");
      expect(html).toContain("#C83861");
      expect(html).toContain("#FDF0F4");
      expect(html).toContain("Ready");
      expect(html).toContain("Sync needs attention");
      expect(html).toContain("Relay down");
      expect(html).toContain("Send files");
      expect(html).toContain("Transfer history");
      expect(html).toContain("Laptop setup status");
      expect(html).toContain("Rotate pairing secret");
      expect(html).toContain("Every phone must scan");
      expect(html).toContain("Closing this window does not stop the Relay");
      expect(html).toContain("Start relay");
      expect(html).toContain("Stop relay");
      expect(html).toContain('id="start-relay"');
      expect(html).toContain('id="stop-relay"');
      expect(html).toContain('invoke("start_relay")');
      expect(html).toContain('invoke("stop_relay")');
      expect(html).toContain("pick_and_send_files");
      expect(html).not.toContain("Manrope");
      expect(html).not.toMatch(/Recent activity|Activity timeline/);
    }

    const stillUp = await fetchPath(handle, "127.0.0.1", "/health");
    expect(stillUp.status).toBe(200);

    if (!lanHost) return;
    for (const path of ["/", "/ui/", "/control/v1/qr.svg"]) {
      const remote = await fetchPath(handle, lanHost, path);
      expect(remote.status).toBe(404);
      expect(await remote.text()).not.toContain(secret);
    }
  });

  test("GET /control/v1/qr.svg is a pairing QR, not ascii from qrcode-terminal", async () => {
    const handle = await startRelay();
    const response = await fetchPath(handle, "127.0.0.1", "/control/v1/qr.svg");
    expect(response.status).toBe(200);
    expect(response.headers.get("content-type")).toMatch(/image\/svg\+xml/);
    const svg = await response.text();
    expect(svg).toContain("<svg");
    expect(svg).not.toMatch(/[\u2580\u2584\u2588]/);
  });

  test("loopback /health stays 200 and never includes the pairing secret", async () => {
    const handle = await startRelay();
    const response = await fetchPath(handle, "127.0.0.1", "/health");
    expect(response.status).toBe(200);
    const health = await response.json();
    expect(JSON.stringify(health)).not.toContain(secret);
    expect(health).not.toHaveProperty("pairingSecret");
  });

  test("POST /control/v1/rotate-secret persists a new secret and rejects the old one", async () => {
    const dir = await mkdtemp(join(tmpdir(), "vidyut-rotate-"));
    const path = join(dir, "relay.json");
    const config: RelayConfig = {
      pairingSecret: secret,
      port: 17321,
      maxPayloadBytes: 1024,
      deviceId: "laptop",
      logLevel: "info",
      transferDestination: join(dir, "Downloads"),
      maxTransferFileBytes: 1024,
    };
    await writeRelayConfig(path, config);
    const pairingSecret = { value: secret };

    const handle = await startRelay({
      pairingSecret,
      persistPairingSecret: async (next) => {
        config.pairingSecret = next;
        await writeRelayConfig(path, config);
      },
    });

    const response = await fetchPath(
      handle,
      "127.0.0.1",
      "/control/v1/rotate-secret",
      { method: "POST" },
    );
    expect(response.status).toBe(200);
    const state = (await response.json()) as { pairingSecret: string };
    expect(state.pairingSecret).not.toBe(secret);
    expect(state.pairingSecret.length).toBeGreaterThan(30);
    expect(pairingSecret.value).toBe(state.pairingSecret);

    const stored = JSON.parse(await readFile(path, "utf8")) as RelayConfig;
    expect(stored.pairingSecret).toBe(state.pairingSecret);
    expect((await stat(path)).mode & 0o777).toBe(0o600);
    expect((await loadOrCreateRelayConfig(path)).pairingSecret).toBe(
      state.pairingSecret,
    );

    const health = await fetchPath(handle, "127.0.0.1", "/health");
    expect(health.status).toBe(200);

    await expect(
      connectDevice({
        url: handle.url.replace("0.0.0.0", "127.0.0.1"),
        pairingSecret: secret,
        deviceId: "phone",
      }),
    ).rejects.toThrow(/auth_failed/);

    const phone = await connectDevice({
      url: handle.url.replace("0.0.0.0", "127.0.0.1"),
      pairingSecret: state.pairingSecret,
      deviceId: "phone",
    });
    phone.close();
    await rm(dir, { recursive: true, force: true });
  });

  test("GET /control/v1/transfers returns stored history on loopback only", async () => {
    const snapshot = {
      v: 1 as const,
      batches: [
        {
          transferId: "transfer_loopback_1",
          batchId: "batch_1",
          origin: "laptop",
          direction: "laptop_to_phone" as const,
          createdAtMs: 1,
          updatedAtMs: 1,
          expiresAtMs: 2,
          status: "completed" as const,
          files: [],
        },
      ],
    };
    const handle = await startRelay({
      transferSnapshot: () => snapshot,
    });
    const local = await fetchPath(handle, "127.0.0.1", "/control/v1/transfers");
    expect(local.status).toBe(200);
    await expect(local.json()).resolves.toEqual(snapshot);

    if (!lanHost) return;
    const remote = await fetchPath(handle, lanHost, "/control/v1/transfers");
    expect(remote.status).toBe(404);
    expect(await remote.text()).not.toContain(secret);
  });

  test("POST /control/v1/transfers/enqueue uses the laptop enqueue path on loopback only", async () => {
    const seen: string[][] = [];
    const handle = await startRelay({
      enqueueLaptopFiles: async (paths) => {
        seen.push(paths);
        return { transferId: "transfer_enqueued" };
      },
    });
    const local = await fetchPath(
      handle,
      "127.0.0.1",
      "/control/v1/transfers/enqueue",
      {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ paths: ["/tmp/report.pdf"] }),
      },
    );
    expect(local.status).toBe(202);
    expect(seen).toEqual([["/tmp/report.pdf"]]);

    if (!lanHost) return;
    const remote = await fetchPath(
      handle,
      lanHost,
      "/control/v1/transfers/enqueue",
      {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ paths: ["/tmp/secret-should-not-leak"] }),
      },
    );
    expect(remote.status).toBe(404);
    expect(await remote.text()).not.toContain(secret);
    expect(seen).toHaveLength(1);
  });

  test("GET /control/v1/setup returns laptop setup status rows on loopback only", async () => {
    const handle = await startRelay();
    const local = await fetchPath(handle, "127.0.0.1", "/control/v1/setup");
    expect(local.status).toBe(200);
    const body = (await local.json()) as {
      rows: Array<{ id: string; ok: boolean }>;
    };
    const ids = body.rows.map((row) => row.id);
    expect(ids).toEqual([
      "relay_running",
      "wayland",
      "wl_clipboard",
      "imagemagick",
      "autostart",
      "firewall",
    ]);
    expect(body.rows[0]).toMatchObject({ id: "relay_running", ok: true });
    expect(JSON.stringify(body)).not.toContain(secret);

    if (!lanHost) return;
    const remote = await fetchPath(handle, lanHost, "/control/v1/setup");
    expect(remote.status).toBe(404);
    expect(await remote.text()).not.toContain(secret);
  });
});

test("writeRelayConfig keeps mode 600", async () => {
  const dir = await mkdtemp(join(tmpdir(), "vidyut-config-mode-"));
  const path = join(dir, "relay.json");
  await writeFile(
    path,
    JSON.stringify({
      pairingSecret: "old",
      port: 17321,
      maxPayloadBytes: 1,
      deviceId: "laptop",
      logLevel: "info",
    }),
  );
  const config = await loadOrCreateRelayConfig(path);
  config.pairingSecret = "rotated";
  await writeRelayConfig(path, config);
  expect((await stat(path)).mode & 0o777).toBe(0o600);
  expect(JSON.parse(await readFile(path, "utf8")).pairingSecret).toBe("rotated");
  await rm(dir, { recursive: true, force: true });
});
