import { describe, expect, test } from "bun:test";
import {
  startClipboardSync,
  type WatchableClipboardAdapter,
} from "../src/relay/clipboard-sync";
import { PayloadPool } from "../src/relay/payload-pool";
import { encryptPayload } from "../src/shared/crypto";
import { isOpenableLink, openLinkWith } from "../src/relay/open-link";
import type { ClipboardPayload, ProcessResult, ProcessRunner } from "../src/relay/clipboard";
import type { PayloadType } from "../src/shared/wire";

class FakeClipboard implements WatchableClipboardAdapter {
  payload: ClipboardPayload | undefined;
  writes: ClipboardPayload[] = [];

  async read() {
    return this.payload;
  }

  async write(payload: ClipboardPayload) {
    this.writes.push(payload);
    this.payload = payload;
  }

  watch() {
    return () => {};
  }
}

class RecordingRunner implements ProcessRunner {
  calls: Array<{ command: string; args: string[] }> = [];
  exitCode = 0;
  stderr = "";

  async run(command: string, args: string[]): Promise<ProcessResult> {
    this.calls.push({ command, args });
    return {
      exitCode: this.exitCode,
      stdout: new Uint8Array(),
      stderr: this.stderr,
    };
  }

  watch() {
    return () => {};
  }
}

const encoder = new TextEncoder();

async function deliverLink(
  text: string,
  options: {
    openLink?: (url: string) => Promise<void>;
    /** Set when no launch is expected, so the helper does not wait for one. */
    skipLaunchWait?: boolean;
  } = {},
) {
  const pool = new PayloadPool();
  const clipboard = new FakeClipboard();
  const opened: string[] = [];
  const stop = startClipboardSync({
    clipboard,
    pool,
    pairingSecret: "pairing-secret",
    origin: "laptop",
    now: () => 1_800_000_020_001,
    openLink: async (url) => {
      opened.push(url);
      await options.openLink?.(url);
    },
  });
  const frame = await encryptPayload(
    { type: "link" as PayloadType, mime: "text/plain", origin: "phone", ts: 1_800_000_020_002 },
    encoder.encode(text),
    "pairing-secret",
  );
  await pool.publish(frame);
  // The write lands after a 200k-iteration PBKDF2 decrypt, so poll rather than
  // guess at a sleep. The launch after it is deliberately not awaited on the
  // pool path, so wait for that too.
  await waitUntil(() => clipboard.writes.length === 1, "clipboard write");
  if (!options.skipLaunchWait) {
    await waitUntil(() => opened.length > 0, "link launch");
  }
  stop();
  return { clipboard, opened };
}

describe("link payloads", () => {
  test("writes the URL to the clipboard and opens it", async () => {
    const { clipboard, opened } = await deliverLink("https://example.com/a?b=c");

    // Both halves happen, which is the whole point: the address stays
    // pasteable even if the tab is closed.
    expect(clipboard.writes).toHaveLength(1);
    expect(new TextDecoder().decode(clipboard.writes[0]!.data)).toBe(
      "https://example.com/a?b=c",
    );
    expect(opened).toEqual(["https://example.com/a?b=c"]);
  });

  test("leaves a text payload alone", async () => {
    const pool = new PayloadPool();
    const clipboard = new FakeClipboard();
    const opened: string[] = [];
    const stop = startClipboardSync({
      clipboard,
      pool,
      pairingSecret: "pairing-secret",
      origin: "laptop",
      now: () => 1,
      openLink: async (url) => {
        opened.push(url);
      },
    });
    const frame = await encryptPayload(
      { type: "text", mime: "text/plain", origin: "phone", ts: 2 },
      encoder.encode("https://example.com"),
      "pairing-secret",
    );
    await pool.publish(frame);
    await waitUntil(() => clipboard.writes.length === 1, "clipboard write");
    stop();

    // A URL sent as plain text is still just text. The type is the signal, not
    // the content, or every copied link would open a browser.
    expect(opened).toEqual([]);
    expect(clipboard.writes).toHaveLength(1);
  });

  test("refuses to open what is not an http URL, even when tagged a link", async () => {
    const { clipboard, opened } = await deliverLink("file:///etc/passwd", {
      // No launch is expected, so deliverLink must not wait for one.
      skipLaunchWait: true,
    });

    // The clipboard half still happens, so the payload is never lost.
    expect(clipboard.writes).toHaveLength(1);
    expect(opened).toEqual([]);
  });

  test("still writes the clipboard when the launch fails", async () => {
    const { clipboard, opened } = await deliverLink("https://example.com", {
      openLink: async () => {
        throw new Error("xdg-open exploded");
      },
    });

    expect(opened).toEqual(["https://example.com"]);
    expect(clipboard.writes).toHaveLength(1);
  });

  test("a link with no launcher still reaches the clipboard", async () => {
    const pool = new PayloadPool();
    const clipboard = new FakeClipboard();
    const stop = startClipboardSync({
      clipboard,
      pool,
      pairingSecret: "pairing-secret",
      origin: "laptop",
      now: () => 1,
    });
    const frame = await encryptPayload(
      { type: "link", mime: "text/plain", origin: "phone", ts: 2 },
      encoder.encode("https://example.com"),
      "pairing-secret",
    );
    await pool.publish(frame);
    await waitUntil(() => clipboard.writes.length === 1, "clipboard write");
    stop();

    expect(clipboard.writes).toHaveLength(1);
  });
});

describe("isOpenableLink", () => {
  test("accepts plain http and https URLs", () => {
    for (const value of [
      "https://example.com",
      "http://example.com/a/b?c=d#e",
      "https://sub.example.co.uk:8443/x",
      "http://localhost:3000",
      "http://192.168.1.5:17321",
    ]) {
      expect(isOpenableLink(value)).toBe(true);
    }
  });

  test("refuses anything that is not an explicit http URL", () => {
    for (const value of [
      "",
      "example.com",
      "localhost:3000",
      "file:///etc/passwd",
      "javascript:alert(1)",
      "data:text/html,<h1>x</h1>",
      "mailto:a@b.com",
      // Whitespace could smuggle a second argument past a naive join.
      "https://example.com/ --version",
      "https://example.com/\nrm -rf /",
      "a".repeat(2100),
    ]) {
      expect(isOpenableLink(value)).toBe(false);
    }
  });
});

describe("openLinkWith", () => {
  test("hands the URL to xdg-open as a single argument", async () => {
    const runner = new RecordingRunner();
    await openLinkWith(runner, "https://example.com/a b");

    expect(runner.calls).toEqual([
      { command: "xdg-open", args: ["https://example.com/a b"] },
    ]);
  });

  test("reports a non-zero exit as a failure", async () => {
    const runner = new RecordingRunner();
    runner.exitCode = 3;
    runner.stderr = "no method available";

    await expect(openLinkWith(runner, "https://example.com")).rejects.toThrow(
      /no method available/,
    );
  });
});

async function waitUntil(
  predicate: () => boolean,
  label: string,
): Promise<void> {
  const deadline = Date.now() + 2000;
  while (!predicate() && Date.now() < deadline) {
    await Bun.sleep(1);
  }
  if (!predicate()) throw new Error(`timed out waiting for ${label}`);
}
