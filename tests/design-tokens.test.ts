import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

import { desktopShellHtml } from "../src/relay/desktop-shell-page";
import { bundledPageCsp, SHELL_CSP } from "../src/relay/control-plane";

const root = join(import.meta.dir, "..");
const read = (relative: string) => readFileSync(join(root, relative), "utf8");

const tokensCss = read("design/tokens.css");
const paletteDart = read("app/lib/src/design/palette.dart");
const themeDart = read("app/lib/src/design/theme.dart");
const shellHtml = desktopShellHtml({
  relayName: "Vidyut Relay",
  host: "192.168.1.4",
  port: 17321,
  pairingSecret: "s3cret",
  manual: "host=192.168.1.4 port=17321 secret=s3cret",
  syncState: "ready",
  authenticatedDeviceCount: 1,
});
const shellCss = shellHtml.match(/<style>([\s\S]*?)<\/style>/)?.[1] ?? "";

/**
 * Canonical tokens the shell deliberately does not consume, each with the
 * reason. The shell still may not contradict a value it does consume; this
 * list exists so that *not* consuming one is a recorded decision rather than
 * an accident.
 *
 * The desktop shell is a mouse-driven control panel, not the phone, so the
 * cases fall into three groups: the phone's own text ramp, the phone's touch
 * spacing scale, and motion the shell does not perform.
 */
const EXEMPT: Record<string, string> = {
  // The phone's text ramp. The shell renders pane titles, row labels and
  // body copy, and declares the subset it uses. Flutter's display/headline/
  // appbar styles have no desktop counterpart.
  "--type-display-size": "phone-only display style",
  "--type-display-weight": "phone-only display style",
  "--type-display-tracking": "phone-only display style",
  "--type-headline-size": "phone-only headline style",
  "--type-headline-weight": "phone-only headline style",
  "--type-headline-tracking": "phone-only headline style",
  "--type-body-lg-size": "phone-only body scale",
  "--type-body-lg-weight": "phone-only body scale",
  "--type-body-md-weight": "phone-only body scale",
  "--type-body-sm-size": "phone-only body scale",
  "--type-body-sm-weight": "phone-only body scale",
  "--type-label-md-size": "phone-only label scale",
  "--type-label-md-weight": "phone-only label scale",
  "--type-appbar-size": "the shell has a title bar, not a phone app bar",
  "--type-appbar-weight": "the shell has a title bar, not a phone app bar",
  "--type-appbar-tracking": "the shell has a title bar, not a phone app bar",

  // Touch metrics. The phone's 48px control and 4/8/12/16 spacing ramp are
  // sized for a finger. A mouse-driven window declares its own densities in
  // the shell stylesheet, deliberately outside the token set.
  "--control-height": "48px is a touch target; the shell uses --control-height-compact",
  "--space-4": "touch spacing ramp; the shell has its own density",
  "--space-6": "touch spacing ramp; the shell has its own density",
  "--space-8": "touch spacing ramp; the shell has its own density",
  "--space-10": "touch spacing ramp; the shell has its own density",
  "--space-12": "touch spacing ramp; the shell has its own density",
  "--space-14": "touch spacing ramp; the shell has its own density",
  "--space-16": "touch spacing ramp; the shell has its own density",
  "--space-20": "touch spacing ramp; the shell has its own density",
  "--space-24": "touch spacing ramp; the shell has its own density",
  "--radius-pill": "the shell uses --radius-control for its controls",
  "--hairline-width": "the shell declares its own hairline weight",

  // Motion the shell does not perform. ADR 0013 makes motion feedback-only,
  // so the entrance and stagger timings have no consumer here.
  "--dur-entrance": "ADR 0013: no entrance choreography on a long surface",
  "--dur-stagger": "ADR 0013: no entrance choreography on a long surface",
  "--ease-spring": "no spring-eased motion in the shell",
  "--dur-dot-pulse": "the shell's status dots do not pulse",
  "--dur-state": "the shell transitions state without a dedicated duration",

  // Interaction colours the phone uses for pressed and outlined controls
  // that the shell does not have.
  "--active": "no pressed-state fill in the shell",
  "--active-mist": "no pressed-state fill in the shell",
  "--text-label-small": "the shell labels at the label scale it declares",
  "--border-strong": "the shell uses --hairline for borders",
};

type Blocks = { light: Record<string, string>; dark: Record<string, string> };

