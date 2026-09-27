import {
  createPairingSecret,
  pairingSecretValue,
  type PairingSecretRef,
} from "./config";
import { desktopShellHtml } from "./desktop-shell-page";
import { manropeFontBytes } from "./shell-assets";
import {
  createPairingQrSvg,
  pairingManualLine,
  type PairingCodeOptions,
} from "./pairing";
import {
  createSetupStatusReader,
  type LaptopSetupStatus,
  type SetupStatusReader,
} from "./setup-status";
import type { ClipboardHealth } from "./clipboard-sync";
import { encodedPayloadBytes, type PayloadFrame } from "../shared/wire";

export type DesktopSyncState = "ready" | "sync_needs_attention" | "relay_down";

export interface ControlPoolMeta {
  type: PayloadFrame["type"];
  mime: string;
  bytes: number;
  origin: string;
  ageSeconds: number;
}

export interface ControlState {
  relayName: string;
  host: string;
  port: number;
  pairingSecret: string;
  manual: string;
  syncState: DesktopSyncState;
  clipboard: ClipboardHealth | undefined;
  authenticatedDeviceCount: number;
  pool: ControlPoolMeta | null;
}

export interface ControlPlaneContext {
  pairingSecret: PairingSecretRef;
  pairingHost: string;
  port: number;
  relayName: string;
  clipboardHealth?: () => ClipboardHealth;
  authenticatedDeviceCount(): number;
  currentPayload(): PayloadFrame | undefined;
  persistPairingSecret?: (secret: string) => Promise<void>;
  kickDevices?: () => void;
  transferSnapshot?: () => unknown;
  enqueueLaptopFiles?: (paths: string[]) => Promise<unknown>;
  setupStatus?: SetupStatusReader;
}

export function isControlPath(pathname: string): boolean {
  return (
    pathname === "/" ||
    pathname === "/ui" ||
    pathname === "/ui/" ||
    pathname.startsWith("/ui/") ||
    pathname.startsWith("/control/v1/")
  );
}

export async function handleControlRequest(
  request: Request,
  context: ControlPlaneContext,
): Promise<Response> {
  const url = new URL(request.url);
  const path = url.pathname;
  if (
    request.method === "GET" &&
    (path === "/" || path === "/ui" || path === "/ui/")
  ) {
    return htmlShellResponse(controlState(context));
  }
  if (request.method === "GET" && path === "/control/v1/state") {
    return Response.json(controlState(context));
  }
  if (request.method === "GET" && path === "/ui/manrope.ttf") {
    return manropeFontResponse();
  }
  if (request.method === "GET" && path === "/control/v1/qr.svg") {
    return new Response(createPairingQrSvg(pairingOptions(context)), {
      headers: {
        "content-type": "image/svg+xml; charset=utf-8",
        "cache-control": "no-store",
      },
    });
  }
  if (request.method === "POST" && path === "/control/v1/rotate-secret") {
    return rotatePairingSecret(context);
  }
  if (request.method === "GET" && path === "/control/v1/transfers") {
    return Response.json(context.transferSnapshot?.() ?? { v: 1, batches: [] });
  }
  if (request.method === "POST" && path === "/control/v1/transfers/enqueue") {
    return enqueueTransfers(request, context);
  }
  if (request.method === "GET" && path === "/control/v1/setup") {
    // Probing shells out to several processes, so the default read is cached.
    // An explicit refresh=1 is how the user says "I just changed something".
    const force = url.searchParams.get("refresh") === "1";
    const status = await (context.setupStatus ?? fallbackSetupStatus(context.port))(
      force,
    );
    return Response.json(status);
  }
  return new Response("Not found", { status: 404 });
}

/**
 * Only used when a caller drives the control plane without supplying a reader.
 * createRelay always supplies one. Keyed by port because the firewall probe
 * needs the port the Relay is actually listening on.
 */
const fallbackReaders = new Map<number, SetupStatusReader>();

function fallbackSetupStatus(port: number): SetupStatusReader {
  let reader = fallbackReaders.get(port);
  if (!reader) {
    reader = createSetupStatusReader({ deps: { port } });
    fallbackReaders.set(port, reader);
  }
  return reader;
}

