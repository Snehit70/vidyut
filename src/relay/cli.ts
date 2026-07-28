#!/usr/bin/env bun
import { homedir, hostname } from "node:os";
import { join } from "node:path";
import { createWaylandClipboardAdapter } from "./clipboard";
import { startClipboardSync, type ClipboardHealth } from "./clipboard-sync";
import { loadOrCreateRelayConfig, type LogLevel } from "./config";
import { createLogger } from "./logger";
import { startMdnsAdvertisement } from "./mdns";
import { getLanIPv4Addresses, getPairingHost } from "./network";
import { createPairingCode } from "./pairing";
import { ensurePortFree } from "./port-check";
import { createRelay } from "./relay";

interface CliOptions {
  host: string;
  configPath: string;
  port?: number;
  maxPayloadBytes?: number;
  logLevel?: LogLevel;
  clipboard: boolean;
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

await ensurePortFree(host, port);

let clipboardHealth: ClipboardHealth = options.clipboard
  ? { enabled: true, status: "starting", watcher: "wl-paste --watch" }
  : { enabled: false, status: "disabled" };
const relay = await createRelay({
  hostname: host,
  port,
  pairingSecret: config.pairingSecret,
  maxPayloadBytes,
  logger,
  relayName,
  clipboardHealth: () => clipboardHealth,
});

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
`);
  process.exit(0);
}
