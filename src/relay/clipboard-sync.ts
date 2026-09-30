import type { ClipboardAdapter } from "./clipboard";
import { pairingSecretValue, type PairingSecretRef } from "./config";
import { noopLogger, type Logger } from "./logger";
import type { PayloadPool } from "./payload-pool";
import { decryptPayload, encryptPayload } from "../shared/crypto";
import { encodedPayloadBytes, type PayloadFrame } from "../shared/wire";
import { isOpenableLink } from "./open-link";

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
  pairingSecret: string | PairingSecretRef;
  origin: string;
  now(): number;
  logger?: Logger;
  onHealthChange?: (health: ClipboardHealth) => void;
  /**
   * Opens a link payload in the desktop's browser, after the URL has been
   * written to the clipboard. Injected so tests can observe the launch without
   * spawning a process, and so the pool path carries no hard process
   * dependency. Omitted, a link still reaches the clipboard and nothing opens.
   */
  openLink?: (url: string) => Promise<void>;
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
          pairingSecretValue(options.pairingSecret),
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
      data = await decryptPayload(frame, pairingSecretValue(options.pairingSecret));
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

    if (frame.type === "link") {
      // Fire and forget, for the same reason the write above is not awaited by
      // the pool: a browser that takes seconds to surface must not hold the
      // phone's ack. The clipboard already has the URL, so a failed launch
      // costs a tab, not the payload.
      void openLinkFrom(frame, data);
    }
  }

  async function openLinkFrom(frame: PayloadFrame, data: Uint8Array) {
    const openLink = options.openLink;
    if (!openLink) return;
    const url = new TextDecoder().decode(data).trim();
    // The phone chose the type, but the relay is the side actually handing this
    // string to a process, so it does not take the claim on trust.
    if (!isOpenableLink(url)) {
      logger.error("link_open_skipped", {
        nonce: frame.nonce,
        frameTs: frame.ts,
        reason: "not an http or https URL",
      });
      return;
    }
    try {
      await openLink(url);
      logger.info("link_opened", { nonce: frame.nonce, frameTs: frame.ts, url });
    } catch (error) {
      logger.error("link_open_failed", {
        nonce: frame.nonce,
        frameTs: frame.ts,
        error: describeError(error),
      });
    }
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
