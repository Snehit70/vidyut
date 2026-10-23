import { verifyPairingProof } from "../shared/auth";
import {
  createRelayProof,
  deriveSessionKey,
  isClientChallenge,
  SessionSealer,
  travelsUnsealed,
} from "../shared/session-seal";
import {
  pairingSecretRef,
  type PairingSecretRef,
} from "./config";
import { handleControlRequest, isControlPath } from "./control-plane";
import {
  isTrustedWebSocketOrigin,
  rejectUntrustedControlRequest,
} from "./local-origin";
import { noopLogger, type Logger } from "./logger";
import { getPairingHost } from "./network";
import { PayloadPool } from "./payload-pool";
import {
  createSetupStatusReader,
  type LaptopSetupStatus,
  type SetupStatusReader,
} from "./setup-status";
import {
  encodedPayloadBytes,
  isBrowseKind,
  isBrowseRequest,
  isPayloadFrame,
  isTransferControlMessage,
  type BrowseAnswer,
  type BrowseRequest,
  type PayloadFrame,
  type RelayHealth,
  type LaptopTelemetry,
  type RelayFeature,
  type RelayMessage,
  type SessionFeature,
  type TransferControlMessage,
} from "../shared/wire";
import type { ClipboardHealth } from "./clipboard-sync";
import type { ClipboardPause } from "./clipboard-pause";
import { sampleLaptopTelemetry } from "./telemetry";

interface RelayOptions {
  hostname: string;
  port: number;
  pairingSecret: string | PairingSecretRef;
  maxPayloadBytes: number;
  pool?: PayloadPool;
  heartbeatIntervalMs?: number;
  staleAfterMs?: number;
  authTimeoutMs?: number;
  logger?: Logger;
  clipboardHealth?: () => ClipboardHealth;
  relayName?: string;
  pairingHost?: string;
  persistPairingSecret?: (secret: string) => Promise<void>;
  transferSnapshot?: () => unknown;
  enqueueLaptopFiles?: (paths: string[]) => Promise<unknown>;
  setupStatus?: SetupStatusReader;
  clipboardPause?: ClipboardPause;
  transferControl?: (
    message: TransferControlMessage,
    sourceDeviceId: string,
  ) => void | Promise<void>;
  deviceDisconnected?: (deviceId: string) => void | Promise<void>;
  deviceConnected?: (
    deviceId: string,
    publishControl: (message: TransferControlMessage) => void,
  ) => void | Promise<void>;
  transferHttp?: (
    request: Request,
    context: { isLoopback: boolean },
  ) => Promise<Response | undefined>;
  telemetry?: () => Promise<LaptopTelemetry>;
  /** Answers the phone reading the laptop's shared folders (ADR 0026). */
  browse?: (request: BrowseRequest) => Promise<BrowseAnswer>;
}

const defaultHeartbeatIntervalMs = 30_000;
const defaultStaleAfterMs = 90_000;
// The phone answers hello within one round trip. A socket that has not proved
// the secret by now is a scanner or a stuck client, and holding it open only
// lets it sit on a challenge.
const defaultAuthTimeoutMs = 10_000;

