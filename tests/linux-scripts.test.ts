import { describe, expect, test } from "bun:test";
import { readFile } from "node:fs/promises";

describe("Linux helper scripts", () => {
  test("file sending and Transfer history do not fall back to yad, zenity, or kdialog", async () => {
    const send = await readFile("scripts/vidyut-send", "utf8");
    const history = await readFile("scripts/vidyut-transfer-history", "utf8");
    for (const text of [send, history]) {
      expect(text).not.toMatch(/\byad\b/);
      expect(text).not.toMatch(/\bzenity\b/);
      expect(text).not.toMatch(/\bkdialog\b/);
    }
    expect(send).toContain("vidyut-shell");
    expect(history).toContain("vidyut-shell");
  });
});