export function controlState(context: ControlPlaneContext): ControlState {
  const pairing = pairingOptions(context);
  const clipboard = context.clipboardHealth?.();
  const payload = context.currentPayload();
  const now = Date.now();
  return {
    relayName: context.relayName,
    host: context.pairingHost,
    port: context.port,
    pairingSecret: pairingSecretValue(context.pairingSecret),
    manual: pairingManualLine(pairing),
    syncState:
      clipboard?.status === "degraded" ? "sync_needs_attention" : "ready",
    clipboard,
    authenticatedDeviceCount: context.authenticatedDeviceCount(),
    pool: payload
      ? {
          type: payload.type,
          mime: payload.mime,
          bytes: encodedPayloadBytes(payload),
          origin: payload.origin,
          ageSeconds: Math.floor((now - payload.ts) / 1000),
        }
      : null,
  };
}

function pairingOptions(context: ControlPlaneContext): PairingCodeOptions {
  return {
    host: context.pairingHost,
    port: context.port,
    pairingSecret: pairingSecretValue(context.pairingSecret),
    relayName: context.relayName,
  };
}

async function rotatePairingSecret(
  context: ControlPlaneContext,
): Promise<Response> {
  const next = createPairingSecret();
  const previous = context.pairingSecret.value;
  context.pairingSecret.value = next;
  try {
    await context.persistPairingSecret?.(next);
  } catch (error) {
    context.pairingSecret.value = previous;
    return Response.json(
      {
        code: "rotate_failed",
        message: error instanceof Error ? error.message : String(error),
      },
      { status: 500 },
    );
  }
  context.kickDevices?.();
  return Response.json(controlState(context));
}

async function enqueueTransfers(
  request: Request,
  context: ControlPlaneContext,
): Promise<Response> {
  if (!context.enqueueLaptopFiles) {
    return Response.json({ code: "enqueue_unavailable" }, { status: 503 });
  }
  let body: unknown;
  try {
    body = await request.json();
  } catch {
    return Response.json({ code: "invalid_json" }, { status: 400 });
  }
  const paths =
    body && typeof body === "object" && "paths" in body
      ? (body as { paths: unknown }).paths
      : undefined;
  if (
    !Array.isArray(paths) ||
    paths.length === 0 ||
    paths.length > 100 ||
    paths.some((path) => typeof path !== "string" || path.length === 0)
  ) {
    return Response.json({ code: "invalid_paths" }, { status: 400 });
  }
  try {
    const offer = await context.enqueueLaptopFiles(paths);
    return Response.json({ offer }, { status: 202 });
  } catch (error) {
    return Response.json(
      {
        code: "enqueue_failed",
        message: error instanceof Error ? error.message : String(error),
      },
      { status: 400 },
    );
  }
}

/**
 * The shell renders no remote assets: Manrope is served from this Relay and
 * the icons are inline SVG. Everything it needs is same-origin, so the policy
 * can start from 'none'. The page holds the pairing secret, and it is also
 * reachable by any browser on loopback, so it gets a real policy rather than
 * none at all.
 */
const SHELL_CSP = [
  "default-src 'none'",
  "script-src 'unsafe-inline'",
  "style-src 'unsafe-inline'",
  "img-src 'self' data:",
  "font-src 'self'",
  "connect-src 'self'",
  "base-uri 'none'",
  "form-action 'none'",
  "frame-ancestors 'none'",
].join("; ");

function htmlShellResponse(state: ControlState): Response {
  return new Response(desktopShellHtml(state), {
    headers: {
      "content-type": "text/html; charset=utf-8",
      "cache-control": "no-store",
      "content-security-policy": SHELL_CSP,
      "x-content-type-options": "nosniff",
      "referrer-policy": "no-referrer",
    },
  });
}

/**
 * Manrope is served from the Relay rather than a font CDN. The shell is a LAN
 * product, and ADR 0011 requires the product typeface to be locally packaged.
 * The bytes are baked into the compiled binary, so this works with no network
 * and no installed font.
 */
async function manropeFontResponse(): Promise<Response> {
  try {
    return new Response(await manropeFontBytes(), {
      headers: {
        "content-type": "font/ttf",
        "cache-control": "public, max-age=31536000, immutable",
      },
    });
  } catch (error) {
    return new Response("Font unavailable", { status: 500 });
  }
}
