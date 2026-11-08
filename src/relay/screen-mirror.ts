import { randomBytes } from "node:crypto";
import { noopLogger, type Logger } from "./logger";
import { ScreenRecordOpener, screenKeyBytes } from "../shared/screen-seal";

/**
 * The phone's screen in a laptop window (ADR 0030).
 *
 * A sealed `screen_start` gets a one-time ticket: a stream id and a fresh
 * key. The phone opens a WebSocket on `/screen/v1/<streamId>` within
 * [ticketTtlMs] and sends sealed H.264 records on it. The relay opens each
 * record and pipes the stream into mpv, or ffplay, which shows it. Closing
 * the window ends the stream, and the phone stops capturing when its socket
 * closes. There is one mirror at a time; a new start replaces the old one.
 */

/** The Wayland app id of the mirror window, for compositor window rules. */
export const screenAppId = "vidyut-screen";

const defaultTicketTtlMs = 15_000;
const streamIdPattern = /^[A-Za-z0-9_-]{24}$/;

export interface ScreenPlayer {
  name: "mpv" | "ffplay";
  command: string[];
  env: Record<string, string>;
}

export interface PlayerProcess {
  write(bytes: Uint8Array): void;
  /** Resolves when the player exits, for example when its window is closed. */
  exited: Promise<unknown>;
  kill(): void;
}

export type LaunchPlayer = (player: ScreenPlayer) => PlayerProcess;

export type ScreenStartAnswer =
  | { ok: true; streamId: string; key: string }
  | { ok: false; code: string; message: string };

/** What the desktop shell shows about the phone screen window. */
export interface ScreenMirrorStatus {
  /** `starting` while the phone is connecting; `idle` when nothing runs. */
  phase: "idle" | "starting" | "streaming";
  width?: number;
  height?: number;
  /** Why the previous mirror ended, as a reason code from [ScreenMirror]. */
  endedReason?: string;
}

/** The part of [ScreenMirror] the control plane needs. */
export interface ScreenMirrorControl {
  status(): ScreenMirrorStatus;
  stopByLaptop(): void;
}

/** The window title carries the streamed size, so a second window is easy to tell apart. */
export function windowTitle(width: number, height: number): string {
  return `Vidyut · phone screen ${width}×${height}`;
}

/** One mirror WebSocket. The relay hands it each binary message. */
export interface ScreenStream {
  /** False when the record did not open; the socket should close. */
  receive(record: Uint8Array): boolean;
  /** The phone's socket closed. */
  closed(): void;
}

type CloseSocket = (code: number, reason: string) => void;

interface Session {
  streamId: string;
  key: Uint8Array;
  deviceId: string;
  width: number;
  height: number;
  phase: "waiting" | "claimed" | "streaming" | "ended";
  timer?: ReturnType<typeof setTimeout>;
  player?: PlayerProcess;
  closeSocket?: CloseSocket | undefined;
  startedAt?: number;
  records: number;
}

/**
 * Finds mpv, or ffplay when mpv is missing. Both read raw H.264 from stdin
 * with the lowest delay they offer.
 */
export function findScreenPlayer(
  which: (command: string) => string | null = Bun.which,
  listMpvOptions: (mpv: string) => string = mpvOptions,
  title = "Vidyut · phone screen",
): ScreenPlayer | undefined {
  const mpv = which("mpv");
  if (mpv) {
    // mpv exits on an option it does not know, and --wayland-app-id is new
    // in 0.36; older ones get mpv's own app id.
    const appId = listMpvOptions(mpv).includes("--wayland-app-id")
      ? [`--wayland-app-id=${screenAppId}`]
      : [];
    return {
      name: "mpv",
      command: [
        mpv,
        // A user mpv.conf can keep the window open at the end of the stream
        // or load scripts, so it is not read.
        "--no-config",
        "--really-quiet",
        "--profile=low-latency",
        "--untimed",
        "--no-cache",
        "--demuxer-lavf-format=h264",
        "--demuxer-lavf-probesize=32",
        "--demuxer-lavf-analyzeduration=0.1",
        "--hwdec=auto-safe",
        "--force-window=immediate",
        "--keep-open=no",
        "--osc=no",
        "--audio=no",
        "--autofit-larger=90%x85%",
        // Tells a new viewer which keys help, once, when the window opens.
        "--osd-duration=4000",
        "--osd-playing-msg=f: fullscreen · T: keep on top",
        `--title=${title}`,
        ...appId,
        "-",
      ],
      env: {},
    };
  }
  const ffplay = which("ffplay");
  if (ffplay) {
    return {
      name: "ffplay",
      command: [
        ffplay,
        "-hide_banner",
        "-loglevel",
        "error",
        "-window_title",
        title,
        "-flags",
        "low_delay",
        "-framedrop",
        "-probesize",
        "32",
        "-analyzeduration",
        "0",
        "-autoexit",
        "-f",
        "h264",
        "-framerate",
        "30",
        "-i",
        "pipe:0",
      ],
      // SDL takes the Wayland app id from these.
      env: { SDL_VIDEO_WAYLAND_WMCLASS: screenAppId, SDL_APP_ID: screenAppId },
    };
  }
  return undefined;
}

