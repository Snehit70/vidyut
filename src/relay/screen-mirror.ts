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
  closeSocket?: CloseSocket;
  startedAt?: number;
  records: number;
}

/**
 * Finds mpv, or ffplay when mpv is missing. Both read raw H.264 from stdin
 * with the lowest delay they offer.
 */
export function findScreenPlayer(
  which: (command: string) => string | null = Bun.which,
  title = "Vidyut · phone screen",
): ScreenPlayer | undefined {
  const mpv = which("mpv");
  if (mpv) {
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
        `--title=${title}`,
        `--wayland-app-id=${screenAppId}`,
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

export const launchPlayer: LaunchPlayer = (player) => {
  const child = Bun.spawn(player.command, {
    stdin: "pipe",
    stdout: "ignore",
    stderr: "ignore",
    env: { ...process.env, ...player.env },
  });
  return {
    write(bytes) {
      child.stdin.write(bytes);
      void child.stdin.flush();
    },
    exited: child.exited,
    kill() {
      try {
        child.stdin.end();
      } catch {
        // already closed
      }
      child.kill();
    },
  };
};

export interface ScreenMirrorOptions {
  findPlayer?: () => ScreenPlayer | undefined;
  launch?: LaunchPlayer;
  logger?: Logger;
  ticketTtlMs?: number;
  now?: () => number;
}

export class ScreenMirror {
  readonly #findPlayer: () => ScreenPlayer | undefined;
  readonly #launch: LaunchPlayer;
  readonly #logger: Logger;
  readonly #ticketTtlMs: number;
  readonly #now: () => number;
  #session: Session | undefined;

  constructor(options: ScreenMirrorOptions = {}) {
    this.#findPlayer = options.findPlayer ?? (() => findScreenPlayer());
    this.#launch = options.launch ?? launchPlayer;
    this.#logger = options.logger ?? noopLogger;
    this.#ticketTtlMs = options.ticketTtlMs ?? defaultTicketTtlMs;
    this.#now = options.now ?? Date.now;
  }

  /** Answers a `screen_start`. Any mirror that runs is replaced. */
  start(deviceId: string, width: number, height: number): ScreenStartAnswer {
    this.#end("replaced");
    if (!this.#findPlayer()) {
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
    const player = this.#findPlayer();
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

  #end(reason: string): void {
    const session = this.#session;
    if (!session) return;
    this.#session = undefined;
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