function parseBlocks(css: string): Blocks {
  const marker = "@media (prefers-color-scheme: dark)";
  const at = css.indexOf(marker);
  return {
    light: parseRoot(css.slice(0, at === -1 ? css.length : at)),
    dark: parseRoot(at === -1 ? "" : css.slice(at)),
  };
}

function parseRoot(css: string): Record<string, string> {
  // Strip comments first: a comment sharing a chunk with a declaration would
  // otherwise swallow the declaration's name.
  const clean = css.replace(/\/\*[\s\S]*?\*\//g, "");
  const out: Record<string, string> = {};
  for (const block of clean.matchAll(/:root\s*\{([^}]*)\}/g)) {
    for (const declaration of block[1]!.split(";")) {
      const at = declaration.indexOf(":");
      if (at === -1) continue;
      const name = declaration.slice(0, at).trim();
      if (name.startsWith("--")) out[name] = declaration.slice(at + 1).trim();
    }
  }
  return out;
}

function parsePalette(): { light: Record<string, string>; dark: Record<string, string> } {
  const light: Record<string, string> = {};
  const dark: Record<string, string> = {};
  for (const match of paletteDart.matchAll(
    /static const (\w+) = Color\(0x([0-9A-Fa-f]{8})\);/g,
  )) {
    const hex = `#${match[2]!.slice(2)}`.toUpperCase();
    if (match[1]!.startsWith("dark")) dark[match[1]!.slice(4)] = hex;
    else light[match[1]!] = hex;
  }
  return { light, dark };
}

const shell = parseBlocks(shellCss);
const canonical = parseBlocks(tokensCss);
const palette = parsePalette();

/** CSS token -> Dart palette constant, for the primitive colors. */
const COLOR_TOKENS: Record<string, string> = {
  "--ground": "ground",
  "--mist": "mist",
  "--petal": "petal",
  "--raspberry": "raspberry",
  "--ink": "ink",
  "--muted": "muted",
  "--hairline": "hairline",
  "--error": "error",
  "--active": "active",
  "--active-mist": "activeMist",
  "--success": "success",
  "--success-mist": "successMist",
  "--warning": "warning",
  "--warning-mist": "warningMist",
};

/** Flutter textTheme role -> the three CSS tokens that encode it. */
const TYPE_ROLES: Record<string, string> = {
  displaySmall: "type-display",
  headlineMedium: "type-headline",
  titleLarge: "type-title-lg",
  titleMedium: "type-title-md",
  titleSmall: "type-title-sm",
  bodyLarge: "type-body-lg",
  bodyMedium: "type-body-md",
  bodySmall: "type-body-sm",
  labelLarge: "type-label-lg",
  labelMedium: "type-label-md",
  labelSmall: "type-label-sm",
};

function parseTypeRamp(): Record<string, { size: string; weight: string; tracking: string }> {
  const out: Record<string, { size: string; weight: string; tracking: string }> = {};
  for (const match of themeDart.matchAll(
    /(\w+): style\(([\d.]+), FontWeight\.w(\d+)(?:, tracking: (-?[\d.]+))?(?:, color: [\w.]+)?\)/g,
  )) {
    out[match[1]!] = {
      size: `${match[2]}px`,
      weight: match[3]!,
      tracking: `${match[4] ?? 0}px`,
    };
  }
  return out;
}

function fromTheme(pattern: RegExp): string {
  return themeDart.match(pattern)?.[1] ?? "";
}