interface DeviceSocketData {
  connId: string;
  remote: string;
  challenge: string;
  authenticated: boolean;
  deviceId?: string;
  connectedAt: number;
  lastSeen: number;
  telemetrySubscribed: boolean;
  authTimer?: ReturnType<typeof setTimeout>;
  /** Set once `sealed_control` is negotiated; every later control message goes through it. */
  sealer?: SessionSealer;
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
  const pairingSecret = pairingSecretRef(options.pairingSecret);
  const devices = new Set<RelaySocket>();
  const startedAt = Date.now();
  const heartbeatIntervalMs = options.heartbeatIntervalMs ?? defaultHeartbeatIntervalMs;
  // One cached probe per Relay. Probing forks several processes, and the
  // control plane is read on a poll, so an uncached read storms the machine.
  const setupStatusReader = createSetupStatusReader();
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
        notifyDeviceDisconnected(
          devices,
          options.deviceDisconnected,
          socket.data.deviceId,
        );
        socket.terminate();
        continue;
      }
      socket.ping();
    }
  }, heartbeatIntervalMs);
  const sampleTelemetry = options.telemetry ?? sampleLaptopTelemetry;
  const sendTelemetry = (candidates: RelaySocket[]) => {
    const recipients = candidates.filter(isTelemetryRecipient);
    if (recipients.length === 0) return;
    void sampleTelemetry().then(
      (telemetry) => {
        for (const socket of recipients) {
          if (isTelemetryRecipient(socket)) send(socket, telemetry);
        }
      },
      (error) => logger.error("telemetry_sampling_failed", {
        error: error instanceof Error ? error.message : String(error),
      }),
    );
  };
  // Sampling reads /proc and /sys, and every sample wakes the phone's radio.
  // Only phones showing the numbers right now get them.
  const telemetryInterval = setInterval(() => {
    sendTelemetry([...devices]);
  }, 5_000);

  const server = Bun.serve<DeviceSocketData>({
    hostname: options.hostname,
    port: options.port,
    async fetch(request, bunServer) {
      const address = bunServer.requestIP(request);
      const now = Date.now();
      if (
        request.headers.get("upgrade")?.toLowerCase() === "websocket" &&
        !isTrustedWebSocketOrigin(request.headers.get("origin"), bunServer.port ?? options.port)
      ) {
        logger.warn("websocket_origin_rejected", {
          remote: address ? `${address.address}:${address.port}` : "unknown",
        });
        return new Response("Forbidden", { status: 403 });
      }
      if (
        bunServer.upgrade(request, {
          data: {
            connId: randomConnId(),
            remote: address ? `${address.address}:${address.port}` : "unknown",
            challenge: randomBase64(24),
            authenticated: false,
            telemetrySubscribed: false,
            connectedAt: now,
            lastSeen: now,
          },
        })
      ) {
        return undefined;
      }
      const pathname = new URL(request.url).pathname;
      const isLoopback = isLoopbackAddress(address?.address);
      if (pathname.startsWith("/transfer/v1/")) {
        const response = await options.transferHttp?.(request, {
          isLoopback,
        });
        return (
          response ??
          Response.json(
            { code: "transfer_not_found" },
            { status: 404 },
          )
        );
      }
      if (pathname === "/health") {
        const snapshot = healthSnapshot(startedAt, devices, pool.current, options.clipboardHealth?.());
        // The detail (device IPs, what was last copied and when) is for the
        // person at this laptop. Anyone else on the WiFi learns only that a
        // Relay is up.
        return Response.json(isLoopback ? snapshot : { status: snapshot.status });
      }
      if (isControlPath(pathname)) {
        if (!isLoopback) {
          return new Response("Not found", { status: 404 });
        }
        const port = bunServer.port;
        if (port === undefined) {
          return new Response("Relay has no listen port.", { status: 500 });
        }
        const rejection = rejectUntrustedControlRequest(request, port);
        if (rejection) {
          logger.warn("control_request_rejected", { method: request.method, pathname });
          return rejection;
        }
        return handleControlRequest(request, {
          pairingSecret,
          pairingHost: options.pairingHost ?? getPairingHost(options.hostname),
          port,
          relayName: options.relayName ?? "Vidyut Relay",
          authenticatedDeviceCount: () =>
            [...devices].filter((socket) => socket.data.authenticated).length,
          currentPayload: () => pool.current,
          kickDevices() {
            for (const socket of devices) {
              socket.close(1008, "pairing_secret_rotated");
            }
          },
          ...(options.clipboardHealth && {
            clipboardHealth: options.clipboardHealth,
          }),
          ...(options.persistPairingSecret && {
            persistPairingSecret: options.persistPairingSecret,
          }),
          ...(options.transferSnapshot && {
            transferSnapshot: options.transferSnapshot,
          }),
          ...(options.enqueueLaptopFiles && {
            enqueueLaptopFiles: options.enqueueLaptopFiles,
          }),
          ...(options.clipboardPause && {
            clipboardPause: options.clipboardPause,
          }),
          setupStatus: options.setupStatus ?? setupStatusReader,
        });
      }
      return new Response("Vidyut relay", { status: 200 });
    },
    websocket: {
      // Bun's default cap is 16 MiB per message, and a publish carries the
      // ciphertext as base64 inside JSON, so the default silently dropped the
      // socket (1006) for anything over ~12 MiB of plaintext. Size the cap from
      // maxPayloadBytes so an over-limit frame reaches the payload_too_large
      // check below instead.
      maxPayloadLength: websocketMessageLimit(options.maxPayloadBytes),
      open(socket) {
        devices.add(socket);
        logger.info("device_connected", { connId: socket.data.connId, remote: socket.data.remote });
        socket.data.authTimer = setTimeout(() => {
          if (socket.data.authenticated) return;
          logger.warn("auth_failed", {
            connId: socket.data.connId,
            remote: socket.data.remote,
            reason: "auth_timeout",
          });
          socket.close(1008, "auth_timeout");
        }, options.authTimeoutMs ?? defaultAuthTimeoutMs);
        send(socket, {
          v: 1,
          kind: "hello",
          challenge: socket.data.challenge,
          maxPayloadBytes: options.maxPayloadBytes,
          features: options.browse ? [...relayFeatures, "browse_files"] : [...relayFeatures],
        });
      },
      async message(socket, rawMessage) {
        socket.data.lastSeen = Date.now();
        let message = parseMessage(rawMessage);
        if (!message) {
          sendError(logger, socket, "bad_message", "Message must be valid JSON.");
          return;
        }
        const sealer = socket.data.sealer;
        if (sealer && message.kind === "sealed") {
          try {
            message = sealer.open(message);
          } catch (error) {
            // The counters cannot resynchronise after a lost or forged
            // message, so the session ends and the phone reconnects.
            logger.warn("sealed_message_rejected", {
              connId: socket.data.connId,
              deviceId: socket.data.deviceId,
              error: error instanceof Error ? error.message : String(error),
            });
            socket.close(1008, "seal_failed");
            return;
          }
        } else if (sealer && !travelsUnsealed(message)) {
          logger.warn("sealed_message_rejected", {
            connId: socket.data.connId,
            deviceId: socket.data.deviceId,
            kind: message.kind,
            error: "unsealed control message on a sealed session",
          });
          socket.close(1008, "seal_required");
          return;
        }

        if (!socket.data.authenticated) {
          await authenticate(
            logger,
            socket,
            message,
            pairingSecret.value,
            pool.current,
            relayHealth(options.relayName ?? "Vidyut Relay", options.clipboardHealth?.()),
          );
          if (socket.data.authenticated) {
            clearTimeout(socket.data.authTimer);
            notifyDeviceConnected(
              options.deviceConnected,
              socket.data.deviceId,
              (message) => send(socket, message),
            );
            sendTelemetry([socket]);
          }
          return;
        }

        if (message.kind === "telemetry_subscribe") {
          const active = message.active === true;
          const changed = socket.data.telemetrySubscribed !== active;
          socket.data.telemetrySubscribed = active;
          if (active && changed) sendTelemetry([socket]);
          return;
        }

        if (isBrowseKind(message.kind)) {
          await answerBrowse(logger, socket, message, options.browse);
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

        const clockOffsetMs = senderClockOffset(message.sentAt);
        const accepted = await pool.publish(
          message.frame,
          socket,
          message.frame.ts + clockOffsetMs,
        );
        if (!accepted) {
          logger.warn("payload_stale_dropped", {
            connId: socket.data.connId,
            deviceId: socket.data.deviceId,
            ...frameIdentity(message.frame),
            clockOffsetMs,
            currentTs: pool.current?.ts,
          });
        }
        send(socket, {
          v: 1,
          kind: "ack",
          ts: message.frame.ts,
          ...(!accepted && { stale: true as const }),
        });
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
        clearTimeout(socket.data.authTimer);
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
        notifyDeviceDisconnected(
          devices,
          options.deviceDisconnected,
          socket.data.deviceId,
        );
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
      clearInterval(telemetryInterval);
      unsubscribe();
      server.stop(true);
      devices.clear();
    },
  };
}

/**
 * How far the sender's clock is behind the Relay's (negative when ahead),
 * measured at receipt. Includes the one-way network delay, which is noise at
 * the scale of clipboard races. Senders that predate `sentAt` get 0.
 */
function senderClockOffset(sentAt: unknown): number {
  if (typeof sentAt !== "number" || !Number.isFinite(sentAt)) return 0;
  return Date.now() - sentAt;
}

const websocketEnvelopeBytes = 64 * 1024;

export function websocketMessageLimit(maxPayloadBytes: number): number {
  return Math.ceil(maxPayloadBytes / 3) * 4 + websocketEnvelopeBytes;
}

const relayFeatures: readonly RelayFeature[] = ["telemetry_subscribe", "relay_proof", "sealed_control"];

function isTelemetryRecipient(socket: RelaySocket): boolean {
  return socket.data.authenticated && socket.data.telemetrySubscribed;
}

function notifyDeviceDisconnected(
  devices: Set<RelaySocket>,
  callback: RelayOptions["deviceDisconnected"],
  deviceId: string | undefined,
): void {
  if (!callback || !deviceId) return;
  if ([...devices].some(
    (socket) =>
      socket.data.authenticated && socket.data.deviceId === deviceId,
  )) {
    return;
  }
  void Promise.resolve()
    .then(() => callback(deviceId))
    .catch(() => undefined);
}

function notifyDeviceConnected(
  callback: RelayOptions["deviceConnected"],
  deviceId: string | undefined,
  publishControl: (message: TransferControlMessage) => void,
): void {
  if (!callback || !deviceId) return;
  void Promise.resolve()
    .then(() => callback(deviceId, publishControl))
    .catch(() => undefined);
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
  // A phone that predates telemetry_subscribe never asks, so it keeps the
  // always-on stream it was built against.
  socket.data.telemetrySubscribed = !(
    Array.isArray(message.features) &&
    message.features.includes("telemetry_subscribe")
  );
  // A phone that sends a clientChallenge wants this Relay to prove it holds
  // the secret too. Older phones send none and get the one-way handshake.
  const clientChallenge = isClientChallenge(message.clientChallenge) ? message.clientChallenge : undefined;
  const sessionFeatures: SessionFeature[] =
    clientChallenge && Array.isArray(message.features) && message.features.includes("sealed_control")
      ? ["sealed_control"]
      : [];
  logger.info("auth_ok", {
    connId: socket.data.connId,
    deviceId: message.deviceId,
    msSinceConnect: Date.now() - socket.data.connectedAt,
    relayProof: clientChallenge !== undefined,
    sealed: sessionFeatures.includes("sealed_control"),
  });
  send(socket, {
    v: 1,
    kind: "auth_ok",
    health,
    ...(clientChallenge && {
      relayProof: createRelayProof(
        pairingSecret,
        socket.data.challenge,
        clientChallenge,
        sessionFeatures,
        message.deviceId,
      ),
      features: sessionFeatures,
    }),
  });
  if (clientChallenge && sessionFeatures.includes("sealed_control")) {
    socket.data.sealer = new SessionSealer(
      deriveSessionKey(pairingSecret, socket.data.challenge, clientChallenge, message.deviceId),
      "relay_to_phone",
    );
  }
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

async function answerBrowse(
  logger: Logger,
  socket: RelaySocket,
  message: unknown,
  browse: RelayOptions["browse"],
): Promise<void> {
  const raw = message as Record<string, unknown>;
  const requestId = typeof raw.requestId === "string" ? raw.requestId : "";
  const reply = (answer: BrowseAnswer) =>
    send(socket, { v: 1, kind: "browse_result", requestId, ...answer });
  // Listings name the laptop's files, so they travel sealed or not at all.
  if (!socket.data.sealer) {
    reply({ ok: false, code: "seal_required", message: "Update Vidyut on the phone to browse the laptop." });
    return;
  }
  if (!isBrowseRequest(message)) {
    reply({ ok: false, code: "bad_request", message: "The browse request was malformed." });
    return;
  }
  if (!browse) {
    reply({ ok: false, code: "browse_unavailable", message: "This laptop does not share folders." });
    return;
  }
  try {
    const answer = await browse(message);
    if (message.kind === "browse_pull" && answer.ok && "queued" in answer) {
      logger.info("browse_pull_queued", {
        connId: socket.data.connId,
        deviceId: socket.data.deviceId,
        files: answer.queued.files,
        bytes: answer.queued.bytes,
      });
    }
    reply(answer);
  } catch (error) {
    logger.error("browse_failed", {
      connId: socket.data.connId,
      deviceId: socket.data.deviceId,
      kind: message.kind,
      error: error instanceof Error ? error.message : String(error),
    });
    reply({ ok: false, code: "browse_failed", message: "The laptop could not read that." });
  }
}

function transferIdOf(message: TransferControlMessage): string {
  return message.kind === "transfer_offer"
    ? message.offer.transferId
    : message.transferId;
}

function send(socket: RelaySocket, message: RelayMessage): void {
  const sealer = socket.data.sealer;
  socket.send(JSON.stringify(sealer && !travelsUnsealed(message) ? sealer.seal(message) : message));
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
