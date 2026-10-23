import { describe, expect, test } from "bun:test";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { loadOrCreateRelayConfig } from "../src/relay/config";

describe("relay config", () => {
  test("creates a persistent pairing secret on first run", async () => {
    const dir = await mkdtemp(join(tmpdir(), "vidyut-config-"));
    const path = join(dir, "relay.json");

    const first = await loadOrCreateRelayConfig(path);
    const second = await loadOrCreateRelayConfig(path);

    expect(first.pairingSecret.length).toBeGreaterThan(30);
    expect(second).toEqual(first);
    expect(first.maxTransferFileBytes).toBe(1024 * 1024 * 1024);
    expect(first.transferDestination).toEndWith("/Downloads/Vidyut");

    await rm(dir, { recursive: true, force: true });
  });

  test("keeps an empty shared folder list, which turns browsing off", async () => {
    const dir = await mkdtemp(join(tmpdir(), "vidyut-config-shared-"));
    const path = join(dir, "relay.json");
    const first = await loadOrCreateRelayConfig(path);
    await writeFile(path, JSON.stringify({ ...first, sharedFolders: [] }));

    expect((await loadOrCreateRelayConfig(path)).sharedFolders).toEqual([]);

    await writeFile(path, JSON.stringify({ ...first, sharedFolders: ["relative/path"] }));
    expect((await loadOrCreateRelayConfig(path)).sharedFolders).toHaveLength(6);
    await rm(dir, { recursive: true, force: true });
  });

  test("migrates an existing clipboard-only config in place", async () => {
    const dir = await mkdtemp(join(tmpdir(), "vidyut-config-migrate-"));
    const path = join(dir, "relay.json");
    await writeFile(
      path,
      JSON.stringify({
        pairingSecret: "existing-secret",
        port: 17321,
        maxPayloadBytes: 1024,
        deviceId: "laptop",
        logLevel: "info",
      }),
    );

    const config = await loadOrCreateRelayConfig(path);

    expect(config.pairingSecret).toBe("existing-secret");
    expect(config.maxTransferFileBytes).toBe(1024 * 1024 * 1024);
    expect(config.sharedFolders.map((folder) => folder.split("/").at(-1))).toEqual([
      "Desktop",
      "Documents",
      "Downloads",
      "Music",
      "Pictures",
      "Videos",
    ]);
    expect(
      JSON.parse(await readFile(path, "utf8")).transferDestination,
    ).toBe(config.transferDestination);
    await rm(dir, { recursive: true, force: true });
  });
});
