import { afterEach, describe, expect, test } from "bun:test";
import { createRelay } from "../src/relay/relay";
import {
  findScreenPlayer,
  ScreenMirror,
  type PlayerProcess,
  type ScreenPlayer,
} from "../src/relay/screen-mirror";
import { createAuthMessage } from "../src/shared/auth";
import { ScreenRecordOpener, sealScreenRecord } from "../src/shared/screen-seal";
import { deriveSessionKey, SessionSealer } from "../src/shared/session-seal";
import { isScreenStart, type RelayMessage } from "../src/shared/wire";
import { connectRawWebSocket } from "./helpers/raw-ws-client";

const secret = "pairing-secret-for-tests";
const fakePlayer: ScreenPlayer = { name: "mpv", command: ["mpv", "-"], env: {} };

class FakePlayer implements PlayerProcess {
  readonly written: Buffer[] = [];
  killed = false;
  #exit: () => void = () => undefined;
  readonly exited = new Promise<void>((resolve) => {
    this.#exit = resolve;
  });

  write(bytes: Uint8Array): void {
    this.written.push(Buffer.from(bytes));
  }

  kill(): void {
    this.killed = true;
    this.#exit();
  }

  /** The user closed the window. */
  closeWindow(): void {
    this.#exit();
  }
}

function mirrorWithFakes(options: { player?: boolean; ticketTtlMs?: number } = {}) {
  const players: FakePlayer[] = [];
  const mirror = new ScreenMirror({
    findPlayer: () => (options.player === false ? undefined : fakePlayer),
    launch: () => {
      const player = new FakePlayer();
      players.push(player);
      return player;
    },
    ...(options.ticketTtlMs !== undefined && { ticketTtlMs: options.ticketTtlMs }),
  });
  return { mirror, players };
}

function keyOf(answer: ReturnType<ScreenMirror["start"]>): Uint8Array {
  if (!answer.ok) throw new Error(`expected a ticket, got ${answer.code}`);
  return new Uint8Array(Buffer.from(answer.key, "base64"));
}

describe("screen records", () => {
  const key = new Uint8Array(32).fill(7);

  test("open in order", () => {
    const opener = new ScreenRecordOpener(key);
    expect(opener.open(sealScreenRecord(key, 0n, Buffer.from("first")))).toEqual(Buffer.from("first"));
    expect(opener.open(sealScreenRecord(key, 1n, Buffer.from("second")))).toEqual(Buffer.from("second"));
    expect(opener.records).toBe(2n);
  });

  test("refuse a skipped, replayed or altered record", () => {
    const skipped = new ScreenRecordOpener(key);
    expect(() => skipped.open(sealScreenRecord(key, 1n, Buffer.from("late")))).toThrow();

    const replayed = new ScreenRecordOpener(key);
    const record = sealScreenRecord(key, 0n, Buffer.from("once"));
    replayed.open(record);
    expect(() => replayed.open(record)).toThrow();

    const altered = sealScreenRecord(key, 0n, Buffer.from("frame"));
    altered[0] = altered[0]! ^ 1;
    expect(() => new ScreenRecordOpener(key).open(altered)).toThrow();
  });

  test("refuse a record too short to hold a tag", () => {
    expect(() => new ScreenRecordOpener(key).open(new Uint8Array(8))).toThrow(/bad length/);
  });
});

describe("screen_start", () => {
  test("accepts sizes in range only", () => {
    expect(isScreenStart({ v: 1, kind: "screen_start", width: 1080, height: 2400 })).toBe(true);
    expect(isScreenStart({ v: 1, kind: "screen_start", width: 0, height: 2400 })).toBe(false);
    expect(isScreenStart({ v: 1, kind: "screen_start", width: 1080.5, height: 2400 })).toBe(false);
    expect(isScreenStart({ v: 1, kind: "screen_start", width: 1080, height: 99_999 })).toBe(false);
    expect(isScreenStart({ v: 1, kind: "screen_start", width: 1080 })).toBe(false);
  });
});

