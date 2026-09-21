import { describe, expect, test } from "bun:test";
import {
  collectLaptopSetupStatus,
  type SetupRow,
  type SetupStatusDeps,
} from "../src/relay/setup-status";

function deps(options: {
  env?: NodeJS.ProcessEnv;
  bins?: Record<string, string>;
  outputs?: Record<string, { code: number; text: string }>;
}): SetupStatusDeps {
  const bins = options.bins ?? {};
  const outputs = options.outputs ?? {};
  return {
    env: options.env ?? { WAYLAND_DISPLAY: "wayland-1" },
    which: (bin) => bins[bin] ?? null,
    run: async (argv) => {
      const key = argv.join(" ");
      const output = outputs[key];
      if (!output) {
        throw new Error(`unexpected command: ${key}`);
      }
      return output;
    },
  };
}

function row(
  status: Awaited<ReturnType<typeof collectLaptopSetupStatus>>,
  id: string,
): SetupRow {
  const found = status.rows.find((entry) => entry.id === id);
  if (!found) throw new Error(`missing row ${id}`);
  return found;
}

describe("laptop setup status", () => {
  test("reports live rows instead of a hardcoded firewall unknown", async () => {
    const status = await collectLaptopSetupStatus(
      deps({
        bins: {
          "wl-paste": "/usr/bin/wl-paste",
          magick: "/usr/bin/magick",
          systemctl: "/usr/bin/systemctl",
          "firewall-cmd": "/usr/bin/firewall-cmd",
        },
        outputs: {
          "/usr/bin/wl-paste --version": { code: 0, text: "wl-clipboard 2.3.0" },
          "/usr/bin/magick -version": {
            code: 0,
            text: "Version: ImageMagick 7.1.1",
          },
          "/usr/bin/systemctl --user is-enabled vidyut-relay.service": {
            code: 0,
            text: "enabled",
          },
          "/usr/bin/firewall-cmd --state": { code: 0, text: "running" },
          "/usr/bin/firewall-cmd --query-port=17321/tcp": {
            code: 0,
            text: "yes",
          },
        },
      }),
    );
    expect(status.rows.map((entry) => entry.id)).toEqual([
      "relay_running",
      "wayland",
      "wl_clipboard",
      "imagemagick",
      "autostart",
      "firewall",
    ]);
    expect(row(status, "relay_running")).toMatchObject({ ok: true });
    expect(row(status, "wayland")).toMatchObject({
      ok: true,
      detail: "WAYLAND_DISPLAY=wayland-1",
    });
    expect(row(status, "wl_clipboard")).toMatchObject({
      ok: true,
      detail: "wl-clipboard 2.3",
    });
    expect(row(status, "imagemagick").ok).toBe(true);
    expect(row(status, "autostart").ok).toBe(true);
    expect(row(status, "firewall")).toEqual({
      id: "firewall",
      ok: true,
      detail: "firewalld allows 17321/tcp",
    });
    expect(JSON.stringify(status)).not.toContain("unknown");
  });

  test("X11 is not an adapter", async () => {
    const status = await collectLaptopSetupStatus(
      deps({ env: { DISPLAY: ":0" } }),
    );
    expect(row(status, "wayland")).toEqual({
      id: "wayland",
      ok: false,
      detail: "X11 is not supported. Vidyut needs a Wayland session.",
      fix: "Log into a Wayland session. X11 has no adapter.",
    });
  });

  test("wl-clipboard below 2.3 is not ok", async () => {
    const status = await collectLaptopSetupStatus(
      deps({
        bins: { "wl-paste": "/usr/bin/wl-paste" },
        outputs: {
          "/usr/bin/wl-paste --version": { code: 0, text: "wl-clipboard 2.2.1" },
        },
      }),
    );
    expect(row(status, "wl_clipboard")).toEqual({
      id: "wl_clipboard",
      ok: false,
      detail: "wl-clipboard 2.2 is below 2.3",
      fix: "Install wl-clipboard 2.3 or newer.",
    });
  });

  test("firewalld uses the configured relay port", async () => {
    const status = await collectLaptopSetupStatus({
      ...deps({
        bins: { "firewall-cmd": "/usr/bin/firewall-cmd" },
        outputs: {
          "/usr/bin/firewall-cmd --state": { code: 0, text: "running" },
          "/usr/bin/firewall-cmd --query-port=18000/tcp": {
            code: 0,
            text: "yes",
          },
        },
      }),
      port: 18000,
    });
    expect(row(status, "firewall")).toEqual({
      id: "firewall",
      ok: true,
      detail: "firewalld allows 18000/tcp",
    });
  });

  test("firewalld blocking 17321 is not ok", async () => {
    const status = await collectLaptopSetupStatus(
      deps({
        bins: { "firewall-cmd": "/usr/bin/firewall-cmd" },
        outputs: {
          "/usr/bin/firewall-cmd --state": { code: 0, text: "running" },
          "/usr/bin/firewall-cmd --query-port=17321/tcp": {
            code: 1,
            text: "no",
          },
        },
      }),
    );
    expect(row(status, "firewall")).toEqual({
      id: "firewall",
      ok: false,
      detail: "firewalld is running and 17321/tcp is not allowed.",
      fix: "sudo firewall-cmd --permanent --add-port=17321/tcp && sudo firewall-cmd --reload",
    });
  });

  test("active ufw without 17321 is not ok", async () => {
    const status = await collectLaptopSetupStatus(
      deps({
        bins: { ufw: "/usr/sbin/ufw" },
        outputs: {
          "/usr/sbin/ufw status": {
            code: 0,
            text: "Status: active\n22/tcp                     ALLOW       Anywhere",
          },
        },
      }),
    );
    expect(row(status, "firewall")).toMatchObject({
      ok: false,
      detail: "ufw is active and 17321/tcp is not allowed.",
    });
  });

  test("inactive ufw is ok", async () => {
    const status = await collectLaptopSetupStatus(
      deps({
        bins: { ufw: "/usr/sbin/ufw" },
        outputs: {
          "/usr/sbin/ufw status": { code: 0, text: "Status: inactive" },
        },
      }),
    );
    expect(row(status, "firewall")).toEqual({
      id: "firewall",
      ok: true,
      detail: "ufw is inactive.",
    });
  });

  test("no firewall tool is reported instead of unknown", async () => {
    const status = await collectLaptopSetupStatus(deps({}));
    expect(row(status, "firewall")).toEqual({
      id: "firewall",
      ok: true,
      detail: "No active firewalld or ufw.",
    });
  });
});
