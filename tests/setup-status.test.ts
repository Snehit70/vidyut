import { describe, expect, test } from "bun:test";
import {
  collectLaptopSetupStatus,
  createSetupStatusReader,
  type LaptopSetupStatus,
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

describe("setup status reader", () => {
  function healthy(checkedAtMs: number): LaptopSetupStatus {
    return {
      checkedAtMs,
      rows: [{ id: "relay_running", ok: true, detail: "Relay is answering." }],
    };
  }

  function countingProbe() {
    let calls = 0;
    return {
      calls: () => calls,
      collect: async () => {
        calls += 1;
        return healthy(0);
      },
    };
  }

  test("serves a warm answer without re-probing", async () => {
    const probe = countingProbe();
    const read = createSetupStatusReader({ ttlMs: 30_000, collect: probe.collect });

    const first = await read();
    const second = await read();
    const third = await read();

    expect(probe.calls()).toBe(1);
    expect(second).toBe(first);
    expect(third).toBe(first);
  });

  test("re-probes once the answer is older than the ttl", async () => {
    let clock = 1_000_000;
    const probe = countingProbe();
    const read = createSetupStatusReader({
      ttlMs: 30_000,
      now: () => clock,
      collect: probe.collect,
    });

    await read();
    clock += 29_000;
    await read();
    expect(probe.calls()).toBe(1);

    clock += 2_000;
    await read();
    expect(probe.calls()).toBe(2);
  });

  test("a forced read bypasses a warm cache", async () => {
    const probe = countingProbe();
    const read = createSetupStatusReader({ ttlMs: 30_000, collect: probe.collect });

    await read();
    await read();
    expect(probe.calls()).toBe(1);

    await read(true);
    expect(probe.calls()).toBe(2);
  });

  test("concurrent readers share one probe", async () => {
    let release: (() => void) | undefined;
    const gate = new Promise<void>((resolve) => {
      release = resolve;
    });
    let calls = 0;
    const read = createSetupStatusReader({
      ttlMs: 30_000,
      collect: async () => {
        calls += 1;
        await gate;
        return healthy(0);
      },
    });

    const all = Promise.all([read(), read(), read(), read(), read()]);
    release?.();
    const results = await all;

    expect(calls).toBe(1);
    for (const result of results) expect(result).toBe(results[0]);
  });

  test("a forced read joins an in-flight probe instead of starting another", async () => {
    let release: (() => void) | undefined;
    const gate = new Promise<void>((resolve) => {
      release = resolve;
    });
    let calls = 0;
    const read = createSetupStatusReader({
      ttlMs: 30_000,
      collect: async () => {
        calls += 1;
        await gate;
        return healthy(0);
      },
    });

    const all = Promise.all([read(), read(true), read(true)]);
    release?.();
    await all;
    expect(calls).toBe(1);
  });

  test("a failed probe is not cached and does not wedge the reader", async () => {
    let calls = 0;
    const read = createSetupStatusReader({
      ttlMs: 30_000,
      collect: async () => {
        calls += 1;
        if (calls === 1) throw new Error("probe exploded");
        return healthy(0);
      },
    });

    await expect(read()).rejects.toThrow("probe exploded");
    await read();
    expect(calls).toBe(2);
  });

  test("freshness is stamped by the reader, not trusted from the probe", async () => {
    let clock = 5_000_000;
    const read = createSetupStatusReader({
      ttlMs: 30_000,
      now: () => clock,
      // A probe reporting a nonsense timestamp must not poison the cache.
      collect: async () => healthy(0),
    });

    const first = await read();
    expect(first.checkedAtMs).toBe(5_000_000);

    clock += 1_000;
    const second = await read();
    expect(second.checkedAtMs).toBe(5_000_000);
  });
});
