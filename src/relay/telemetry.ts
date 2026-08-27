import { readFile } from "node:fs/promises";
import { readdir } from "node:fs/promises";
import { statfs } from "node:fs/promises";
import { cpus, freemem, totalmem } from "node:os";
import type { LaptopTelemetry } from "../shared/wire";

type CpuSample = { idle: number; total: number };
let previousCpu: CpuSample | undefined;

export async function sampleLaptopTelemetry(now = Date.now()): Promise<LaptopTelemetry> {
  const [battery, storage, temperature] = await Promise.all([
    readBattery(),
    readStorage(),
    readWaybarTemperature(),
  ]);
  const currentCpu = cpuCounters();
  const cpuUsagePercent = previousCpu && currentCpu
    ? clamp((1 - (currentCpu.idle - previousCpu.idle) / (currentCpu.total - previousCpu.total)) * 100)
    : null;
  previousCpu = currentCpu;
  return {
    v: 1,
    kind: "telemetry",
    ts: now,
    batteryPercent: battery?.percent ?? null,
    batteryState: battery?.state ?? null,
    memoryUsedBytes: totalmem() - freemem(),
    memoryTotalBytes: totalmem(),
    storageUsedBytes: storage?.used ?? null,
    storageTotalBytes: storage?.total ?? null,
    cpuUsagePercent,
    cpuTemperatureCelsius: temperature,
  };
}

async function readBattery(): Promise<{ percent: number; state: LaptopTelemetry["batteryState"] } | undefined> {
  try {
    const entries = await readdir("/sys/class/power_supply");
    const battery = entries.find((entry) => entry.startsWith("BAT"));
    if (!battery) return undefined;
    const root = `/sys/class/power_supply/${battery}`;
    const [capacity, status] = await Promise.all([
      readFile(`${root}/capacity`, "utf8"),
      readFile(`${root}/status`, "utf8"),
    ]);
    const percent = Number.parseInt(capacity.trim(), 10);
    if (!Number.isFinite(percent)) return undefined;
    const normalized = status.trim().toLowerCase();
    const state = normalized === "charging" ? "charging" : normalized === "full" ? "plugged_in" : "on_battery";
    return { percent: Math.max(0, Math.min(100, percent)), state };
  } catch { return undefined; }
}

async function readStorage(): Promise<{ used: number; total: number } | undefined> {
  try {
    const value = await statfs("/");
    const total = Number(value.blocks) * Number(value.bsize);
    const free = Number(value.bfree) * Number(value.bsize);
    return { used: total - free, total };
  } catch { return undefined; }
}

async function readWaybarTemperature(): Promise<number | null> {
  try {
    const roots = await readdir("/sys/devices/platform/coretemp.0/hwmon");
    const hwmon = roots.find((entry) => entry.startsWith("hwmon"));
    if (!hwmon) return null;
    const raw = await readFile(`/sys/devices/platform/coretemp.0/hwmon/${hwmon}/temp1_input`, "utf8");
    const value = Number(raw.trim()) / 1000;
    return Number.isFinite(value) ? value : null;
  } catch { return null; }
}

function cpuCounters(): CpuSample | undefined {
  const aggregate = cpus().reduce((result, cpu) => {
    const values = Object.values(cpu.times);
    result.idle += cpu.times.idle;
    result.total += values.reduce((sum, value) => sum + value, 0);
    return result;
  }, { idle: 0, total: 0 });
  return aggregate.total > 0 ? aggregate : undefined;
}

function clamp(value: number): number { return Math.max(0, Math.min(100, value)); }
