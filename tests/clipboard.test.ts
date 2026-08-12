import { describe, expect, test } from "bun:test";
import {
  BunProcessRunner,
  createWaylandClipboardAdapter,
  type ProcessRunner,
  type RunOptions,
} from "../src/relay/clipboard";

class FakeRunner implements ProcessRunner {
  calls: Array<{ command: string; args: string[]; input?: Uint8Array; options?: RunOptions }> = [];
  watches: Array<{ command: string; args: string[] }> = [];
  outputs = new Map<string, Uint8Array>();
  errors = new Map<string, string>();
  exitCodes = new Map<string, number>();
  onWatchChange: (() => void | Promise<void>) | undefined;
  onWatchExit: ((result: { exitCode: number; stdout: Uint8Array; stderr: string }) => void) | undefined;

  async run(command: string, args: string[], input?: Uint8Array, options?: RunOptions) {
    this.calls.push({ command, args, ...(input && { input }), ...(options && { options }) });
    const key = [command, ...args].join(" ");
    return {
      exitCode: this.exitCodes.get(key) ?? 0,
      stdout: this.outputs.get(key) ?? new Uint8Array(),
      stderr: this.errors.get(key) ?? "",
    };
  }

  watch(
    command: string,
    args: string[],
    onChange: () => void | Promise<void>,
    onExit?: (result: { exitCode: number; stdout: Uint8Array; stderr: string }) => void,
  ) {
    this.watches.push({ command, args });
    this.onWatchChange = onChange;
    this.onWatchExit = onExit;
    return () => {
      this.onWatchChange = undefined;
      this.onWatchExit = undefined;
    };
  }
}

