import type { ProcessRunner } from "./clipboard";

/**
 * Hands a URL to the desktop's registered handler.
 *
 * xdg-open is the whole strategy, and that is deliberate. It routes to whatever
 * the session registered as the default handler, and every mainstream browser
 * then reuses an already-running instance and opens a tab in it, in whichever
 * profile it was last using. So "open a tab in the browser that is already
 * open, in the right profile" is answered by the browser rather than
 * reimplemented here.
 *
 * The alternative was considered and rejected: enumerating running browsers and
 * choosing a window or profile. On Wayland there is no window introspection to
 * lean on, and it would duplicate the browser's own session restore, badly and
 * with no way to test it. If it opens on an unwelcome profile, the fix is a
 * better default handler, not a smarter guess in the relay.
 */
export function openLinkWith(runner: ProcessRunner, url: string): Promise<void> {
  return runner.run("xdg-open", [url], undefined, { timeoutMs: 10_000 }).then((result) => {
    if (result.exitCode !== 0) {
      throw new Error(
        `xdg-open failed: ${result.stderr || `exit ${result.exitCode}`}`,
      );
    }
  });
}

/**
 * The last gate before a string becomes a process argument.
 *
 * Deliberately stricter than the phone's own check. The phone decides whether
 * a tab should appear, and being lenient there is reasonable because a false
 * positive costs a browser tab. This is the side that actually spawns, so it
 * accepts only an explicit http or https URL, with no whitespace and no
 * control characters, and a plausible authority.
 */
export function isOpenableLink(raw: string): boolean {
  const text = raw.trim();
  if (!text || text.length > 2048) return false;
  if (!/^https?:\/\//i.test(text)) return false;
  if (/[\s\u0000-\u001f\u007f]/.test(text)) return false;
  const authority = text.replace(/^https?:\/\//i, "").split(/[/?#]/)[0] ?? "";
  if (!authority) return false;
  // Letters, digits and the punctuation legal in a host, port, or userinfo.
  // Nothing here can start a second argument, close the string, or name a file.
  return /^[A-Za-z0-9._~%!$&'()*+,;=:@[\]-]+$/.test(authority);
}
