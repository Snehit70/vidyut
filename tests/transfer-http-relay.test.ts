import { afterEach, describe, expect, test } from "bun:test";
import { createRelay } from "../src/relay/relay";
import { createTransferHttpAuth } from "../src/shared/transfer-http-auth";
import { TransferHttpDataPlane } from "../src/transfer/http-data-plane";

const secret = "pairing-secret-for-http-relay-tests";

class TestDataPlane extends TransferHttpDataPlane {
  protected override async handleAuthenticated(
    request: Request,
  ): Promise<Response | undefined> {
    return Response.json({
      path: new URL(request.url).pathname,
      authenticated: true,
    });
  }
}

let relay: Awaited<ReturnType<typeof createRelay>> | undefined;

afterEach(async () => {
  await relay?.stop();
  relay = undefined;
});

describe("same-port transfer HTTP data plane", () => {
  test("serves authenticated transfer requests without another port", async () => {
    const dataPlane = new TestDataPlane(secret);
    relay = await createRelay({
      hostname: "127.0.0.1",
      port: 0,
      pairingSecret: secret,
      maxPayloadBytes: 1024,
      transferHttp: dataPlane.handle.bind(dataPlane),
    });
    const path = "/transfer/v1/transfer_1234567890/file_1234567890123";
    const auth = await createTransferHttpAuth({
      pairingSecret: secret,
      method: "GET",
      pathAndQuery: path,
    });

    const response = await fetch(relay.url.replace("ws:", "http:") + path, {
      headers: {
        "x-vidyut-date": auth.date,
        authorization: auth.authorization,
      },
    });

    expect(response.status).toBe(200);
    await expect(response.json()).resolves.toEqual({
      path,
      authenticated: true,
    });
  });

  test("rejects unauthenticated requests before the adapter", async () => {
    const dataPlane = new TestDataPlane(secret);
    relay = await createRelay({
      hostname: "127.0.0.1",
      port: 0,
      pairingSecret: secret,
      maxPayloadBytes: 1024,
      transferHttp: dataPlane.handle.bind(dataPlane),
    });

    const response = await fetch(
      relay.url.replace("ws:", "http:") +
        "/transfer/v1/transfer_1234567890/file_1234567890123",
    );

    expect(response.status).toBe(401);
    await expect(response.json()).resolves.toEqual({
      code: "transfer_auth_failed",
    });
  });
});
