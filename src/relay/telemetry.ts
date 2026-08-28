import { readFile } from "node:fs/promises";
import { readdir } from "node:fs/promises";
import { statfs } from "node:fs/promises";
import { cpus, totalmem } from "node:os";
import type { LaptopTelemetry } from "../shared/wire";

type CpuSample = { idle: number; total: number };
let previousCpu: CpuSample | undefined;

export async function sampleLaptopTelemetry(now = Date.now()): Promise<LaptopTelemetry> {
  const [battery, storage, temperature] = await Promise.all([
    readBattery(),
    readStorage(),
    readCpuTemperature(),
  ]);
  const memory = await readMemory();
  const currentCpu = cpuCounters();
  const totalDelta = previousCpu && currentCpu
    ? currentCpu.total - previousCpu.total
    : 0;
  const cpuUsagePercent = previousCpu && currentCpu && totalDelta > 0
    ? clamp((1 - (currentCpu.idle - previousCpu.idle) / totalDelta) * 100)
    : null;
  previousCpu = currentCpu;
  return {
    v: 1,
    kind: "telemetry",
    ts: now,
    batteryPercent: battery?.percent ?? null,
    batteryState: battery?.state ?? null,
    memoryUsedBytes: memory?.used ?? null,
    memoryTotalBytes: memory?.total ?? totalmem(),
    storageUsedBytes: storage?.used ?? null,
    storageTotalBytes: storage?.total ?? null,
    cpuUsagePercent,
    cpuTemperatureCelsius: temperature,
  };
}

async function readMemory(): Promise<{ used: number; total: number } | undefined> {
  try {
    const values = new Map(
      (await readFile("/proc/meminfo", "utf8"))
        .split("\n")
        .map((line) => {
          const match = /^(MemTotal|MemAvailable):\s+(\d+)\s+kB$/.exec(line);
          return match ? [match[1], Number(match[2]) * 1024] : [];
        })
        .filter((entry): entry is [string, number] => entry.length === 2),
    );
    const total = values.get("MemTotal");
    const available = values.get("MemAvailable");
    return total !== undefined && available !== undefined
      ? { used: Math.max(0, total - available), total }
      : undefined;
  } catch {
    return undefined;
  }
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

export async function readCpuTemperature(sysfsRoot = "/sys"): Promise<number | null> {
  const preferredSensors = ["k10temp", "coretemp", "zenpower", "acpitz"];

  // /sys/class/hwmon is the stable kernel interface across CPU vendors. The
  // hwmon number is not stable, so identify sensors by their name instead.
  try {
    const entries = await readdir(`${sysfsRoot}/class/hwmon`);
    const sensors = await Promise.all(entries.map(async (entry) => {
      try {
        const name = (await readFile(`${sysfsRoot}/class/hwmon/${entry}/name`, "utf8")).trim();
        return { entry, name };
      } catch {
        return undefined;
      }
    }));

    for (const name of preferredSensors) {
      for (const sensor of sensors) {
        if (sensor?.name !== name) continue;
        try {
          const value = parseTemperature(await readFile(
            `${sysfsRoot}/class/hwmon/${sensor.entry}/temp1_input`,
            "utf8",
          ));
          if (value !== null) return value;
        } catch {
          // Try the next matching sensor or fallback.
        }
      }
    }
  } catch {
    // Try legacy and thermal-zone paths below.
  }

  // Preserve compatibility with systems exposing the old Waybar path.
  try {
    const roots = await readdir(`${sysfsRoot}/devices/platform/coretemp.0/hwmon`);
    const hwmon = roots.find((entry) => entry.startsWith("hwmon"));
    if (hwmon) {
      const value = parseTemperature(await readFile(
        `${sysfsRoot}/devices/platform/coretemp.0/hwmon/${hwmon}/temp1_input`,
        "utf8",
      ));
      if (value !== null) return value;
    }
  } catch {
    // Try the generic thermal zone below.
  }

  try {
    const entries = await readdir(`${sysfsRoot}/class/thermal`);
    const cpuThermalTypes = new Set([
      "x86_pkg_temp",
      "cpu-thermal",
      "cpu_thermal",
      "k10temp",
    ]);
    for (const entry of entries.filter((value) => value.startsWith("thermal_zone"))) {
      try {
        const type = (await readFile(`${sysfsRoot}/class/thermal/${entry}/type`, "utf8")).trim();
        if (!cpuThermalTypes.has(type)) continue;
        const value = parseTemperature(await readFile(
          `${sysfsRoot}/class/thermal/${entry}/temp`,
          "utf8",
        ));
        if (value !== null) return value;
      } catch {
        // Try the next thermal zone.
      }
    }
  } catch {
    // No usable CPU thermal zone.
  }
  return null;
}

function parseTemperature(raw: string): number | null {
  const trimmed = raw.trim();
  if (trimmed.length === 0) return null;
  const value = Number(trimmed) / 1000;
  return Number.isFinite(value) && value >= -100 && value <= 200 ? value : null;
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
