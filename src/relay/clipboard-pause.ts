import type { ClipboardHealth } from "./clipboard-sync";
import { noopLogger, type Logger } from "./logger";

/** The longest timed pause the control plane takes; longer is "until resumed". */
export const maxPauseMinutes = 24 * 60;

export interface ClipboardPauseState {
  paused: boolean;
  /** Relay-clock epoch ms when the pause lifts by itself. Absent while paused until resumed. */
  until?: number;
}

interface ClipboardPauseOptions {
  now(): number;
  logger?: Logger;
  /** Fires on every pause, resume and expiry, so health can be pushed. */
  onChange?: (state: ClipboardPauseState) => void;
}

/**
 * The laptop's "stop syncing my clipboard for a while" switch. While paused,
 * a laptop copy is not published and a phone payload is not written. File
 * transfers are a separate path and keep running.
 */
export class ClipboardPause {
  readonly #options: ClipboardPauseOptions;
  readonly #logger: Logger;
  #paused = false;
  #until: number | undefined;
  #timer: ReturnType<typeof setTimeout> | undefined;

  constructor(options: ClipboardPauseOptions) {
    this.#options = options;
    this.#logger = options.logger ?? noopLogger;
  }

  get paused(): boolean {
    // The timer is the normal way out; this covers one that fired late.
    if (this.#paused && this.#until !== undefined && this.#options.now() >= this.#until) {
      this.#lift("expired");
    }
    return this.#paused;
  }

  state(): ClipboardPauseState {
    if (!this.paused) return { paused: false };
    return this.#until === undefined ? { paused: true } : { paused: true, until: this.#until };
  }

  /** Omit durationMs to pause until resumed. Pausing again replaces the old deadline. */
  pause(durationMs?: number): void {
    clearTimeout(this.#timer);
    this.#timer = undefined;
    this.#paused = true;
    this.#until = durationMs === undefined ? undefined : this.#options.now() + durationMs;
    if (durationMs !== undefined) {
      this.#timer = setTimeout(() => this.#lift("expired"), durationMs);
      this.#timer.unref?.();
    }
    this.#logger.info("clipboard_paused", {
      ...(this.#until !== undefined && { until: this.#until }),
    });
    this.#options.onChange?.(this.state());
  }

  resume(): void {
    if (this.#paused) this.#lift("resumed");
  }

  stop(): void {
    clearTimeout(this.#timer);
    this.#timer = undefined;
  }

  #lift(reason: "resumed" | "expired"): void {
    clearTimeout(this.#timer);
    this.#timer = undefined;
    this.#paused = false;
    this.#until = undefined;
    this.#logger.info("clipboard_resumed", { reason });
    this.#options.onChange?.({ paused: false });
  }
}

/** Clipboard health as the phone and the shell see it, with the pause folded in. */
export function withPause(health: ClipboardHealth, pause: ClipboardPause): ClipboardHealth {
  const state = pause.state();
  if (!state.paused) return health;
  return {
    ...health,
    paused: true,
    ...(state.until !== undefined && { pausedUntil: state.until }),
  };
}