describe("screen player", () => {
  test("prefers mpv and falls back to ffplay", () => {
    const mpv = findScreenPlayer((command) => `/usr/bin/${command}`);
    expect(mpv?.name).toBe("mpv");
    expect(mpv?.command).toContain("--wayland-app-id=vidyut-screen");
    expect(mpv?.command.at(-1)).toBe("-");

    const ffplay = findScreenPlayer((command) => (command === "ffplay" ? "/usr/bin/ffplay" : null));
    expect(ffplay?.name).toBe("ffplay");
    expect(ffplay?.env.SDL_APP_ID).toBe("vidyut-screen");

    expect(findScreenPlayer(() => null)).toBeUndefined();
  });
});

describe("ScreenMirror", () => {
  test("says how to fix a laptop without a player", () => {
    const { mirror } = mirrorWithFakes({ player: false });
    expect(mirror.start("phone", 1080, 2400)).toMatchObject({ ok: false, code: "no_player" });
  });

  test("admits one socket per ticket and pipes opened records to the player", () => {
    const { mirror, players } = mirrorWithFakes();
    const answer = mirror.start("phone", 1080, 2400);
    const key = keyOf(answer);
    if (!answer.ok) throw new Error("unreachable");

    expect(mirror.claim("not-the-id")).toBe(false);
    expect(mirror.claim(answer.streamId)).toBe(true);
    expect(mirror.claim(answer.streamId)).toBe(false);

    const stream = mirror.attach(answer.streamId, () => undefined);
    expect(stream).toBeDefined();
    expect(stream!.receive(sealScreenRecord(key, 0n, Buffer.from("sps")))).toBe(true);
    expect(stream!.receive(sealScreenRecord(key, 1n, Buffer.from("idr")))).toBe(true);
    expect(players[0]!.written.map(String)).toEqual(["sps", "idr"]);

    stream!.closed();
    expect(players[0]!.killed).toBe(true);
  });

  test("ends the stream and closes the window on a bad record", () => {
    const { mirror, players } = mirrorWithFakes();
    const answer = mirror.start("phone", 1080, 2400);
    if (!answer.ok) throw new Error("expected a ticket");
    mirror.claim(answer.streamId);
    const closes: string[] = [];
    const stream = mirror.attach(answer.streamId, (_code, reason) => closes.push(reason));

    const wrongKey = new Uint8Array(32).fill(1);
    expect(stream!.receive(sealScreenRecord(wrongKey, 0n, Buffer.from("x")))).toBe(false);
    expect(players[0]!.killed).toBe(true);
    expect(closes).toEqual(["bad_record"]);
  });

  test("closes the phone socket when the window is closed", async () => {
    const { mirror, players } = mirrorWithFakes();
    const answer = mirror.start("phone", 1080, 2400);
    if (!answer.ok) throw new Error("expected a ticket");
    mirror.claim(answer.streamId);
    const closed = new Promise<string>((resolve) => {
      mirror.attach(answer.streamId, (_code, reason) => resolve(reason));
    });

    players[0]!.closeWindow();
    expect(await closed).toBe("window_closed");
  });

  test("a new start replaces the mirror that runs", () => {
    const { mirror, players } = mirrorWithFakes();
    const first = mirror.start("phone", 1080, 2400);
    if (!first.ok) throw new Error("expected a ticket");
    mirror.claim(first.streamId);
    const closes: string[] = [];
    mirror.attach(first.streamId, (_code, reason) => closes.push(reason));

    const second = mirror.start("phone", 720, 1600);
    expect(second.ok).toBe(true);
    expect(players[0]!.killed).toBe(true);
    expect(closes).toEqual(["replaced"]);
  });

  test("an unused ticket expires", async () => {
    const { mirror } = mirrorWithFakes({ ticketTtlMs: 10 });
    const answer = mirror.start("phone", 1080, 2400);
    if (!answer.ok) throw new Error("expected a ticket");
    await Bun.sleep(30);
    expect(mirror.claim(answer.streamId)).toBe(false);
  });
});

