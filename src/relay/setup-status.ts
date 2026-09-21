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
}

export async function collectLaptopSetupStatus(): Promise<LaptopSetupStatus> {
  const [clipboard, imagemagick, autostart] = await Promise.all([
    probeWlClipboard(),
    probeImageMagick(),
    probeAutostart(),
  ]);
  return {
    rows: [
      {
        id: "relay_running",
        ok: true,
        detail: "Relay is answering.",
      },
      waylandRow(),
      clipboard,
      imagemagick,
      autostart,
      {
        id: "firewall",
        ok: true,
        detail: "unknown",
      },
    ],
  };
}

function waylandRow(): SetupRow {
  const display = process.env.WAYLAND_DISPLAY;
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
    detail: process.env.DISPLAY
      ? "X11 is not supported. Vidyut needs a Wayland session."
      : "WAYLAND_DISPLAY is unset.",
    fix: "Log into a Wayland session. X11 has no adapter.",
  };
}

async function probeWlClipboard(): Promise<SetupRow> {
  const bin = Bun.which("wl-paste");
  if (!bin) {
    return {
      id: "wl_clipboard",
      ok: false,
      detail: "wl-paste was not found.",
      fix: "Install wl-clipboard 2.3 or newer.",
    };
  }
  const output = await runCapture([bin, "--version"]);
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

async function probeImageMagick(): Promise<SetupRow> {
  const bin = Bun.which("magick");
  if (!bin) {
    return {
      id: "imagemagick",
      ok: false,
      detail: "magick was not found.",
      fix: "Install ImageMagick.",
    };
  }
  const output = await runCapture([bin, "-version"]);
  const first = output.text.split("\n")[0] ?? "magick";
  return {
    id: "imagemagick",
    ok: output.code === 0,
    detail: first,
    ...(output.code !== 0 && { fix: "Install ImageMagick." }),
  };
}

async function probeAutostart(): Promise<SetupRow> {
  const bin = Bun.which("systemctl");
  if (!bin) {
    return {
      id: "autostart",
      ok: false,
      detail: "systemctl was not found.",
    };
  }
  const output = await runCapture([
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
