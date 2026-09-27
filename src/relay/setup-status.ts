export type SetupRowId =
  | "relay_running"
  | "wayland"
  | "wl_clipboard"
  | "imagemagick"
  | "autostart"
  | "firewall";

export interface SetupRow {
  id: SetupRowId;
  ok: boolean;
  detail: string;
  fix?: string;
}

export interface LaptopSetupStatus {
  rows: SetupRow[];
  /** When these rows were actually probed, not when they were served. */
  checkedAtMs: number;
}

export interface SetupStatusDeps {
  env?: NodeJS.ProcessEnv;
  which?: (bin: string) => string | null;
  run?: (argv: string[]) => Promise<{ code: number; text: string }>;
  port?: number;
  now?: () => number;
}

const defaultRelayPort = 17321;

/** Probing shells out to up to six processes, so it is cached, not free. */
export const setupStatusTtlMs = 30_000;

export async function collectLaptopSetupStatus(
  deps: SetupStatusDeps = {},
): Promise<LaptopSetupStatus> {
  const env = deps.env ?? process.env;
  const which = deps.which ?? ((bin: string) => Bun.which(bin));
  const run = deps.run ?? runCapture;
  const now = deps.now ?? Date.now;
  const port =
    typeof deps.port === "number" &&
    Number.isInteger(deps.port) &&
    deps.port > 0 &&
    deps.port <= 65535
      ? deps.port
      : defaultRelayPort;
  const [clipboard, imagemagick, autostart, firewall] = await Promise.all([
    probeWlClipboard(which, run),
    probeImageMagick(which, run),
    probeAutostart(which, run),
    probeFirewall(which, run, port),
  ]);
  return {
    checkedAtMs: now(),
    rows: [
      {
        id: "relay_running",
        ok: true,
        detail: "Relay is answering.",
      },
      waylandRow(env),
      clipboard,
      imagemagick,
      autostart,
      firewall,
    ],
  };
}

export type SetupStatusReader = (
  force?: boolean,
) => Promise<LaptopSetupStatus>;

export interface SetupStatusReaderOptions {
  ttlMs?: number;
  now?: () => number;
  deps?: SetupStatusDeps;
  collect?: (deps: SetupStatusDeps) => Promise<LaptopSetupStatus>;
}

/**
 * A caching, single-flight reader for laptop setup status.
 *
 * Every probe forks several processes, so a naive read-per-request costs a
 * process storm: the desktop shell polls every few seconds, and each open
 * window adds its own poll. Two things fix that. A TTL keeps the answer warm,
 * and single-flight makes concurrent readers share one probe instead of each
 * starting their own.
 *
 * The reader stamps and checks freshness against its own clock rather than
 * trusting the probe's timestamp, so a probe that reports its own time cannot
 * desynchronise the cache.
 *
 * A failed probe is never cached, so a transient error cannot leave the UI
 * showing a stale verdict as if it were current.
 */
export function createSetupStatusReader(
  options: SetupStatusReaderOptions = {},
): SetupStatusReader {
  const ttlMs = options.ttlMs ?? setupStatusTtlMs;
  const now = options.now ?? Date.now;
  const collect = options.collect ?? collectLaptopSetupStatus;
  let cached: LaptopSetupStatus | undefined;
  let inFlight: Promise<LaptopSetupStatus> | undefined;

  return async function read(force = false): Promise<LaptopSetupStatus> {
    if (!force && cached && now() - cached.checkedAtMs < ttlMs) {
      return cached;
    }
    if (inFlight) return inFlight;
    inFlight = collect({ ...options.deps, now })
      .then((status) => {
        cached = { ...status, checkedAtMs: now() };
        return cached;
      })
      .finally(() => {
        inFlight = undefined;
      });
    return inFlight;
  };
}

function waylandRow(env: NodeJS.ProcessEnv): SetupRow {
  const display = env.WAYLAND_DISPLAY;
  if (display && display.length > 0) {
    return {
      id: "wayland",
      ok: true,
      detail: `WAYLAND_DISPLAY=${display}`,
    };
  }
  return {
    id: "wayland",
    ok: false,
    detail: env.DISPLAY
      ? "X11 is not supported. Vidyut needs a Wayland session."
      : "WAYLAND_DISPLAY is unset.",
    fix: "Log into a Wayland session. X11 has no adapter.",
  };
}

async function probeWlClipboard(
  which: NonNullable<SetupStatusDeps["which"]>,
  run: NonNullable<SetupStatusDeps["run"]>,
): Promise<SetupRow> {
  const bin = which("wl-paste");
  if (!bin) {
    return {
      id: "wl_clipboard",
      ok: false,
      detail: "wl-paste was not found.",
      fix: "Install wl-clipboard 2.3 or newer.",
    };
  }
  const output = await run([bin, "--version"]);
  const version = parseVersion(output.text);
  if (!version) {
    return {
      id: "wl_clipboard",
      ok: false,
      detail: output.text || "wl-paste --version produced no version.",
      fix: "Install wl-clipboard 2.3 or newer.",
    };
  }
  const ok = version.major > 2 || (version.major === 2 && version.minor >= 3);
  return {
    id: "wl_clipboard",
    ok,
    detail: ok
      ? `wl-clipboard ${version.raw}`
      : `wl-clipboard ${version.raw} is below 2.3`,
    ...(!ok && { fix: "Install wl-clipboard 2.3 or newer." }),
  };
}

