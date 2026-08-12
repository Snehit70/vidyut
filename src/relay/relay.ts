import { verifyPairingProof } from "../shared/auth";
import { noopLogger, type Logger } from "./logger";
import { PayloadPool } from "./payload-pool";
import {
  encodedPayloadBytes,
  isPayloadFrame,
  isTransferControlMessage,
  type PayloadFrame,
  type RelayHealth,
  type RelayMessage,
  type TransferControlMessage,
} from "../shared/wire";
import type { ClipboardHealth } from "./clipboard-sync";

interface RelayOptions {
  hostname: string;
  port: number;
  pairingSecret: string;
  maxPayloadBytes: number;
  pool?: PayloadPool;
  heartbeatIntervalMs?: number;
  staleAfterMs?: number;
  logger?: Logger;
  clipboardHealth?: () => ClipboardHealth;
  relayName?: string;
  transferControl?: (
    message: TransferControlMessage,
    sourceDeviceId: string,
  ) => void | Promise<void>;
  deviceDisconnected?: (deviceId: string) => void | Promise<void>;
  transferHttp?: (
    request: Request,
    context: { isLoopback: boolean },
  ) => Promise<Response | undefined>;
}

const defaultHeartbeatIntervalMs = 30_000;
const defaultStaleAfterMs = 90_000;

interface DeviceSocketData {
  connId: string;
  remote: string;
  challenge: string;
  authenticated: boolean;
  deviceId?: string;
  connectedAt: number;
  lastSeen: number;
}

type RelaySocket = Bun.ServerWebSocket<DeviceSocketData>;

export interface RelayHandle {
  url: string;
  pool: PayloadPool;
  publishHealth(): void;
  publishTransferControl(message: TransferControlMessage): void;
  stop(): Promise<void>;
}

