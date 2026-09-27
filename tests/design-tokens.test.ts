import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

import { desktopShellHtml } from "../src/relay/desktop-shell-page";

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
    for (const [token, value] of Object.entries(canonical.light)) {
      const declared = shell.light[token];
      if (declared === undefined) continue;
      expect(declared, `shell ${token}`).toBe(value);
    }
    for (const [token, value] of Object.entries(canonical.dark)) {
      const declared = shell.dark[token];
      if (declared === undefined) continue;
      expect(declared, `shell dark ${token}`).toBe(value);
    }
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
});