describe("design tokens", () => {
  test("light colors match palette.dart", () => {
    for (const [token, constant] of Object.entries(COLOR_TOKENS)) {
      expect(canonical.light[token], `tokens.css ${token}`).toBe(
        palette.light[constant],
      );
    }
  });

  test("dark colors match palette.dart", () => {
    for (const [token, constant] of Object.entries(COLOR_TOKENS)) {
      if (constant === "active" || constant === "activeMist") continue;
      if (!(constant in palette.dark)) continue;
      expect(canonical.dark[token], `tokens.css dark ${token}`).toBe(
        palette.dark[constant],
      );
    }
  });

  test("type ramp matches theme.dart", () => {
    const ramp = parseTypeRamp();
    for (const [role, prefix] of Object.entries(TYPE_ROLES)) {
      const style = ramp[role];
      expect(style, `theme.dart has a ${role} style`).toBeDefined();
      expect(canonical.light[`--${prefix}-size`]).toBe(style!.size);
      expect(canonical.light[`--${prefix}-weight`]).toBe(style!.weight);
    }
  });

  test("app bar title and line height match theme.dart", () => {
    const appBar = themeDart.match(
      /titleTextStyle: style\(([\d.]+), FontWeight\.w(\d+), tracking: (-?[\d.]+)\)/,
    );
    expect(appBar).not.toBeNull();
    expect(canonical.light["--type-appbar-size"]).toBe(`${appBar![1]}px`);
    expect(canonical.light["--type-appbar-weight"]).toBe(appBar![2]);
    expect(canonical.light["--type-appbar-tracking"]).toBe(`${appBar![3]}px`);
    expect(canonical.light["--type-line-height"]).toBe(fromTheme(/height: ([\d.]+),/));
  });

  test("shape tokens match theme.dart", () => {
    expect(canonical.light["--radius-card"]).toBe(
      `${fromTheme(/cardTheme: CardThemeData\([\s\S]*?BorderRadius\.circular\((\d+)\)/)}px`,
    );
    expect(canonical.light["--radius-control"]).toBe(
      `${fromTheme(/filledButtonTheme:[\s\S]*?BorderRadius\.circular\((\d+)\)/)}px`,
    );
    expect(canonical.light["--control-height"]).toBe(
      `${fromTheme(/filledButtonTheme:[\s\S]*?Size\.fromHeight\((\d+)\)/)}px`,
    );
    expect(canonical.light["--focus-border"]).toBe(
      `${fromTheme(/focusedBorder:[\s\S]*?width: ([\d.]+)/)}px`,
    );
  });

  test("the shell uses the canonical token values", () => {
    // A token the shell does not declare cannot contradict the canonical
    // value, so the old shape of this test skipped those. That made omission
    // invisible: `--control-height` is absent from the shell, which uses its
    // own 34px control, and the suite stayed green. Every canonical token
    // must now be either consumed or explicitly exempted below, so a new
    // token cannot slip in unclassified.
    for (const [token, value] of Object.entries(canonical.light)) {
      if (!(token in shell.light)) continue;
      expect(shell.light[token], `shell ${token}`).toBe(value);
    }
    for (const [token, value] of Object.entries(canonical.dark)) {
      if (!(token in shell.dark)) continue;
      expect(shell.dark[token], `shell dark ${token}`).toBe(value);
    }
  });

  test("every canonical token is consumed by the shell or exempt", () => {
    const unclassified = [
      ...Object.keys(canonical.light),
      ...Object.keys(canonical.dark),
    ].filter(
      (token) =>
        !(token in shell.light) && !(token in shell.dark) && !(token in EXEMPT),
    );
    expect(
      unclassified.sort(),
      "add these to SHELL_EXEMPT with a reason, or consume them",
    ).toEqual([]);
  });

  test("the exemption list has no dead entries", () => {
    // An exemption for a token the shell now consumes is a stale excuse that
    // would hide the next real decision.
    for (const [token, reason] of Object.entries(EXEMPT)) {
      const consumed = token in shell.light || token in shell.dark;
      expect(consumed, `${token} is exempt but the shell declares it`).toBe(false);
      expect(
        token in canonical.light || token in canonical.dark,
        `${token} is exempt but not a canonical token`,
      ).toBe(true);
      expect(reason.trim().length, `${token} needs a reason`).toBeGreaterThan(0);
    }
  });

  test("the bundled boot page CSP matches the shell CSP plus the relay poll", () => {
    // The boot page and the Relay-served shell have two CSP strings in the
    // project, and they are allowed to differ in exactly one directive. This
    // is what stops that difference becoming a second, accidental one.
    const tauriConf = JSON.parse(read("src-tauri/tauri.conf.json")) as {
      app: { security: { csp: string } };
    };
    const bundled = tauriConf.app.security.csp;

    expect(bundled).toBe(bundledPageCsp("http://127.0.0.1:*"));

    const declarations = (csp: string) =>
      new Map(
        csp.split("; ").map((directive) => {
          const [name, ...values] = directive.split(" ");
          return [name!, values.join(" ")] as const;
        }),
      );
    const shellDirectives = declarations(SHELL_CSP);
    const bundledDirectives = declarations(bundled);

    expect([...bundledDirectives.keys()].sort()).toEqual(
      [...shellDirectives.keys()].sort(),
    );

    // Exactly one directive may differ, and it must be connect-src: the boot
    // page polls the Relay over loopback before the shell takes over.
    const differing = [...shellDirectives]
      .filter(([name, value]) => bundledDirectives.get(name) !== value)
      .map(([name]) => name);
    expect(differing).toEqual(["connect-src"]);
    expect(bundledDirectives.get("connect-src")).toBe(
      "'self' http://127.0.0.1:*",
    );
  });

  test("every custom property the shell uses is declared", () => {
    const declared = new Set([
      ...Object.keys(shell.light),
      ...Object.keys(shell.dark),
    ]);
    const referenced = new Set(
      [...shellCss.matchAll(/var\((--[a-z0-9-]+)\)/g)].map((match) => match[1]!),
    );
    expect(referenced.size).toBeGreaterThan(10);
    for (const name of referenced) {
      expect(declared.has(name), `shell uses ${name}`).toBe(true);
    }
  });
});

