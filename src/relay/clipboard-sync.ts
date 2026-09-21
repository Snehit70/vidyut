import type { ClipboardAdapter } from "./clipboard";
import { noopLogger, type Logger } from "./logger";
import type { PayloadPool } from "./payload-pool";
import { decryptPayload, encryptPayload } from "../shared/crypto";
import { encodedPayloadBytes, type PayloadFrame } from "../shared/wire";

export interface WatchableClipboardAdapter extends ClipboardAdapter {
  watch(
    onChange: () => Promise<void> | void,
    onReady?: () => void,
    onFailure?: (error: Error) => void,
  ): () => void;
}

export interface ClipboardHealth {
  enabled: boolean;
  status: "starting" | "healthy" | "degraded" | "disabled";
  watcher?: string;
  error?: string;
}

interface ClipboardSyncOptions {
  clipboard: WatchableClipboardAdapter;
  pool: PayloadPool;
  pairingSecret: string;
  origin: string;
  now(): number;
  logger?: Logger;
  onHealthChange?: (health: ClipboardHealth) => void;
}

export function startClipboardSync(options: ClipboardSyncOptions): () => void {
  const logger = options.logger ?? noopLogger;
  let suppressNextChange = false;

  const stopWatching = options.clipboard.watch(
    async () => {
      if (suppressNextChange) {
        suppressNextChange = false;
        return;
      }

      try {
        const payload = await options.clipboard.read();
        if (!payload) return;

        const frame = await encryptPayload(
          {
            type: payload.type,
            mime: payload.mime,
            origin: options.origin,
            ts: options.now(),
          },
          payload.data,
          options.pairingSecret,
        );
        logger.info("clipboard_published", {
          type: frame.type,
          mime: frame.mime,
          bytes: encodedPayloadBytes(frame),
          nonce: frame.nonce,
          frameTs: frame.ts,
        });
        const accepted = await options.pool.publish(frame, options.origin);
        if (!accepted) {
          logger.warn("payload_stale_dropped", {
            origin: "local",
            type: frame.type,
            mime: frame.mime,
            bytes: encodedPayloadBytes(frame),
            nonce: frame.nonce,
            frameTs: frame.ts,
            currentTs: options.pool.current?.ts,
          });
        }
      } catch (error) {
        logger.error("clipboard_read_failed", { error: describeError(error) });
      }
    },
    () => {
      const health: ClipboardHealth = { enabled: true, status: "healthy", watcher: "wl-paste --watch" };
      options.onHealthChange?.(health);
      logger.info("clipboard_watch_ready", { watcher: health.watcher });
    },
    (error) => {
      const message = describeError(error);
      const health: ClipboardHealth = {
        enabled: true,
        status: "degraded",
        watcher: "wl-paste --watch",
        error: message,
      };
      options.onHealthChange?.(health);
      logger.error("clipboard_watch_failed", {
        watcher: health.watcher,
        error: message,
        guidance: clipboardWatchGuidance(message),
      });
    },
  );

  const unsubscribe = options.pool.subscribe((frame, source) => {
    if (source === options.origin || frame.origin === options.origin) return;
    // Do not await the Wayland write on the pool publish path. A stuck
    // wl-copy/magick would otherwise hold the phone's ack and freeze the
    // relay socket until the service is restarted.
    void writeIncoming(frame);
  });

  async function writeIncoming(frame: PayloadFrame) {
    // The pool fans out through Promise.allSettled, which swallows listener
    // rejections — every failure must be caught and logged here.
    let data: Uint8Array;
    try {
      data = await decryptPayload(frame, options.pairingSecret);
    } catch (error) {
      logger.error("clipboard_write_failed", {
        nonce: frame.nonce,
        frameTs: frame.ts,
        stage: "decrypt",
        error: describeError(error),
      });
      return;
    }

    suppressNextChange = true;
    try {
      await options.clipboard.write({
        type: frame.type,
        mime: frame.mime,
        data,
      });
    } catch (error) {
      suppressNextChange = false;
      logger.error("clipboard_write_failed", {
        nonce: frame.nonce,
        frameTs: frame.ts,
        stage: "write",
        error: describeError(error),
      });
      return;
    }
    logger.info("clipboard_write", {
      type: frame.type,
      mime: frame.mime,
      bytes: encodedPayloadBytes(frame),
      nonce: frame.nonce,
      frameTs: frame.ts,
      e2eMs: options.now() - frame.ts,
    });
  }

  return () => {
    stopWatching();
    unsubscribe();
  };
}

function describeError(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

function clipboardWatchGuidance(error: string): string {
  if (error.includes("wlroots data-control protocol")) {
    return "Install wl-clipboard 2.3 or newer for ext-data-control-v1 compositor support.";
  }
  return "Check WAYLAND_DISPLAY and wl-paste availability; see docs/TROUBLESHOOTING.md.";
}
