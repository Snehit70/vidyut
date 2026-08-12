import { spawn } from "bun";
import type { PayloadType } from "../shared/wire";

export interface ClipboardPayload {
  type: PayloadType;
  mime: string;
  data: Uint8Array;
}

export interface ProcessResult {
  exitCode: number;
  stdout: Uint8Array;
  stderr: string;
}

export interface RunOptions {
  /**
   * The command forks a daemon that inherits its pipes (wl-copy serving the
   * selection): resolve on the direct child's exit instead of waiting for
   * stdout/stderr EOF, which the daemon holds open until the next clipboard
   * change.
   */
  detachOutput?: boolean;
}

export interface ProcessRunner {
  run(command: string, args: string[], input?: Uint8Array, options?: RunOptions): Promise<ProcessResult>;
  watch(
    command: string,
    args: string[],
    onChange: () => void | Promise<void>,
    onExit?: (result: ProcessResult) => void,
  ): () => void;
}

export interface ClipboardAdapter {
  read(): Promise<ClipboardPayload | undefined>;
  write(payload: ClipboardPayload): Promise<void>;
  watch(
    onChange: () => void | Promise<void>,
    onReady?: () => void,
    onFailure?: (error: Error) => void,
  ): () => void;
}

const supportedMimeTypes: Array<{ mime: string; type: PayloadType }> = [
  { mime: "image/png", type: "image" },
  { mime: "image/jpeg", type: "image" },
  { mime: "image/webp", type: "image" },
  { mime: "text/plain", type: "text" },
  { mime: "text/plain;charset=utf-8", type: "text" },
];

export function createWaylandClipboardAdapter(runner: ProcessRunner = new BunProcessRunner()): ClipboardAdapter {
  return {
    async read() {
      const typeList = await runner.run("wl-paste", ["--list-types"]);
      // wl-paste reports an empty selection as a non-zero exit. An empty
      // clipboard is normal while the relay is running and must not take the
      // relay down with an unhandled read rejection.
      if (typeList.exitCode !== 0) {
        if (isEmptyClipboardError(typeList.stderr)) return undefined;
        ensureProcessOk(typeList, "wl-paste --list-types");
      }
      const availableTypes = new Set(new TextDecoder().decode(typeList.stdout).split(/\r?\n/).filter(Boolean));
      const selected = supportedMimeTypes.find((candidate) => availableTypes.has(candidate.mime));
      if (!selected) return undefined;

      // -n: emit the exact clipboard bytes. Without it wl-paste appends a
      // trailing newline to text, which then rides to the phone (a copied
      // "token" arrives as "token\n"). For non-text types -n is a no-op —
      // wl-paste auto-enables it for binary content.
      const read = await runner.run("wl-paste", ["--type", selected.mime, "-n"]);
      ensureProcessOk(read, `wl-paste --type ${selected.mime}`);
      return {
        type: selected.type,
        mime: selected.mime,
        data: read.stdout,
      };
    },
    async write(payload) {
      const { mime, data } = await normalizeImageToPng(runner, payload);
      // Without detachOutput this blocks until the NEXT clipboard change —
      // and everything downstream of the write (the ack to the sender, the
      // e2eMs measurement) stalls with it.
      const result = await runner.run("wl-copy", ["--type", mime], data, {
        detachOutput: true,
      });
      ensureProcessOk(result, `wl-copy --type ${mime}`);
    },
    watch(onChange, onReady, onFailure) {
      // wl-paste --watch fires once immediately for the selection that already
      // exists when the relay starts. That startup fire is not a user action:
      // publishing it re-stamps stale clipboard content with a fresh now()
      // timestamp, which then supersedes any frame a device held while the
      // relay was down and makes the pool drop it as stale (offline-hold,
      // E2E §10). Swallow the first fire; every later one is a real change.
      let primed = false;
      return runner.watch(
        "wl-paste",
        ["--watch", "sh", "-c", "printf changed"],
        () => {
          if (!primed) {
            primed = true;
            onReady?.();
            return;
          }
          return onChange();
        },
        (result) => {
          const detail = result.stderr.trim() || `exit ${result.exitCode}`;
          onFailure?.(new Error(`wl-paste --watch failed: ${detail}`));
        },
      );
    },
  };
}

