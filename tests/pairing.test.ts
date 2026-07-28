import { describe, expect, test } from "bun:test";
import { createPairingCode } from "../src/relay/pairing";

describe("pairing code", () => {
  test("contains QR and manual pairing details", () => {
    const code = createPairingCode({
      host: "192.168.1.10",
      port: 17321,
      pairingSecret: "secret",
    });

    expect(JSON.parse(code.raw)).toEqual({
      v: 1,
      service: "vidyut",
      host: "192.168.1.10",
      port: 17321,
      secret: "secret",
    });
    expect(code.manual).toBe("host=192.168.1.10 port=17321 secret=secret");
    expect(code.qr.length).toBeGreaterThan(0);
  });

  test("includes the friendly relay name when available", () => {
    const code = createPairingCode({
      host: "192.168.1.10",
      port: 17321,
      pairingSecret: "secret",
      relayName: "framework",
    });

    expect(JSON.parse(code.raw).name).toBe("framework");
  });
});
