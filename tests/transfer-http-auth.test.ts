import { describe, expect, test } from "bun:test";
import {
  createTransferHttpAuth,
  verifyTransferHttpAuth,
} from "../src/shared/transfer-http-auth";

const secret = "pairing-secret-for-http-tests";
const now = 1_753_689_600_000;
const path = "/transfer/v1/transfer_123/file_456?offset=4096";

describe("transfer HTTP authentication", () => {
  test("authenticates method, path, query and current timestamp", async () => {
    const auth = await createTransferHttpAuth({
      pairingSecret: secret,
      method: "GET",
      pathAndQuery: path,
      date: now,
    });
    const request = new Request(`http://relay${path}`, {
      headers: {
        "x-vidyut-date": auth.date,
        authorization: auth.authorization,
      },
    });

    await expect(
      verifyTransferHttpAuth({ request, pairingSecret: secret, now }),
    ).resolves.toBe(true);
  });

  test("rejects a changed range, method, secret or stale timestamp", async () => {
    const auth = await createTransferHttpAuth({
      pairingSecret: secret,
      method: "GET",
      pathAndQuery: path,
      date: now,
    });
    const headers = {
      "x-vidyut-date": auth.date,
      authorization: auth.authorization,
    };

    await expect(
      verifyTransferHttpAuth({
        request: new Request(`http://relay${path.replace("4096", "0")}`, {
          headers,
        }),
        pairingSecret: secret,
        now,
      }),
    ).resolves.toBe(false);
    await expect(
      verifyTransferHttpAuth({
        request: new Request(`http://relay${path}`, {
          method: "PUT",
          headers,
        }),
        pairingSecret: secret,
        now,
      }),
    ).resolves.toBe(false);
    await expect(
      verifyTransferHttpAuth({
        request: new Request(`http://relay${path}`, { headers }),
        pairingSecret: "wrong",
        now,
      }),
    ).resolves.toBe(false);
    await expect(
      verifyTransferHttpAuth({
        request: new Request(`http://relay${path}`, { headers }),
        pairingSecret: secret,
        now: now + 5 * 60 * 1000 + 1,
      }),
    ).resolves.toBe(false);
  });
});