export async function createRelay(options: RelayOptions): Promise<RelayHandle> {
  const pool = options.pool ?? new PayloadPool();
  const logger = options.logger ?? noopLogger;
  const devices = new Set<RelaySocket>();
  const startedAt = Date.now();
  const heartbeatIntervalMs = options.heartbeatIntervalMs ?? defaultHeartbeatIntervalMs;
  const staleAfterMs = options.staleAfterMs ?? defaultStaleAfterMs;
  const unsubscribe = pool.subscribe((frame, source) => {
    logger.info("payload_published", {
      ...publisherIdentity(source),
      ...frameIdentity(frame),
      relayLagMs: Date.now() - frame.ts,
    });
    const recipients = broadcast(devices, source, { v: 1, kind: "payload", frame });
    logger.info("payload_broadcast", { nonce: frame.nonce, frameTs: frame.ts, recipients, replay: false });
  });

  // Reap sockets whose peer went away without a close frame (WiFi drop,
  // phone killed). Pings keep lastSeen fresh on healthy connections; a
  // socket that stays silent past staleAfterMs is terminated.
  const heartbeat = setInterval(() => {
    const now = Date.now();
    for (const socket of devices) {
      const idleMs = now - socket.data.lastSeen;
      if (idleMs > staleAfterMs) {
        devices.delete(socket);
        logger.warn("socket_reaped", {
          connId: socket.data.connId,
          deviceId: socket.data.deviceId,
          idleMs,
          staleAfterMs,
        });
        notifyDeviceDisconnected(options.deviceDisconnected, socket.data.deviceId);
        socket.terminate();
        continue;
      }
      socket.ping();
    }
  }, heartbeatIntervalMs);

  const server = Bun.serve<DeviceSocketData>({
    hostname: options.hostname,
    port: options.port,
    async fetch(request, bunServer) {
      const address = bunServer.requestIP(request);
      const now = Date.now();
      if (
        bunServer.upgrade(request, {
          data: {
            connId: randomConnId(),
            remote: address ? `${address.address}:${address.port}` : "unknown",
            challenge: randomBase64(24),
            authenticated: false,
            connectedAt: now,
            lastSeen: now,
          },
        })
      ) {
        return undefined;
      }
      if (new URL(request.url).pathname.startsWith("/transfer/v1/")) {
        const response = await options.transferHttp?.(request, {
          isLoopback: isLoopbackAddress(address?.address),
        });
        return (
          response ??
          Response.json(
            { code: "transfer_not_found" },
            { status: 404 },
          )
        );
      }
      if (new URL(request.url).pathname === "/health") {
        return Response.json(healthSnapshot(startedAt, devices, pool.current, options.clipboardHealth?.()));
      }
      return new Response("Vidyut relay", { status: 200 });
    },
    websocket: {
      open(socket) {
        devices.add(socket);
        logger.info("device_connected", { connId: socket.data.connId, remote: socket.data.remote });
        send(socket, {
          v: 1,
          kind: "hello",
          challenge: socket.data.challenge,
          maxPayloadBytes: options.maxPayloadBytes,
        });
      },
      async message(socket, rawMessage) {
        socket.data.lastSeen = Date.now();
        const message = parseMessage(rawMessage);
        if (!message) {
          sendError(logger, socket, "bad_message", "Message must be valid JSON.");
          return;
        }

        if (!socket.data.authenticated) {
          await authenticate(
            logger,
            socket,
            message,
            options.pairingSecret,
            pool.current,
            relayHealth(options.relayName ?? "Vidyut Relay", options.clipboardHealth?.()),
          );
          return;
        }

        if (isTransferControlMessage(message)) {
          try {
            await options.transferControl?.(
              message,
              socket.data.deviceId ?? "unknown",
            );
          } catch (error) {
            logger.error("transfer_control_failed", {
              connId: socket.data.connId,
              deviceId: socket.data.deviceId,
              kind: message.kind,
              transferId: transferIdOf(message),
              error: error instanceof Error ? error.message : String(error),
            });
            sendError(
              logger,
              socket,
              "transfer_control_failed",
              "Transfer control could not be processed.",
            );
            return;
          }
          const recipients = broadcast(devices, socket, message);
          logger.info("transfer_control_routed", {
            connId: socket.data.connId,
            deviceId: socket.data.deviceId,
            kind: message.kind,
            transferId: transferIdOf(message),
            recipients,
          });
          return;
        }

        if (message.kind !== "publish" || !isPayloadFrame(message.frame)) {
          sendError(
            logger,
            socket,
            "bad_message",
            "Authenticated devices may publish payload frames or valid transfer control messages.",
          );
          return;
        }

        if (encodedPayloadBytes(message.frame) > options.maxPayloadBytes) {
          sendError(logger, socket, "payload_too_large", `Payload exceeds ${options.maxPayloadBytes} bytes.`);
          return;
        }

        const accepted = await pool.publish(message.frame, socket);
        if (!accepted) {
          logger.warn("payload_stale_dropped", {
            connId: socket.data.connId,
            deviceId: socket.data.deviceId,
            ...frameIdentity(message.frame),
            currentTs: pool.current?.ts,
          });
        }
        send(socket, { v: 1, kind: "ack", ts: message.frame.ts });
      },
      pong(socket) {
        socket.data.lastSeen = Date.now();
      },
      // The phone's own 30s keepalive pings count as liveness too, so reap
      // accuracy no longer depends solely on the relay's outbound ping→pong.
      ping(socket) {
        socket.data.lastSeen = Date.now();
      },
      close(socket, wsCode, wsReason) {
        // A reaped socket was already removed by the heartbeat sweep and got
        // its socket_reaped terminal event; skip it so each connection ends
        // with exactly one terminal event.
        if (!devices.delete(socket)) return;
        logger.info("device_disconnected", {
          connId: socket.data.connId,
          deviceId: socket.data.deviceId,
          authenticated: socket.data.authenticated,
          durationMs: Date.now() - socket.data.connectedAt,
          wsCode,
          wsReason,
        });
        notifyDeviceDisconnected(options.deviceDisconnected, socket.data.deviceId);
      },
    },
  });

  return {
    url: `ws://${server.hostname}:${server.port}`,
    pool,
    publishHealth() {
      broadcast(
        devices,
        undefined,
        {
          v: 1,
          kind: "health",
          health: relayHealth(
            options.relayName ?? "Vidyut Relay",
            options.clipboardHealth?.(),
          ),
        },
      );
    },
    publishTransferControl(message) {
      if (!isTransferControlMessage(message)) {
        throw new TypeError("Invalid transfer control message.");
      }
      const recipients = broadcast(devices, undefined, message);
      logger.info("transfer_control_routed", {
        origin: "local",
        kind: message.kind,
        transferId: transferIdOf(message),
        recipients,
      });
    },
    async stop() {
      clearInterval(heartbeat);
      unsubscribe();
      server.stop(true);
      devices.clear();
    },
  };
}

function notifyDeviceDisconnected(
  callback: RelayOptions["deviceDisconnected"],
  deviceId: string | undefined,
): void {
  if (!callback || !deviceId) return;
  void Promise.resolve(callback(deviceId)).catch(() => undefined);
}

function isLoopbackAddress(address: string | undefined): boolean {
  return (
    address === "127.0.0.1" ||
    address === "::1" ||
    address?.startsWith("127.") === true ||
    address?.startsWith("::ffff:127.") === true
  );
}