describe("design skill token files", () => {
  const files = ["colors.css", "typography.css", "spacing.css", "motion.css"];

  test("each imports the canonical tokens", () => {
    for (const file of files) {
      const css = read(`.claude/skills/vidyut-design/tokens/${file}`);
      expect(css, `${file} imports design/tokens.css`).toContain(
        '@import url("../../../../design/tokens.css")',
      );
    }
  });

  test("none of them restate a canonical token value", () => {
    const canonicalNames = new Set([
      ...Object.keys(canonical.light),
      ...Object.keys(canonical.dark),
    ]);
    for (const file of files) {
      const css = read(`.claude/skills/vidyut-design/tokens/${file}`);
      // Only declarations outside :root are exempt, and there are none of
      // consequence; every --x: value must either be a var() alias or a token
      // the canonical file does not define.
      for (const match of css.matchAll(/(--[a-z0-9-]+)\s*:\s*([^;]+);/g)) {
        const [, name, value] = match;
        if (!canonicalNames.has(name!)) continue;
        expect(
          value!.trim().startsWith("var("),
          `${file} restates ${name}; alias it or edit the Dart`,
        ).toBe(true);
      }
    }
  });

  test("no skill file claims a retired typeface or geometry", () => {
    const skill = ".claude/skills/vidyut-design";
    const paths = [
      ...files.map((file) => `${skill}/tokens/${file}`),
      `${skill}/tokens/fonts.css`,
      `${skill}/readme.md`,
    ];
    for (const path of paths) {
      const text = read(path);
      expect(text, `${path} has no Plus Jakarta Sans`).not.toContain(
        "Plus Jakarta Sans",
      );
      expect(text, `${path} has no 54px button`).not.toContain("54px");
      expect(text, `${path} has no 20px card radius`).not.toMatch(/20px\s*;/);
    }
  });
});

describe("desktop shell self-sufficiency", () => {
  test("no remote font, stylesheet, or script is requested", () => {
    const remote = [
      /\bhref="((?:https?:)?\/\/[^"]*)"/g,
      /\bsrc="((?:https?:)?\/\/[^"]*)"/g,
    ];
    for (const pattern of remote) {
      for (const match of shellHtml.matchAll(pattern)) {
        // The only outbound reference allowed is the GitHub Releases anchor.
        expect(match[1]).toBe("https://github.com/Snehit70/vidyut/releases");
      }
    }
    expect(shellHtml).not.toMatch(/<link\b/);
    expect(shellHtml).not.toContain("fonts.googleapis.com");
    expect(shellHtml).not.toContain("fonts.gstatic.com");
  });

  test("Manrope is the only product typeface (ADR 0011)", () => {
    expect(shellCss).toContain('font-family: "Manrope"');
    expect(shellHtml).not.toContain("Plus Jakarta Sans");
    expect(shellHtml).not.toContain("Manrope\"; src: url(https");
  });

  test("Manrope is served by the Relay, not a CDN", () => {
    expect(shellCss).toContain('url("/ui/manrope.ttf")');
  });

  test("the shell has no staggered entrance and honors reduced motion", () => {
    // ADR 0013: long scrollable surfaces render immediately.
    expect(shellCss).not.toContain("animation-delay");
    expect(shellHtml).not.toMatch(/animation-delay:/);
    expect(shellCss).toContain("@media (prefers-reduced-motion: reduce)");
  });

  test("the shell follows the system colour scheme", () => {
    expect(shellHtml).toContain('<meta name="color-scheme" content="light dark"/>');
    expect(shellCss).toContain("@media (prefers-color-scheme: dark)");
    expect(shellCss).not.toContain("color-scheme: only light");
    expect(shellCss).not.toContain("color-scheme: light only");
  });
});