describe("Wayland clipboard adapter", () => {
  test("writes text payloads with wl-copy", async () => {
    const runner = new FakeRunner();
    const clipboard = createWaylandClipboardAdapter(runner);
    const data = new TextEncoder().encode("paste me");

    await clipboard.write({ type: "text", mime: "text/plain", data });

    expect(runner.calls).toEqual([
      {
        command: "wl-copy",
        args: ["--type", "text/plain"],
        input: data,
        options: { detachOutput: true },
      },
    ]);
  });

  test("re-encodes non-PNG images to PNG before writing", async () => {
    const runner = new FakeRunner();
    const jpeg = new Uint8Array([0xff, 0xd8, 0xff]);
    const png = new Uint8Array([137, 80, 78, 71]);
    runner.outputs.set("magick - png:-", png);
    const clipboard = createWaylandClipboardAdapter(runner);

    await clipboard.write({ type: "image", mime: "image/jpeg", data: jpeg });

    expect(runner.calls).toEqual([
      { command: "magick", args: ["-", "png:-"], input: jpeg },
      {
        command: "wl-copy",
        args: ["--type", "image/png"],
        input: png,
        options: { detachOutput: true },
      },
    ]);
  });

  test("writes PNG images directly without re-encoding", async () => {
    const runner = new FakeRunner();
    const png = new Uint8Array([137, 80, 78, 71]);
    const clipboard = createWaylandClipboardAdapter(runner);

    await clipboard.write({ type: "image", mime: "image/png", data: png });

    expect(runner.calls).toEqual([
      {
        command: "wl-copy",
        args: ["--type", "image/png"],
        input: png,
        options: { detachOutput: true },
      },
    ]);
  });

  test("falls back to the original bytes when re-encoding fails", async () => {
    const runner = new FakeRunner();
    const jpeg = new Uint8Array([0xff, 0xd8, 0xff]);
    runner.exitCodes.set("magick - png:-", 1);
    const clipboard = createWaylandClipboardAdapter(runner);

    await clipboard.write({ type: "image", mime: "image/jpeg", data: jpeg });

    expect(runner.calls.at(-1)).toEqual({
      command: "wl-copy",
      args: ["--type", "image/jpeg"],
      input: jpeg,
      options: { detachOutput: true },
    });
  });

  test("reads the first supported clipboard payload type", async () => {
    const runner = new FakeRunner();
    runner.outputs.set(
      "wl-paste --list-types",
      new TextEncoder().encode("application/octet-stream\nimage/png\ntext/plain\n"),
    );
    runner.outputs.set("wl-paste --type image/png -n", new Uint8Array([137, 80, 78, 71]));
    const clipboard = createWaylandClipboardAdapter(runner);

    await expect(clipboard.read()).resolves.toEqual({
      type: "image",
      mime: "image/png",
      data: new Uint8Array([137, 80, 78, 71]),
    });
    // The read must pass -n so wl-paste emits exact bytes and never appends a
    // trailing newline to text payloads.
    expect(runner.calls.at(-1)?.args).toEqual(["--type", "image/png", "-n"]);
  });

  test("treats an empty clipboard as no payload", async () => {
    const runner = new FakeRunner();
    runner.exitCodes.set("wl-paste --list-types", 1);
    runner.errors.set("wl-paste --list-types", "Nothing is copied\n");
    const clipboard = createWaylandClipboardAdapter(runner);

    await expect(clipboard.read()).resolves.toBeUndefined();
    expect(runner.calls).toHaveLength(1);
  });

  test("watches clipboard changes with wl-paste, swallowing the startup fire", async () => {
    const runner = new FakeRunner();
    const clipboard = createWaylandClipboardAdapter(runner);
    let changes = 0;
    let ready = false;

    const stop = clipboard.watch(() => {
      changes += 1;
    }, () => {
      ready = true;
    });
    // wl-paste --watch emits once for the pre-existing selection on startup;
    // that fire must not count as a change.
    await runner.onWatchChange?.();
    expect(changes).toBe(0);
    expect(ready).toBeTrue();
    // Every subsequent fire is a real clipboard change.
    await runner.onWatchChange?.();
    await runner.onWatchChange?.();
    stop();

    expect(runner.watches).toEqual([
      {
        command: "wl-paste",
        args: ["--watch", "sh", "-c", "printf changed"],
      },
    ]);
    expect(changes).toBe(2);
    expect(runner.onWatchChange).toBeUndefined();
  });

  test("surfaces an incompatible compositor when wl-paste watch exits", () => {
    const runner = new FakeRunner();
    const clipboard = createWaylandClipboardAdapter(runner);
    let failure: Error | undefined;

    clipboard.watch(
      () => undefined,
      undefined,
      (error) => {
        failure = error;
      },
    );
    runner.onWatchExit?.({
      exitCode: 1,
      stdout: new Uint8Array(),
      stderr: "Watch mode requires a compositor that supports the wlroots data-control protocol\n",
    });

    expect(failure?.message).toBe(
      "wl-paste --watch failed: Watch mode requires a compositor that supports the wlroots data-control protocol",
    );
  });
});

describe("BunProcessRunner", () => {
  // wl-copy forks a daemon that inherits the pipes and holds them until it
  // loses the selection; the shell background job stands in for that daemon.
  test("detachOutput resolves on the direct child's exit despite a grandchild holding the pipes", async () => {
    const runner = new BunProcessRunner();
    const start = performance.now();

    const result = await runner.run("sh", ["-c", "sleep 5 & exit 0"], undefined, {
      detachOutput: true,
    });

    expect(result.exitCode).toBe(0);
    expect(performance.now() - start).toBeLessThan(2000);
  });

  test("detachOutput still surfaces stderr from a failing command", async () => {
    const runner = new BunProcessRunner();

    const result = await runner.run("sh", ["-c", "echo boom >&2; exit 3"], undefined, {
      detachOutput: true,
    });

    expect(result.exitCode).toBe(3);
    expect(result.stderr.trim()).toBe("boom");
  });

  test("watch reports an unexpected child exit with stderr", async () => {
    const runner = new BunProcessRunner();

    const result = await new Promise<{ exitCode: number; stdout: Uint8Array; stderr: string }>((resolve) => {
      runner.watch("sh", ["-c", "echo unsupported >&2; exit 7"], () => undefined, resolve);
    });

    expect(result.exitCode).toBe(7);
    expect(result.stderr.trim()).toBe("unsupported");
  });
});