const mpvOptionLists = new Map<string, string>();

/** `mpv --list-options`, read once per binary. */
function mpvOptions(mpv: string): string {
  let list = mpvOptionLists.get(mpv);
  if (list === undefined) {
    try {
      list = Bun.spawnSync([mpv, "--no-config", "--list-options"], { stderr: "ignore" }).stdout.toString();
    } catch {
      list = "";
    }
    mpvOptionLists.set(mpv, list);
  }
  return list;
}

/**
 * How far the player may fall behind before it is stopped: a few seconds of
 * the fastest stream. Past this the window shows the past, and the relay
 * would only buffer more.
 */
const maxPlayerBacklogBytes = 8 * 1024 * 1024;

export const launchPlayer: LaunchPlayer = (player) => {
  const child = Bun.spawn(player.command, {
    stdin: "pipe",
    stdout: "ignore",
    stderr: "ignore",
    env: { ...process.env, ...player.env },
  });
  let exited = false;
  let backlog = 0;
  void child.exited.then(() => {
    exited = true;
  });
  // Once the window is closed the pipe is gone; a write or flush that fails
  // then must not become an unhandled rejection, which would end the relay.
  const settle = (result: number | Promise<number> | undefined, bytes: number) => {
    if (result instanceof Promise) {
      result.then(
        (flushed) => {
          backlog = Math.max(0, backlog - (flushed || bytes));
        },
        () => undefined,
      );
    } else {
      backlog = Math.max(0, backlog - bytes);
    }
  };
  const stop = () => {
    try {
      settle(child.stdin.end(), 0);
    } catch {
      // already closed
    }
    child.kill();
  };
  return {
    write(bytes) {
      if (exited) return;
      backlog += bytes.byteLength;
      if (backlog > maxPlayerBacklogBytes) {
        // Its exit ends the session.
        stop();
        return;
      }
      child.stdin.write(bytes);
      settle(child.stdin.flush(), bytes.byteLength);
    },
    exited: child.exited,
    kill: stop,
  };
};

export interface ScreenMirrorOptions {
  findPlayer?: (title: string) => ScreenPlayer | undefined;
  launch?: LaunchPlayer;
  logger?: Logger;
  ticketTtlMs?: number;
  now?: () => number;
}

export class ScreenMirror implements ScreenMirrorControl {
  readonly #findPlayer: (title: string) => ScreenPlayer | undefined;
  readonly #launch: LaunchPlayer;
  readonly #logger: Logger;
  readonly #ticketTtlMs: number;
  readonly #now: () => number;
  #session: Session | undefined;
  #lastEnd: string | undefined;

  constructor(options: ScreenMirrorOptions = {}) {
    this.#findPlayer = options.findPlayer ?? ((title) => findScreenPlayer(undefined, undefined, title));
    this.#launch = options.launch ?? launchPlayer;
    this.#logger = options.logger ?? noopLogger;
    this.#ticketTtlMs = options.ticketTtlMs ?? defaultTicketTtlMs;
    this.#now = options.now ?? Date.now;
  }