describe("relay screen mirror", () => {
  let relay: Awaited<ReturnType<typeof createRelay>> | undefined;

  afterEach(async () => {
    await relay?.stop();
    relay = undefined;
  });

  async function relayWithMirror() {
    const fakes = mirrorWithFakes();
    relay = await createRelay({
      hostname: "127.0.0.1",
      port: 0,
      pairingSecret: secret,
      maxPayloadBytes: 1024 * 1024,
      screen: fakes.mirror,
    });
    return { relay, ...fakes };
  }

  async function sealedPhone(url: string) {
    const phone = await connectRawWebSocket(url);
    const hello = await phone.next();
    if (hello.kind !== "hello") throw new Error("expected hello");
    const clientChallenge = Buffer.from(crypto.getRandomValues(new Uint8Array(24))).toString("base64");
    phone.send({
      ...(await createAuthMessage(secret, hello.challenge, "phone")),
      clientChallenge,
      features: ["telemetry_subscribe", "sealed_control"],
    });
    await phone.next((message) => message.kind === "auth_ok");
    const sealer = new SessionSealer(
      deriveSessionKey(secret, hello.challenge, clientChallenge, "phone"),
      "phone_to_relay",
    );
    return { phone, sealer, features: hello.features ?? [] };
  }

  async function nextOpened(
    phone: Awaited<ReturnType<typeof connectRawWebSocket>>,
    sealer: SessionSealer,
  ): Promise<RelayMessage> {
    const sealed = await phone.next((message) => message.kind === "sealed");
    if (sealed.kind !== "sealed") throw new Error("expected sealed");
    return sealer.open(sealed);
  }

  function openStream(url: string, streamId: string): Promise<WebSocket> {
    return new Promise((resolve, reject) => {
      const socket = new WebSocket(`${url}/screen/v1/${streamId}`);
      socket.binaryType = "arraybuffer";
      socket.onopen = () => resolve(socket);
      socket.onerror = () => reject(new Error("stream refused"));
    });
  }

  test("hands out a ticket on a sealed session and shows the stream", async () => {
    const { relay, players } = await relayWithMirror();
    const { phone, sealer, features } = await sealedPhone(relay.url);
    expect(features).toContain("screen_mirror");

    phone.send(sealer.seal({ v: 1, kind: "screen_start", width: 1080, height: 2400 }));
    const ready = await nextOpened(phone, sealer);
    if (ready.kind !== "screen_ready") throw new Error(`expected screen_ready, got ${ready.kind}`);
    const key = new Uint8Array(Buffer.from(ready.key, "base64"));

    const stream = await openStream(relay.url, ready.streamId);
    stream.send(new Uint8Array(sealScreenRecord(key, 0n, Buffer.from("frame-0"))));
    stream.send(new Uint8Array(sealScreenRecord(key, 1n, Buffer.from("frame-1"))));
    for (let i = 0; i < 50 && (players[0]?.written.length ?? 0) < 2; i++) await Bun.sleep(10);
    expect(players[0]!.written.map(String)).toEqual(["frame-0", "frame-1"]);

    const closed = new Promise<void>((resolve) => {
      stream.onclose = () => resolve();
    });
    players[0]!.closeWindow();
    await closed;

    // The ticket was used, so a second socket is refused.
    await expect(openStream(relay.url, ready.streamId)).rejects.toThrow(/refused/);
    phone.close();
  });

  test("refuses to hand a key to an unsealed session", async () => {
    const { relay } = await relayWithMirror();
    const phone = await connectRawWebSocket(relay.url);
    const hello = await phone.next();
    if (hello.kind !== "hello") throw new Error("expected hello");
    phone.send(await createAuthMessage(secret, hello.challenge, "legacy-phone"));
    await phone.next((message) => message.kind === "auth_ok");

    phone.send({ v: 1, kind: "screen_start", width: 1080, height: 2400 });
    expect(await phone.next((message) => message.kind === "screen_failed")).toMatchObject({
      code: "seal_required",
    });
    phone.close();
  });

  test("does not advertise the feature without a mirror", async () => {
    relay = await createRelay({
      hostname: "127.0.0.1",
      port: 0,
      pairingSecret: secret,
      maxPayloadBytes: 1024 * 1024,
    });
    const phone = await connectRawWebSocket(relay.url);
    const hello = await phone.next();
    if (hello.kind !== "hello") throw new Error("expected hello");
    expect(hello.features).not.toContain("screen_mirror");
    phone.close();
  });
});