describe("desktop shell behaviour guards", () => {
  test("hidden elements are actually hidden", () => {
    // An author `display` rule outranks the user agent [hidden] rule, so a
    // hidden banner stayed on screen. This is the guard for that class of bug.
    expect(shellCss).toContain("[hidden] { display: none !important; }");
  });

  test("the hidden-toggled elements are exactly the ones that declare display", () => {
    // The trap: an element that both sets `display` in author CSS and is
    // toggled with the hidden attribute stays visible, because the author rule
    // outranks the user agent rule. These are the elements at risk, so the
    // global [hidden] override has to stay.
    const displayRules = new Set(
      [...shellCss.matchAll(/^\.([\w-]+)\s*\{[^}]*display:\s*flex/gm)].map(
        (match) => match[1]!,
      ),
    );
    expect(displayRules.size).toBeGreaterThan(0);
    for (const selector of ["banner", "summary"]) {
      expect(displayRules.has(selector), `.${selector} declares display:flex`).toBe(true);
    }
    // Both of those classes sit on elements the script toggles with .hidden.
    for (const id of ["banner", "file-summary", "setup-summary"]) {
      expect(shellHtml).toContain(`id="${id}"`);
      expect(shellHtml, `${id} is hidden-toggled`).toMatch(
        new RegExp(`(hidden[^>]*id="${id}"|id="${id}"[^>]*hidden)`),
      );
    }
    // The override must be a top-level rule, not nested inside a block or a
    // media query, or it will not apply where it is needed.
    const override = "[hidden] { display: none !important; }";
    const at = shellCss.indexOf(override);
    expect(at).toBeGreaterThan(-1);
    expect(shellCss.split(override).length - 1).toBe(1);
    const before = shellCss.slice(0, at);
    const opens = (before.match(/\{/g) ?? []).length;
    const closes = (before.match(/\}/g) ?? []).length;
    expect(opens - closes, "the [hidden] rule is not nested").toBe(0);
  });

  test("the QR is not the default pane once a device is paired", () => {
    expect(shellHtml).toContain("function defaultPane()");
    expect(shellHtml).toContain('return Number(state.authenticatedDeviceCount || 0) > 0 ? "files" : "pairing";');
    // And the QR says what it is for when it is not the front door.
    expect(shellHtml).toContain("Already paired. Scan again to add another phone.");
  });

  test("transfer failures are shown as sentences, not identifiers", () => {
    expect(shellHtml).toContain("function failureText(code)");
    expect(shellHtml).toContain("The other device ran out of space.");
    expect(shellHtml).toContain("This device is no longer paired.");
    // The raw identifier must not be what reaches the row.
    expect(shellHtml).not.toContain("escapeHtml(failed.errorCode)");
  });

  test("stop relay is visually distinct from start relay", () => {
    expect(shellHtml).toContain('id="stop-relay" disabled');
    expect(shellHtml).toMatch(/class="btn outlined danger" id="stop-relay"/);
    expect(shellCss).toContain(".btn.danger");
    expect(shellHtml).not.toMatch(/class="btn outlined danger" id="start-relay"/);
  });

  test("wide windows centre the content instead of hugging the left edge", () => {
    expect(shellCss).toContain("max-width: 880px; margin-inline: auto;");
  });

  test("an unrecognised sync state is not reported as Ready", () => {
    // Ready means a live connection and a healthy watcher, so a state this
    // window does not know must not resolve to it. This evaluates the real
    // injected function rather than asserting on its source text.
    const statusLiteral = shellHtml.match(/var STATUS = (\{.*?\});/)?.[1];
    const fnSource = shellHtml.match(
      /function statusCopyFor\(syncState\) \{[\s\S]*?\n  \}/,
    )?.[0];
    expect(statusLiteral).toBeDefined();
    expect(fnSource).toBeDefined();

    const status = JSON.parse(statusLiteral!) as Record<string, { label: string }>;
    const statusCopyFor = new Function(
      "STATUS",
      `${fnSource}\nreturn statusCopyFor;`,
    )(status) as (state: string) => { label: string; tone: string };

    expect(statusCopyFor("ready").label).toBe("Ready");
    expect(statusCopyFor("sync_needs_attention").label).toBe("Sync needs attention");
    expect(statusCopyFor("relay_down").label).toBe("Relay down");

    for (const unknown of ["degraded", "paused", "", "toString", "__proto__", "READY"]) {
      const copy = statusCopyFor(unknown);
      expect(copy.label, `unknown state ${JSON.stringify(unknown)}`).not.toBe("Ready");
    }
  });
});
