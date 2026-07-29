import { mkdir, readFile, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, join } from "node:path";

export type LogLevel = "debug" | "info" | "warn" | "error";

export interface RelayConfig {
  pairingSecret: string;
  port: number;
  maxPayloadBytes: number;
  deviceId: string;
  logLevel: LogLevel;
  transferDestination: string;
  maxTransferFileBytes: number;
}

export const defaultRelayPort = 17321;
export const defaultMaxPayloadBytes = 25 * 1024 * 1024;
export const defaultMaxTransferFileBytes = 1024 * 1024 * 1024;

export async function loadOrCreateRelayConfig(path: string): Promise<RelayConfig> {
  try {
    const parsed = JSON.parse(await readFile(path, "utf8")) as Partial<RelayConfig>;
    const config = normalizeConfig(parsed);
    if (
      parsed.transferDestination !== config.transferDestination ||
      parsed.maxTransferFileBytes !== config.maxTransferFileBytes
    ) {
      await writeConfig(path, config);
    }
    return config;
  } catch (error) {
    if (!isMissingFile(error)) throw error;
  }

  const config: RelayConfig = {
    pairingSecret: randomSecret(),
    port: defaultRelayPort,
    maxPayloadBytes: defaultMaxPayloadBytes,
    deviceId: "laptop",
    logLevel: "info",
    transferDestination: join(homedir(), "Downloads", "Vidyut"),
    maxTransferFileBytes: defaultMaxTransferFileBytes,
  };
  await writeConfig(path, config);
  return config;
}

function normalizeConfig(config: Partial<RelayConfig>): RelayConfig {
  if (
    typeof config.pairingSecret !== "string" ||
    typeof config.port !== "number" ||
    typeof config.maxPayloadBytes !== "number" ||
    typeof config.deviceId !== "string" ||
    !isLogLevel(config.logLevel)
  ) {
    throw new Error("Relay config is missing required fields.");
  }
  return {
    pairingSecret: config.pairingSecret,
    port: config.port,
    maxPayloadBytes: config.maxPayloadBytes,
    deviceId: config.deviceId,
    logLevel: config.logLevel,
    transferDestination:
      typeof config.transferDestination === "string" &&
      config.transferDestination.length > 0
        ? config.transferDestination
        : join(homedir(), "Downloads", "Vidyut"),
    maxTransferFileBytes:
      typeof config.maxTransferFileBytes === "number" &&
      Number.isSafeInteger(config.maxTransferFileBytes) &&
      config.maxTransferFileBytes > 0
        ? config.maxTransferFileBytes
        : defaultMaxTransferFileBytes,
  };
}

async function writeConfig(path: string, config: RelayConfig): Promise<void> {
  await mkdir(dirname(path), { recursive: true });
  await writeFile(path, `${JSON.stringify(config, null, 2)}\n`, { mode: 0o600 });
}

function isLogLevel(value: unknown): value is LogLevel {
  return (
    value === "debug" ||
    value === "info" ||
    value === "warn" ||
    value === "error"
  );
}

function randomSecret(): string {
  return Buffer.from(crypto.getRandomValues(new Uint8Array(32))).toString("base64url");
}

function isMissingFile(error: unknown): boolean {
  return Boolean(error && typeof error === "object" && "code" in error && error.code === "ENOENT");
}
