/**
 * The control plane answers only loopback peers, but a loopback peer is not
 * the same thing as a trusted caller. A web page the user has open can reach
 * 127.0.0.1 too: by DNS rebinding a hostname it controls (the request then
 * carries that hostname in Host), or by firing a simple cross-site POST that
 * needs no preflight. Both would hand a page the pairing secret or let it
 * queue local files for the phone.
 *
 * These checks close that off without breaking the real callers: the shell
 * (same origin, http://127.0.0.1:PORT), the Tauri tray (raw HTTP with Host
 * 127.0.0.1:PORT and no Origin), and the phone's WebSocket (no Origin).
 */

const loopbackHostnames = new Set(["127.0.0.1", "localhost", "[::1]"]);

/** Returns a 403 response when the request did not come from a local caller. */
export function rejectUntrustedControlRequest(
  request: Request,
  port: number,
): Response | undefined {
  if (!isLoopbackHost(request.headers.get("host"), port)) {
    return forbidden("untrusted_host");
  }
  const origin = request.headers.get("origin");
  if (origin !== null && !isLoopbackOrigin(origin, port)) {
    return forbidden("untrusted_origin");
  }
  // Top-level navigation into the shell is fine from anywhere (the Tauri boot
  // page navigates in from tauri://localhost), and a cross-site GET cannot
  // read the response. Anything that changes state must come from the shell
  // itself or from a client that is not a browser at all.
  if (request.method !== "GET" && request.method !== "HEAD") {
    const site = request.headers.get("sec-fetch-site");
    if (site !== null && site !== "same-origin" && site !== "none") {
      return forbidden("cross_site_request");
    }
  }
  return undefined;
}

/**
 * Browsers always send Origin on a WebSocket handshake; the phone's dart:io
 * client and the CLI do not. A page on any site could otherwise open a socket
 * to the Relay, and while it cannot authenticate without the secret, it should
 * not get a challenge to work against either.
 */
export function isTrustedWebSocketOrigin(
  origin: string | null,
  port: number,
): boolean {
  return origin === null || isLoopbackOrigin(origin, port);
}

export function isLoopbackHost(host: string | null, port: number): boolean {
  if (!host) return false;
  const { hostname, hostPort } = splitHost(host.toLowerCase());
  if (!loopbackHostnames.has(hostname)) return false;
  return hostPort === undefined || hostPort === String(port);
}

function isLoopbackOrigin(origin: string, port: number): boolean {
  let url: URL;
  try {
    url = new URL(origin);
  } catch {
    return false;
  }
  return (
    url.protocol === "http:" &&
    loopbackHostnames.has(url.hostname) &&
    url.port === String(port)
  );
}

function splitHost(host: string): { hostname: string; hostPort?: string } {
  if (host.startsWith("[")) {
    const end = host.indexOf("]");
    if (end === -1) return { hostname: host };
    const rest = host.slice(end + 1);
    return {
      hostname: host.slice(0, end + 1),
      ...(rest.startsWith(":") && { hostPort: rest.slice(1) }),
    };
  }
  const colon = host.lastIndexOf(":");
  if (colon === -1) return { hostname: host };
  return { hostname: host.slice(0, colon), hostPort: host.slice(colon + 1) };
}

function forbidden(code: string): Response {
  return Response.json({ code }, { status: 403 });
}