/**
 * Most Linux apps only paste `image/png`; phone screenshots arrive as
 * `image/jpeg` (MIUI) or a non-concrete `image/*` (share sheet), which apps
 * silently refuse. Re-encode through ImageMagick — it sniffs the real format
 * from the bytes — and offer PNG instead. Any failure (magick not installed,
 * corrupt data) falls back to writing the original bytes untouched.
 */
async function normalizeImageToPng(
  runner: ProcessRunner,
  payload: ClipboardPayload,
): Promise<{ mime: string; data: Uint8Array }> {
  if (payload.type !== "image" || payload.mime === "image/png") {
    return { mime: payload.mime, data: payload.data };
  }
  try {
    const converted = await runner.run("magick", ["-", "png:-"], payload.data);
    if (converted.exitCode === 0 && converted.stdout.length > 0) {
      return { mime: "image/png", data: converted.stdout };
    }
  } catch {
    // magick missing or unspawnable — degrade to the raw write below.
  }
  return { mime: payload.mime, data: payload.data };
}

export class BunProcessRunner implements ProcessRunner {
  async run(
    command: string,
    args: string[],
    input?: Uint8Array,
    options?: RunOptions,
  ): Promise<ProcessResult> {
    const child = spawn([command, ...args], {
      stdin: input ? "pipe" : "ignore",
      stdout: options?.detachOutput ? "ignore" : "pipe",
      stderr: "pipe",
    });

    if (input && child.stdin) {
      child.stdin.write(input);
      child.stdin.end();
    }

    if (options?.detachOutput) {
      const exitCode = await child.exited;
      if (exitCode === 0) {
        // Success means the daemon may hold stderr open — drop it unread.
        void child.stderr.cancel();
        return { exitCode, stdout: new Uint8Array(), stderr: "" };
      }
      // A failing wl-copy exits before forking, so its pipes are closed and
      // stderr is safe to drain for the error message.
      const stderr = await new Response(child.stderr).text();
      return { exitCode, stdout: new Uint8Array(), stderr };
    }

    const [stdout, stderr, exitCode] = await Promise.all([
      new Response(child.stdout).arrayBuffer(),
      new Response(child.stderr).text(),
      child.exited,
    ]);

    return {
      exitCode,
      stdout: new Uint8Array(stdout),
      stderr,
    };
  }

  watch(
    command: string,
    args: string[],
    onChange: () => void | Promise<void>,
    onExit?: (result: ProcessResult) => void,
  ): () => void {
    const child = spawn([command, ...args], {
      stdin: "ignore",
      stdout: "pipe",
      stderr: "pipe",
    });
    const reader = child.stdout.getReader();
    const stderr = new Response(child.stderr).text();
    let stopped = false;

    void (async () => {
      while (!stopped) {
        const chunk = await reader.read();
        if (chunk.done) return;
        await onChange();
      }
    })();
    void (async () => {
      const [exitCode, errorOutput] = await Promise.all([child.exited, stderr]);
      if (stopped) return;
      onExit?.({
        exitCode,
        stdout: new Uint8Array(),
        stderr: errorOutput,
      });
    })();

    return () => {
      stopped = true;
      child.kill();
    };
  }
}

function ensureProcessOk(result: ProcessResult, description: string): void {
  if (result.exitCode !== 0) {
    throw new Error(`${description} failed: ${result.stderr || `exit ${result.exitCode}`}`);
  }
}

function isEmptyClipboardError(stderr: string): boolean {
  return /nothing is copied|clipboard is empty/i.test(stderr);
}
