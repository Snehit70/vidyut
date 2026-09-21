import {
  createPairingSecret,
  pairingSecretValue,
  type PairingSecretRef,
} from "./config";
import {
  createPairingQrSvg,
  pairingManualLine,
  type PairingCodeOptions,
} from "./pairing";
import {
  collectLaptopSetupStatus,
  type LaptopSetupStatus,
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
  setupStatus?: () => Promise<LaptopSetupStatus>;
}

export function isControlPath(pathname: string): boolean {
  return (
    pathname === "/" ||
    pathname === "/ui" ||
    pathname === "/ui/" ||
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
    return htmlShell(controlState(context));
  }
  if (request.method === "GET" && path === "/control/v1/state") {
    return Response.json(controlState(context));
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
    const status = await (context.setupStatus ?? collectLaptopSetupStatus)();
    return Response.json(status);
  }
  return new Response("Not found", { status: 404 });
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

function htmlShell(state: ControlState): Response {
  const statusLabel =
    state.syncState === "sync_needs_attention"
      ? "Sync needs attention"
      : "Ready";
  const html = `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8"/>
  <meta name="viewport" content="width=device-width, initial-scale=1"/>
  <title>Vidyut</title>
  <style>
    :root {
      --ground: #ffffff;
      --mist: #fdf0f4;
      --raspberry: #c83861;
      --ink: #33202b;
      --muted: #856774;
      --hairline: #9d878f;
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      font-family: Manrope, "Segoe UI", sans-serif;
      background: var(--mist);
      color: var(--ink);
    }
    main {
      max-width: 42rem;
      margin: 0 auto;
      padding: 2.5rem 1.5rem 4rem;
    }
    h1 { font-size: 1.75rem; margin: 0 0 0.25rem; }
    .status { color: var(--raspberry); font-weight: 600; margin-bottom: 1.5rem; }
    .card {
      background: var(--ground);
      border: 1px solid var(--hairline);
      border-radius: 1rem;
      padding: 1.25rem 1.5rem;
      margin-bottom: 1rem;
    }
    .qr { width: 14rem; height: 14rem; background: #fff; }
    dl { display: grid; grid-template-columns: 7rem 1fr; gap: 0.4rem 1rem; margin: 1rem 0 0; }
    dt { color: var(--muted); }
    dd { margin: 0; word-break: break-all; }
    .manual { font-family: ui-monospace, monospace; font-size: 0.9rem; }
  </style>
</head>
<body>
  <main>
    <h1>Vidyut</h1>
    <p class="status">${escapeHtml(statusLabel)}</p>
    <section class="card">
      <p>Point the phone at this pairing QR. One secret is shared by every device.</p>
      <img class="qr" alt="Pairing QR" src="/control/v1/qr.svg"/>
      <dl>
        <dt>Laptop</dt><dd>${escapeHtml(state.relayName)}</dd>
        <dt>Host</dt><dd>${escapeHtml(state.host)}</dd>
        <dt>Port</dt><dd>${escapeHtml(String(state.port))}</dd>
        <dt>Secret</dt><dd>${escapeHtml(state.pairingSecret)}</dd>
        <dt>Manual</dt><dd class="manual">${escapeHtml(state.manual)}</dd>
        <dt>Devices</dt><dd>${escapeHtml(String(state.authenticatedDeviceCount))}</dd>
      </dl>
    </section>
  </main>
</body>
</html>
`;
  return new Response(html, {
    headers: { "content-type": "text/html; charset=utf-8" },
  });
}

function escapeHtml(value: string): string {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}
