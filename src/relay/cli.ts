#!/usr/bin/env bun
import { homedir, hostname } from "node:os";
import { dirname, join } from "node:path";
import { readFile } from "node:fs/promises";
import { createWaylandClipboardAdapter } from "./clipboard";
import { startClipboardSync, type ClipboardHealth } from "./clipboard-sync";
import { loadOrCreateRelayConfig, type LogLevel } from "./config";
import { createLogger } from "./logger";
import { startMdnsAdvertisement } from "./mdns";
import { getLanIPv4Addresses, getPairingHost } from "./network";
import { createPairingCode } from "./pairing";
import { ensurePortFree } from "./port-check";
import { createRelay } from "./relay";
import { createTransferHttpAuth } from "../shared/transfer-http-auth";
import { sha256Hex } from "../shared/transfer-crypto";
import {
  JsonTransferQueueStorage,
  TransferQueue,
} from "../transfer/transfer-queue";
import { TransferCoordinator } from "../transfer/transfer-coordinator";
import {
  defaultTransferChunkBytes,
  LaptopTransferDataPlane,
} from "../transfer/laptop-data-plane";

interface CliOptions {
  host: string;
  configPath: string;
  port?: number;
  maxPayloadBytes?: number;
  logLevel?: LogLevel;
  clipboard: boolean;
  sendPaths: string[];
  showTransfers: boolean;
}

const options = parseArgs(Bun.argv.slice(2));
const config = await loadOrCreateRelayConfig(options.configPath);
const host = options.host;
const port = options.port ?? config.port;
const maxPayloadBytes = options.maxPayloadBytes ?? config.maxPayloadBytes;
const logLevel = options.logLevel ?? config.logLevel;
const logger = createLogger(logLevel);
const pairingHost = getPairingHost(host);
const relayName = hostname().trim() || "Vidyut Relay";

if (options.showTransfers) {
  await printTransfers(options.configPath);
  process.exit(0);
}

if (options.sendPaths.length > 0) {
  await sendFilesToRunningRelay({
    host,
    port,
    pairingSecret: config.pairingSecret,
    paths: options.sendPaths,
  });
  process.exit(0);
}

await ensurePortFree(host, port);

let clipboardHealth: ClipboardHealth = options.clipboard
  ? { enabled: true, status: "starting", watcher: "wl-paste --watch" }
  : { enabled: false, status: "disabled" };
const transferQueue = await TransferQueue.open({
  storage: new JsonTransferQueueStorage(
    join(dirname(options.configPath), "transfers.json"),
  ),
});
let relay: Awaited<ReturnType<typeof createRelay>>;
const transferCoordinator = new TransferCoordinator({
  queue: transferQueue,
  destinationDirectory: config.transferDestination,
  maxFileBytes: config.maxTransferFileBytes,
  publishControl: (message) => relay.publishTransferControl(message),
});
const transferDataPlane = new LaptopTransferDataPlane(
  config.pairingSecret,
  transferQueue,
  defaultTransferChunkBytes,
  (message) => relay.publishTransferControl(message),
  async () => {
    await transferCoordinator.activateNext();
  },
  (paths) => transferCoordinator.enqueueLaptopFiles(paths),
);
relay = await createRelay({
  hostname: host,
  port,
  pairingSecret: config.pairingSecret,
  maxPayloadBytes,
  logger,
  relayName,
  clipboardHealth: () => clipboardHealth,
  transferControl: (message, sourceDeviceId) =>
    transferCoordinator.handleControl(message, sourceDeviceId),
  transferHttp: transferDataPlane.handle.bind(transferDataPlane),
});
await transferCoordinator.start();

const stopClipboard = options.clipboard
  ? startClipboardSync({
      clipboard: createWaylandClipboardAdapter(),
      pool: relay.pool,
      pairingSecret: config.pairingSecret,
      origin: config.deviceId,
      now: Date.now,
      logger,
      onHealthChange: (health) => {
        clipboardHealth = health;
        relay.publishHealth();
      },
    })
  : () => undefined;
const stopMdns = startMdnsAdvertisement({
  instanceName: relayName,
  hostName: hostname().replace(/[^a-zA-Z0-9-]/g, "-") || "vidyut-relay",
  port,
  addresses: getLanIPv4Addresses(),
});

const pairingCode = createPairingCode({
  host: pairingHost,
  port,
  pairingSecret: config.pairingSecret,
  relayName,
});

logger.info("relay_started", { url: relay.url, maxPayloadBytes, clipboard: options.clipboard });
console.log("Vidyut pairing code:");
console.log(pairingCode.qr);
console.log(pairingCode.raw);
console.log("Manual entry: %s", pairingCode.manual);

for (const signal of ["SIGINT", "SIGTERM"] as const) {
  process.on(signal, async () => {
    logger.info("relay_stopping", { signal });
    stopClipboard();
    stopMdns();
    await relay.stop();
    process.exit(0);
  });
}