async function authenticate(
  logger: Logger,
  socket: RelaySocket,
  message: RelayMessage,
  pairingSecret: string,
  currentPayload: PayloadFrame | undefined,
  health: RelayHealth,
): Promise<void> {
  if (message.kind !== "auth") {
    logger.warn("auth_failed", { connId: socket.data.connId, remote: socket.data.remote, reason: "not_auth_message" });
    sendError(logger, socket, "auth_required", "Device must authenticate before publishing or receiving payloads.");
    socket.close(1008, "auth_required");
    return;
  }

  const valid = await verifyPairingProof(pairingSecret, socket.data.challenge, message.deviceId, message.proof);
  if (!valid) {
    logger.warn("auth_failed", { connId: socket.data.connId, remote: socket.data.remote, reason: "proof_rejected" });
    sendError(logger, socket, "auth_failed", "Pairing secret proof was rejected.");
    socket.close(1008, "auth_failed");
    return;
  }

  socket.data.authenticated = true;
  socket.data.deviceId = message.deviceId;
  logger.info("auth_ok", {
    connId: socket.data.connId,
    deviceId: message.deviceId,
    msSinceConnect: Date.now() - socket.data.connectedAt,
  });
  send(socket, { v: 1, kind: "auth_ok", health });
  if (currentPayload) {
    send(socket, { v: 1, kind: "payload", frame: currentPayload });
    logger.info("payload_broadcast", {
      nonce: currentPayload.nonce,
      frameTs: currentPayload.ts,
      recipients: 1,
      replay: true,
    });
  }
}

function relayHealth(
  relayName: string,
  clipboard?: ClipboardHealth,
): RelayHealth {
  return {
    status: clipboard?.status === "degraded" ? "degraded" : "ok",
    relayName,
    ...(clipboard && { clipboard }),
  };
}

// The one-curl liveness surface (#36): identity and age only — never payload
// content, never the pairing secret.
function healthSnapshot(
  startedAt: number,
  devices: Set<RelaySocket>,
  currentPayload: PayloadFrame | undefined,
  clipboard?: ClipboardHealth,
): Record<string, unknown> {
  const now = Date.now();
  return {
    status: clipboard?.status === "degraded" ? "degraded" : "ok",
    uptimeSeconds: Math.floor((now - startedAt) / 1000),
    ...(clipboard && { clipboard }),
    devices: [...devices]
      .filter((socket) => socket.data.authenticated)
      .map((socket) => ({
        deviceId: socket.data.deviceId,
        remote: socket.data.remote,
        connectedSeconds: Math.floor((now - socket.data.connectedAt) / 1000),
        lastSeenSecondsAgo: Math.floor((now - socket.data.lastSeen) / 1000),
      })),
    pool: currentPayload
      ? {
          type: currentPayload.type,
          mime: currentPayload.mime,
          bytes: encodedPayloadBytes(currentPayload),
          origin: currentPayload.origin,
          ageSeconds: Math.floor((now - currentPayload.ts) / 1000),
        }
      : null,
  };
}

function broadcast(devices: Set<RelaySocket>, publisher: unknown, message: RelayMessage): number {
  let recipients = 0;
  for (const device of devices) {
    if (device !== publisher && device.data.authenticated) {
      send(device, message);
      recipients += 1;
    }
  }
  return recipients;
}

function publisherIdentity(source: unknown): Record<string, unknown> {
  if (source && typeof source === "object" && "data" in source) {
    const socket = source as RelaySocket;
    return { connId: socket.data.connId, deviceId: socket.data.deviceId };
  }
  return { origin: "local" };
}

function frameIdentity(frame: PayloadFrame): Record<string, unknown> {
  return {
    type: frame.type,
    mime: frame.mime,
    bytes: encodedPayloadBytes(frame),
    nonce: frame.nonce,
    frameTs: frame.ts,
  };
}

function transferIdOf(message: TransferControlMessage): string {
  return message.kind === "transfer_offer"
    ? message.offer.transferId
    : message.transferId;
}

function send(socket: RelaySocket, message: RelayMessage): void {
  socket.send(JSON.stringify(message));
}

function sendError(logger: Logger, socket: RelaySocket, code: string, message: string): void {
  logger.warn("client_error_sent", {
    connId: socket.data.connId,
    deviceId: socket.data.deviceId,
    code,
  });
  send(socket, { v: 1, kind: "error", code, message });
}

function parseMessage(rawMessage: string | Buffer): RelayMessage | undefined {
  try {
    return JSON.parse(String(rawMessage)) as RelayMessage;
  } catch {
    return undefined;
  }
}

function randomConnId(): string {
  return Buffer.from(crypto.getRandomValues(new Uint8Array(4))).toString("hex");
}

function randomBase64(byteLength: number): string {
  return Buffer.from(crypto.getRandomValues(new Uint8Array(byteLength))).toString("base64");
}
