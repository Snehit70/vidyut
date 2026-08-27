import { createAuthMessage } from "../../src/shared/auth";
import type { RelayMessage } from "../../src/shared/wire";

/**
 * Minimal WebSocket client over a raw TCP socket for relay tests.
 *
 * Bun's built-in WebSocket client can drop a data frame that arrives
 * coalesced with other frames right after the handshake, which makes
 * reconnect assertions flaky. This client parses the frames itself, so a
 * frame the relay put on the wire is a frame the test observes. It also
 * makes heartbeat behavior controllable: `respondToPings: false` imitates
 * a vanished peer that keeps the TCP socket open but never answers.
 */
export interface RawWebSocketClient {
  /** Next JSON text message from the relay (pings are handled separately). */
  next(predicate?: (message: RelayMessage) => boolean): Promise<RelayMessage>;
  send(message: unknown): void;
  /** Sends a client-initiated WebSocket ping control frame. */
  ping(): void;
  /** Resolves when the relay closes or terminates the connection. */
  closed: Promise<void>;
  isClosed(): boolean;
  close(): void;
}

interface RawWebSocketOptions {
  respondToPings?: boolean;
}

export async function connectRawWebSocket(url: string, options: RawWebSocketOptions = {}): Promise<RawWebSocketClient> {
  const respondToPings = options.respondToPings ?? true;
  const { hostname, port } = new URL(url.replace(/^ws:/, "http:"));

  const messages: RelayMessage[] = [];
  const waiters: Array<(message: RelayMessage) => boolean | void> = [];
  let closedFlag = false;
  let resolveClosed: () => void = () => {};
  const closed = new Promise<void>((resolve) => {
    resolveClosed = resolve;
  });

  let upgraded = false;
  let pending: Uint8Array<ArrayBufferLike> = new Uint8Array(0);

  const socket = await Bun.connect({
    hostname,
    port: Number(port),
    socket: {
      data(tcpSocket, chunk) {
        let bytes = new Uint8Array(chunk);
        if (!upgraded) {
          const headerEnd = new TextDecoder().decode(bytes).indexOf("\r\n\r\n");
          if (headerEnd === -1) return;
          upgraded = true;
          bytes = bytes.slice(headerEnd + 4);
        }
        const merged = new Uint8Array(pending.length + bytes.length);
        merged.set(pending, 0);
        merged.set(bytes, pending.length);
        const { frames, rest } = parseServerFrames(merged);
        pending = rest;
        for (const frame of frames) {
          if (frame.opcode === 0x9) {
            if (respondToPings) {
              tcpSocket.write(encodeClientFrame(0xa, frame.payload));
            }
            continue;
          }
          if (frame.opcode !== 0x1) continue;
          const message = JSON.parse(new TextDecoder().decode(frame.payload)) as RelayMessage;
          let handled = false;
          for (let i = 0; i < waiters.length; i++) {
            const waiter = waiters[i]!;
            const consumed = waiter(message);
            if (consumed !== false) {
              waiters.splice(i, 1);
              handled = true;
              break;
            }
          }
          if (!handled) messages.push(message);
        }
      },
      close() {
        closedFlag = true;
        resolveClosed();
      },
      error() {
        closedFlag = true;
        resolveClosed();
      },
    },
  });

  const key = Buffer.from(crypto.getRandomValues(new Uint8Array(16))).toString("base64");
  socket.write(
    `GET / HTTP/1.1\r\n` +
      `Host: ${hostname}:${port}\r\n` +
      `Upgrade: websocket\r\n` +
      `Connection: Upgrade\r\n` +
      `Sec-WebSocket-Key: ${key}\r\n` +
      `Sec-WebSocket-Version: 13\r\n\r\n`,
  );

  return {
    next(predicate) {
      if (!predicate) {
        const message = messages.shift();
        if (message) return Promise.resolve(message);
        return new Promise<RelayMessage>((resolve) => waiters.push((msg) => resolve(msg)));
      }
      const index = messages.findIndex(predicate);
      if (index !== -1) {
        const [message] = messages.splice(index, 1);
        return Promise.resolve(message!);
      }
      return new Promise<RelayMessage>((resolve) => {
        waiters.push((msg) => {
          if (predicate(msg)) {
            resolve(msg);
            return true;
          }
          return false;
        });
      });
    },
    send(message) {
      socket.write(encodeClientFrame(0x1, new TextEncoder().encode(JSON.stringify(message))));
    },
    ping() {
      socket.write(encodeClientFrame(0x9, new Uint8Array(0)));
    },
    closed,
    isClosed() {
      return closedFlag;
    },
    close() {
      socket.end();
    },
  };
}

/** Runs the hello/auth handshake and returns once the relay accepts. */
export async function authenticateRawClient(client: RawWebSocketClient, pairingSecret: string, deviceId: string): Promise<void> {
  const hello = await client.next();
  if (hello.kind !== "hello") {
    throw new Error(`Expected hello, got ${hello.kind}`);
  }
  client.send(await createAuthMessage(pairingSecret, hello.challenge, deviceId));
  const reply = await client.next();
  if (reply.kind !== "auth_ok") {
    throw new Error(`Expected auth_ok, got ${reply.kind}`);
  }
}

/** Client->server frames must be masked per RFC 6455. */
function encodeClientFrame(opcode: number, payload: Uint8Array): Uint8Array {
  const mask = crypto.getRandomValues(new Uint8Array(4));
  let header: number[];
  if (payload.length < 126) {
    header = [0x80 | opcode, 0x80 | payload.length];
  } else if (payload.length < 65536) {
    header = [0x80 | opcode, 0x80 | 126, payload.length >> 8, payload.length & 0xff];
  } else {
    throw new Error("Payload too large for the test client.");
  }
  const frame = new Uint8Array(header.length + 4 + payload.length);
  frame.set(header, 0);
  frame.set(mask, header.length);
  for (let i = 0; i < payload.length; i++) {
    frame[header.length + 4 + i] = payload[i]! ^ mask[i % 4]!;
  }
  return frame;
}

/** Server->client frames are unmasked; returns parsed frames plus leftover bytes. */
function parseServerFrames(buffer: Uint8Array): {
  frames: Array<{ opcode: number; payload: Uint8Array }>;
  rest: Uint8Array;
} {
  const frames: Array<{ opcode: number; payload: Uint8Array }> = [];
  let offset = 0;
  while (offset + 2 <= buffer.length) {
    const opcode = buffer[offset]! & 0x0f;
    let length = buffer[offset + 1]! & 0x7f;
    let headerLength = 2;
    if (length === 126) {
      if (offset + 4 > buffer.length) break;
      length = (buffer[offset + 2]! << 8) | buffer[offset + 3]!;
      headerLength = 4;
    } else if (length === 127) {
      if (offset + 10 > buffer.length) break;
      length = Number(new DataView(buffer.buffer, buffer.byteOffset + offset + 2, 8).getBigUint64(0));
      headerLength = 10;
    }
    if (offset + headerLength + length > buffer.length) break;
    frames.push({
      opcode,
      payload: buffer.slice(offset + headerLength, offset + headerLength + length),
    });
    offset += headerLength + length;
  }
  return { frames, rest: buffer.slice(offset) };
}