function parseArgs(args: string[]): CliOptions {
  const options: CliOptions = {
    host: "0.0.0.0",
    configPath: join(homedir(), ".config", "vidyut", "relay.json"),
    clipboard: true,
    sendPaths: [],
    showTransfers: false,
  };

  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index];
    const next = args[index + 1];
    if (arg === "--host" && next) {
      options.host = next;
      index += 1;
    } else if (arg === "--port" && next) {
      options.port = parsePositiveInteger("--port", next);
      index += 1;
    } else if (arg === "--config" && next) {
      options.configPath = next;
      index += 1;
    } else if (arg === "--max-payload-bytes" && next) {
      options.maxPayloadBytes = parsePositiveInteger("--max-payload-bytes", next);
      index += 1;
    } else if (arg === "--log-level" && next && isLogLevel(next)) {
      options.logLevel = next;
      index += 1;
    } else if (arg === "--no-clipboard") {
      options.clipboard = false;
    } else if (arg === "--send" && next) {
      options.sendPaths.push(next);
      index += 1;
    } else if (arg === "--transfers") {
      options.showTransfers = true;
    } else if (arg === "--help") {
      printHelpAndExit();
    } else {
      throw new Error(`Unknown or incomplete argument: ${arg}`);
    }
  }

  return options;
}

function isLogLevel(value: string): value is LogLevel {
  return value === "debug" || value === "info" || value === "warn" || value === "error";
}

function parsePositiveInteger(flag: string, value: string): number {
  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed <= 0) {
    throw new Error(`${flag} must be a positive integer.`);
  }
  return parsed;
}

function printHelpAndExit(): never {
  console.log(`Usage: vidyut-relay [options]

Options:
  --host <host>                 Host to bind (default: 0.0.0.0)
  --port <port>                 Relay port (default: config or 17321)
  --config <path>               Relay config path
  --max-payload-bytes <bytes>   Maximum encrypted payload size
  --log-level <level>           debug | info | warn | error
  --no-clipboard                Run protocol relay without Wayland clipboard sync
  --send <path>                 Queue a file through the running relay (repeatable)
  --transfers                   Print transfer queue and history
`);
  process.exit(0);
}

async function printTransfers(configPath: string): Promise<void> {
  let batches: ReturnType<TransferQueue["snapshot"]>["batches"];
  try {
    const snapshot = JSON.parse(
      await readFile(join(dirname(configPath), "transfers.json"), "utf8"),
    ) as ReturnType<TransferQueue["snapshot"]>;
    batches = [...snapshot.batches].reverse();
  } catch (error) {
    if (
      error &&
      typeof error === "object" &&
      "code" in error &&
      error.code === "ENOENT"
    ) {
      console.log("No file transfers yet.");
      return;
    }
    throw error;
  }
  if (batches.length === 0) {
    console.log("No file transfers yet.");
    return;
  }
  for (const batch of batches) {
    const direction =
      batch.direction === "laptop_to_phone" ? "Sent" : "Received";
    console.log(`${direction} · ${batch.status} · ${new Date(batch.createdAtMs).toLocaleString()}`);
    for (const file of batch.files) {
      const progress = file.size === 0
        ? 100
        : Math.floor((file.confirmedOffset / file.size) * 100);
      console.log(`  ${file.filename} · ${file.status} · ${progress}%`);
    }
  }
}

async function sendFilesToRunningRelay({
  host,
  port,
  pairingSecret,
  paths,
}: {
  host: string;
  port: number;
  pairingSecret: string;
  paths: string[];
}): Promise<void> {
  const body = new TextEncoder().encode(JSON.stringify(paths));
  const digest = await sha256Hex(body);
  const pathAndQuery = `/transfer/v1/local/enqueue?digest=${digest}`;
  const auth = await createTransferHttpAuth({
    pairingSecret,
    method: "POST",
    pathAndQuery,
  });
  const localHost = host === "0.0.0.0" || host === "::" ? "127.0.0.1" : host;
  let response: Response;
  try {
    response = await fetch(`http://${localHost}:${port}${pathAndQuery}`, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-vidyut-date": auth.date,
        authorization: auth.authorization,
      },
      body: exactArrayBuffer(body),
      signal: AbortSignal.timeout(30_000),
    });
  } catch {
    throw new Error(
      "The Vidyut relay is not running. Start the user service before sending files.",
    );
  }
  const result = (await response.json()) as {
    offer?: { transferId?: string; files?: unknown[] };
    message?: string;
  };
  if (!response.ok) {
    throw new Error(result.message ?? `Relay rejected the files (${response.status}).`);
  }
  console.log(
    `Queued ${result.offer?.files?.length ?? paths.length} file(s) as ${result.offer?.transferId ?? "a transfer"}.`,
  );
}

function exactArrayBuffer(bytes: Uint8Array): ArrayBuffer {
  const buffer = new ArrayBuffer(bytes.byteLength);
  new Uint8Array(buffer).set(bytes);
  return buffer;
}
