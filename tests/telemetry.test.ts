import { describe, expect, test } from "bun:test";
import { sampleLaptopTelemetry } from "../src/relay/telemetry";

describe("laptop telemetry sampling", () => {
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