  /** Answers a `screen_start`. Any mirror that runs is replaced. */
  start(deviceId: string, width: number, height: number): ScreenStartAnswer {
    this.#end("replaced");
    if (!this.#findPlayer(windowTitle(width, height))) {
      return {
        ok: false,
        code: "no_player",
        message: "Install mpv on the laptop to show the phone screen.",
      };
    }
    const session: Session = {
      streamId: randomBytes(18).toString("base64url"),
      key: new Uint8Array(randomBytes(screenKeyBytes)),
      deviceId,
      width,
      height,
      phase: "waiting",
      records: 0,
    };
    session.timer = setTimeout(() => {
      if (this.#session === session && session.phase === "waiting") {
        this.#logger.warn("screen_mirror_ticket_expired", { deviceId });
        this.#end("ticket_expired");
      }
    }, this.#ticketTtlMs);
    this.#session = session;
    this.#logger.info("screen_mirror_ready", { deviceId, width, height });
    return {
      ok: true,
      streamId: session.streamId,
      key: Buffer.from(session.key).toString("base64"),
    };
  }

  /**
   * Takes the ticket for an incoming WebSocket upgrade. Each ticket admits
   * one socket, so a second try with the same id is refused.
   */
  claim(streamId: string): boolean {
    const session = this.#session;
    if (!streamIdPattern.test(streamId) || !session) return false;
    if (session.phase !== "waiting" || session.streamId !== streamId) return false;
    clearTimeout(session.timer);
    session.phase = "claimed";
    return true;
  }

  /** Starts the window for a claimed stream once its socket is open. */
  attach(streamId: string, closeSocket: CloseSocket): ScreenStream | undefined {
    const session = this.#session;
    if (!session || session.streamId !== streamId || session.phase !== "claimed") {
      return undefined;
    }
    const player = this.#findPlayer(windowTitle(session.width, session.height));
    if (!player) {
      this.#end("no_player");
      return undefined;
    }
    let child: PlayerProcess;
    try {
      child = this.#launch(player);
    } catch (error) {
      this.#logger.error("screen_mirror_player_failed", {
        player: player.name,
        error: error instanceof Error ? error.message : String(error),
      });
      this.#end("player_failed");
      return undefined;
    }
    session.phase = "streaming";
    session.player = child;
    session.closeSocket = closeSocket;
    session.startedAt = this.#now();
    this.#logger.info("screen_mirror_started", {
      deviceId: session.deviceId,
      player: player.name,
      width: session.width,
      height: session.height,
    });
    void child.exited.then(() => {
      if (this.#session === session) this.#end("window_closed");
    });

    const opener = new ScreenRecordOpener(session.key);
    return {
      receive: (record) => {
        if (this.#session !== session || session.phase !== "streaming") return false;
        let plaintext: Buffer;
        try {
          plaintext = opener.open(record);
        } catch (error) {
          this.#logger.warn("screen_mirror_record_rejected", {
            deviceId: session.deviceId,
            records: session.records,
            error: error instanceof Error ? error.message : String(error),
          });
          this.#end("bad_record");
          return false;
        }
        session.records += 1;
        try {
          child.write(plaintext);
        } catch {
          // The player went away; its exit ends the session.
        }
        return true;
      },
      closed: () => {
        session.closeSocket = undefined;
        if (this.#session === session) this.#end("phone_stopped");
      },
    };
  }

  /** Ends any mirror, for relay shutdown. */
  stop(): void {
    this.#end("relay_stopped");
  }

  /** Ends the mirror from the desktop shell's Stop button. */
  stopByLaptop(): void {
    this.#end("stopped_on_laptop");
  }

  status(): ScreenMirrorStatus {
    const session = this.#session;
    if (!session) {
      return this.#lastEnd === undefined ? { phase: "idle" } : { phase: "idle", endedReason: this.#lastEnd };
    }
    return {
      phase: session.phase === "streaming" ? "streaming" : "starting",
      width: session.width,
      height: session.height,
    };
  }

  #end(reason: string): void {
    const session = this.#session;
    if (!session) return;
    this.#session = undefined;
    this.#lastEnd = reason;
    const wasStreaming = session.phase === "streaming";
    session.phase = "ended";
    clearTimeout(session.timer);
    session.player?.kill();
    session.closeSocket?.(1000, reason);
    if (wasStreaming) {
      this.#logger.info("screen_mirror_ended", {
        deviceId: session.deviceId,
        reason,
        records: session.records,
        durationMs: session.startedAt === undefined ? 0 : this.#now() - session.startedAt,
      });
    }
  }
}
