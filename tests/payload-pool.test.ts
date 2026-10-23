import { describe, expect, test } from "bun:test";
import { PayloadPool } from "../src/relay/payload-pool";
import type { PayloadFrame } from "../src/shared/wire";

const frame: PayloadFrame = {
  v: 1,
  type: "text",
  mime: "text/plain",
  origin: "phone",
  ts: 1_800_000_030_000,
  nonce: "nonce",
  payload: "payload",
};

describe("payload pool", () => {
  test("keeps the published payload even when a subscriber fails", async () => {
    const pool = new PayloadPool();
    pool.subscribe(() => {
      throw new Error("subscriber failed");
    });

    await expect(pool.publish(frame)).resolves.toBe(true);
    expect(pool.current).toEqual(frame);
  });

  test("drops a frame ordered before the current one, but not a verbatim republish", async () => {
    const pool = new PayloadPool();
    await pool.publish(frame, "phone", 1_000);
    const older = { ...frame, nonce: "older", ts: frame.ts + 5 };
    await expect(pool.publish(older, "laptop", 999)).resolves.toBe(false);
    // Same nonce re-sent later stamps an earlier order ts; still accepted.
    await expect(pool.publish(frame, "phone", 998)).resolves.toBe(true);
    expect(pool.current).toEqual(frame);
  });
});