async function probeImageMagick(
  which: NonNullable<SetupStatusDeps["which"]>,
  run: NonNullable<SetupStatusDeps["run"]>,
): Promise<SetupRow> {
  const bin = which("magick");
  if (!bin) {
    return {
      id: "imagemagick",
      ok: false,
      detail: "magick was not found.",
      fix: "Install ImageMagick.",
    };
  }
  const output = await run([bin, "-version"]);
  const first = output.text.split("\n")[0] ?? "magick";
  return {
    id: "imagemagick",
    ok: output.code === 0,
    detail: first,
    ...(output.code !== 0 && { fix: "Install ImageMagick." }),
  };
}

async function probeAutostart(
  which: NonNullable<SetupStatusDeps["which"]>,
  run: NonNullable<SetupStatusDeps["run"]>,
): Promise<SetupRow> {
  const bin = which("systemctl");
  if (!bin) {
    return {
      id: "autostart",
      ok: false,
      detail: "systemctl was not found.",
    };
  }
  const output = await run([
    bin,
    "--user",
    "is-enabled",
    "vidyut-relay.service",
  ]);
  const enabled = output.code === 0 && output.text.trim() === "enabled";
  return {
    id: "autostart",
    ok: enabled,
    detail: output.text.trim() || "vidyut-relay.service is not enabled.",
    ...(!enabled && {
      fix: "systemctl --user enable --now vidyut-relay.service",
    }),
  };
}

async function probeFirewall(
  which: NonNullable<SetupStatusDeps["which"]>,
  run: NonNullable<SetupStatusDeps["run"]>,
  port: number,
): Promise<SetupRow> {
  const firewallCmd = which("firewall-cmd");
  if (firewallCmd) {
    const state = await run([firewallCmd, "--state"]);
    if (state.code === 0 && /running/i.test(state.text)) {
      const query = await run([
        firewallCmd,
        `--query-port=${port}/tcp`,
      ]);
      if (query.code === 0) {
        return {
          id: "firewall",
          ok: true,
          detail: `firewalld allows ${port}/tcp`,
        };
      }
      return {
        id: "firewall",
        ok: false,
        detail: `firewalld is running and ${port}/tcp is not allowed.`,
        fix: `sudo firewall-cmd --permanent --add-port=${port}/tcp && sudo firewall-cmd --reload`,
      };
    }
  }

  const ufw = which("ufw");
  if (ufw) {
    const status = await run([ufw, "status"]);
    if (status.code !== 0) {
      return {
        id: "firewall",
        ok: false,
        detail: status.text.trim() || "Could not query ufw.",
        fix: `Allow TCP ${port} on the LAN zone.`,
      };
    }
    if (/Status:\s*inactive/i.test(status.text)) {
      return {
        id: "firewall",
        ok: true,
        detail: "ufw is inactive.",
      };
    }
    if (/Status:\s*active/i.test(status.text)) {
      if (ufwAllowsRelayPort(status.text, port)) {
        return {
          id: "firewall",
          ok: true,
          detail: `ufw allows ${port}/tcp`,
        };
      }
      return {
        id: "firewall",
        ok: false,
        detail: `ufw is active and ${port}/tcp is not allowed.`,
        fix: `sudo ufw allow ${port}/tcp && sudo ufw allow 5353/udp`,
      };
    }
    return {
      id: "firewall",
      ok: false,
      detail: status.text.trim() || "Could not parse ufw status.",
      fix: `Allow TCP ${port} on the LAN zone.`,
    };
  }

  return {
    id: "firewall",
    ok: true,
    detail: "No active firewalld or ufw.",
  };
}

function ufwAllowsRelayPort(status: string, port: number): boolean {
  return status
    .split("\n")
    .some(
      (line) =>
        line.includes(`${port}/tcp`) && /ALLOW/i.test(line),
    );
}

function parseVersion(
  text: string,
): { raw: string; major: number; minor: number } | undefined {
  const match = text.match(/(\d+)\.(\d+)/);
  if (!match?.[1] || !match[2]) return undefined;
  return {
    raw: `${match[1]}.${match[2]}`,
    major: Number(match[1]),
    minor: Number(match[2]),
  };
}

async function runCapture(argv: string[]): Promise<{ code: number; text: string }> {
  try {
    const proc = Bun.spawn(argv, { stdout: "pipe", stderr: "pipe" });
    const timer = setTimeout(() => proc.kill(), 2_000);
    const stdout = await new Response(proc.stdout).text();
    const stderr = await new Response(proc.stderr).text();
    const code = await proc.exited;
    clearTimeout(timer);
    return { code, text: `${stdout}\n${stderr}`.trim() };
  } catch {
    return { code: 127, text: "" };
  }
}
