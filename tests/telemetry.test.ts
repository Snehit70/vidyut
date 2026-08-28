import { describe, expect, test } from "bun:test";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { readCpuTemperature, sampleLaptopTelemetry } from "../src/relay/telemetry";

async function withSysfs(files: Record<string, string>, run: (root: string) => Promise<void>) {
  const root = await mkdtemp(join(tmpdir(), "vidyut-telemetry-"));
  try {
    for (const [path, value] of Object.entries(files)) {
      const file = join(root, path);
      await mkdir(join(file, ".."), { recursive: true });
      await writeFile(file, value);
    }
    await run(root);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
}

describe("laptop telemetry sampling", () => {
  test("prefers k10temp and skips malformed readings", async () => {
    await withSysfs({
      "class/hwmon/hwmon0/name": "coretemp\n",
      "class/hwmon/hwmon0/temp1_input": "65000\n",
      "class/hwmon/hwmon1/name": "k10temp\n",
      "class/hwmon/hwmon1/temp1_input": "41500\n",
    }, async (root) => {
      expect(await readCpuTemperature(root)).toBe(41.5);
    });

    await withSysfs({
      "class/hwmon/hwmon0/name": "k10temp\n",
      "class/hwmon/hwmon0/temp1_input": "\n",
      "class/thermal/thermal_zone0/type": "x86_pkg_temp\n",
      "class/thermal/thermal_zone0/temp": "43000\n",
    }, async (root) => {
      expect(await readCpuTemperature(root)).toBe(43);
    });
  });

  test("does not treat a non-CPU thermal zone as CPU temperature", async () => {
    await withSysfs({
      "class/thermal/thermal_zone0/type": "acpitz\n",
      "class/thermal/thermal_zone0/temp": "37000\n",
    }, async (root) => {
      expect(await readCpuTemperature(root)).toBeNull();
    });
  });

  test("samples system telemetry conforming to the wire contract", async () => {
    const fixedTs = 1_700_000_000_000;
    const telemetry = await sampleLaptopTelemetry(fixedTs);

    expect(telemetry.v).toBe(1);
    expect(telemetry.kind).toBe("telemetry");
    expect(telemetry.ts).toBe(fixedTs);

    if (telemetry.batteryPercent !== null) {
      expect(telemetry.batteryPercent).toBeGreaterThanOrEqual(0);
      expect(telemetry.batteryPercent).toBeLessThanOrEqual(100);
      expect(["charging", "on_battery", "plugged_in"]).toContain(telemetry.batteryState!);
    }

    if (telemetry.memoryTotalBytes !== null) {
      expect(telemetry.memoryTotalBytes).toBeGreaterThan(0);
      expect(telemetry.memoryUsedBytes).toBeGreaterThanOrEqual(0);
      expect(telemetry.memoryUsedBytes!).toBeLessThanOrEqual(telemetry.memoryTotalBytes);
    }

    if (telemetry.storageTotalBytes !== null) {
      expect(telemetry.storageTotalBytes).toBeGreaterThan(0);
      expect(telemetry.storageUsedBytes).toBeGreaterThanOrEqual(0);
      expect(telemetry.storageUsedBytes!).toBeLessThanOrEqual(telemetry.storageTotalBytes);
    }

    if (telemetry.cpuUsagePercent !== null) {
      expect(telemetry.cpuUsagePercent).toBeGreaterThanOrEqual(0);
      expect(telemetry.cpuUsagePercent).toBeLessThanOrEqual(100);
    }

    if (telemetry.cpuTemperatureCelsius !== null) {
      expect(telemetry.cpuTemperatureCelsius).toBeGreaterThan(0);
      expect(telemetry.cpuTemperatureCelsius).toBeLessThan(150);
    }
  });
});
