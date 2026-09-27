import { SHELL_ICON_PATHS, type ShellIconName } from "./shell-assets";

export interface DesktopShellState {
  relayName: string;
  host: string;
  port: number;
  pairingSecret: string;
  manual: string;
  syncState: "ready" | "sync_needs_attention" | "relay_down";
  authenticatedDeviceCount: number;
}

interface StatusCopy {
  label: string;
  detail: string;
  icon: ShellIconName;
  tone: "good" | "warn" | "bad";
}

const STATUS_COPY: Record<DesktopShellState["syncState"], StatusCopy> = {
  ready: {
    label: "Ready",
    detail: "Automatic clipboard sync is ready between your devices.",
    icon: "sync",
    tone: "good",
  },
  sync_needs_attention: {
    label: "Sync needs attention",
    detail: "Connected, but automatic clipboard sync needs recovery.",
    icon: "syncProblem",
    tone: "warn",
  },
  relay_down: {
    label: "Relay down",
    detail:
      "The Relay is not answering. Clipboard and transfers pause until it is running.",
    icon: "cloudOff",
    tone: "bad",
  },
};

/** Sidebar order is also the Ctrl+1..4 order. */
const PANES = [
  { id: "pairing", label: "Pairing", icon: "qrCode" },
  { id: "files", label: "Files", icon: "folderOpen" },
  { id: "setup", label: "Setup", icon: "tune" },
  { id: "relay", label: "Relay", icon: "dns" },
] as const satisfies readonly {
  id: string;
  label: string;
  icon: ShellIconName;
}[];

export function desktopShellHtml(state: DesktopShellState): string {
  const status = STATUS_COPY[state.syncState];
  const endpoint = `${state.host}:${state.port}`;
  const banner = status.tone === "good";
  return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8"/>
  <meta name="viewport" content="width=device-width, initial-scale=1"/>
  <meta name="color-scheme" content="light dark"/>
  <title>Vidyut</title>
  <style>${SHELL_CSS}</style>
</head>
<body data-sync="${escapeHtml(state.syncState)}" data-pane="pairing">
  ${iconSprite()}
  <div class="app">
    <header class="titlebar">
      <div class="titlebar-id">
        <h1>Vidyut</h1>
        <span class="sep" aria-hidden="true">/</span>
        <span class="relay-name" id="relay-name">${escapeHtml(state.relayName)}</span>
      </div>
      <div class="titlebar-end">
        <p class="status" id="status-chip" role="status" aria-live="polite">
          <span class="status-dot" aria-hidden="true"></span>
          <span id="status-label">${escapeHtml(status.label)}</span>
        </p>
        <button
          type="button"
          class="quit"
          id="quit-shell"
          title="Close the desktop shell. The Relay keeps running, so clipboard sync and transfers are unaffected."
        >Quit</button>
      </div>
    </header>

    <div class="banner" id="banner" role="status" aria-live="polite"${banner ? " hidden" : ""}>
      <svg class="icon" viewBox="0 0 24 24" focusable="false" aria-hidden="true"><use href="#i-${status.icon}" id="status-icon"/></svg>
      <p id="status-detail">${escapeHtml(status.detail)}</p>
    </div>

    <div class="body">
      <nav class="sidebar" aria-label="Sections">
        <div class="nav" role="tablist" aria-orientation="vertical" id="nav">
          ${PANES.map(
            (pane, index) => `<button
            type="button"
            class="nav-item"
            role="tab"
            id="tab-${pane.id}"
            data-pane="${pane.id}"
            aria-controls="pane-${pane.id}"
            aria-selected="${pane.id === "pairing"}"
            tabindex="${pane.id === "pairing" ? 0 : -1}">
            <svg class="icon" viewBox="0 0 24 24" focusable="false" aria-hidden="true"><use href="#i-${pane.icon}"/></svg>
            <span>${pane.label}</span>
            <kbd aria-hidden="true">${index + 1}</kbd>
          </button>`,
          ).join("")}
        </div>
        <div class="sidebar-foot">
          <button type="button" class="btn filled" id="send-files">
            <svg class="icon" viewBox="0 0 24 24" focusable="false" aria-hidden="true"><use href="#i-folderOpen"/></svg>
            Send files
          </button>
        </div>
      </nav>

      <main class="pane" id="pane-pairing" role="tabpanel" aria-labelledby="tab-pairing" tabindex="0">
        <div class="pane-head">
          <h2>Pairing</h2>
          <p id="pairing-hint">Point the phone at this QR. The Relay is reachable only on this WiFi network.</p>
        </div>
        <div class="pairing-grid">
          <div class="qr-frame">
            <img class="qr" id="qr" alt="Pairing QR" src="/control/v1/qr.svg" width="168" height="168"/>
          </div>
          <dl class="facts">
            <div><dt>Address</dt><dd id="endpoint">${escapeHtml(endpoint)}</dd></div>
            <div><dt>Relay</dt><dd id="relay-name-2">${escapeHtml(state.relayName)}</dd></div>
            <div><dt>Paired</dt><dd><span id="devices">${escapeHtml(String(state.authenticatedDeviceCount))}</span> <span id="devices-label">${deviceWord(state.authenticatedDeviceCount)}</span></dd></div>
          </dl>
        </div>
        <div class="row-actions">
          <button type="button" class="btn outlined" id="copy-manual">Copy pairing line</button>
        </div>

        <section class="block">
          <div class="block-head">
            <h3>Rotate pairing secret</h3>
            <button type="button" class="btn outlined" id="rotate-open" aria-expanded="false" aria-controls="rotate-confirm">Rotate</button>
          </div>
          <p>Replaces the one secret every device shares. There is no per-phone list.</p>
          <div id="rotate-confirm" class="confirm" role="group" aria-labelledby="rotate-confirm-label" hidden>
            <p id="rotate-confirm-label">Every phone must scan the new QR. Clipboard and transfers pause until they pair again.</p>
            <div class="btn-row">
              <button type="button" class="btn outlined" id="rotate-cancel">Cancel</button>
              <button type="button" class="btn filled" id="rotate-go">Rotate pairing secret</button>
            </div>
          </div>
        </section>
      </main>

      <main class="pane" id="pane-files" role="tabpanel" aria-labelledby="tab-files" tabindex="0" hidden>
        <div class="pane-head">
          <h2>Files</h2>
          <p>Files move between your paired devices. History is metadata only; completed files stay where they landed.</p>
        </div>
        <div class="summary" id="file-summary" hidden></div>
        <p class="stale" id="transfers-stale" hidden></p>
        <section class="block">
          <h3>Transfer history</h3>
          <ul class="rows" id="transfers">
            <li class="empty">No transfers yet.</li>
          </ul>
        </section>
      </main>

      <main class="pane" id="pane-setup" role="tabpanel" aria-labelledby="tab-setup" tabindex="0" hidden>
        <div class="pane-head">
          <h2>Setup</h2>
          <p>Conditions on this laptop that can degrade the Relay.</p>
        </div>
        <div class="summary" id="setup-summary" hidden></div>
        <p class="stale" id="setup-stale" hidden></p>
        <section class="block">
          <div class="block-head">
            <h3>Laptop setup status</h3>
            <button type="button" class="btn outlined" id="setup-recheck">Check again</button>
          </div>
          <p class="checked" id="setup-checked"></p>
          <ul class="rows" id="setup">
            <li class="empty">Checking laptop setup status.</li>
          </ul>
        </section>
      </main>

      <main class="pane" id="pane-relay" role="tabpanel" aria-labelledby="tab-relay" tabindex="0" hidden>
        <div class="pane-head">
          <h2>Relay</h2>
          <p>The Relay is a background service. This window is only its control panel.</p>
        </div>
        <section class="block">
          <h3>Service</h3>
          <dl class="facts">
            <div><dt>Address</dt><dd id="endpoint-2">${escapeHtml(endpoint)}</dd></div>
            <div><dt>Unit</dt><dd>vidyut-relay.service</dd></div>
            <div><dt>Paired</dt><dd><span id="devices-2">${escapeHtml(String(state.authenticatedDeviceCount))}</span> <span id="devices-label-2">${deviceWord(state.authenticatedDeviceCount)}</span></dd></div>
          </dl>
          <div class="btn-row" data-explains="relay">
            <button type="button" class="btn outlined" id="start-relay" disabled>Start relay</button>
            <button type="button" class="btn outlined danger" id="stop-relay" disabled>Stop relay</button>
          </div>
          <p class="note">Closing this window does not stop the Relay. Stop relay is the only thing that does.</p>
        </section>
        <section class="block">
          <h3>Updates</h3>
          <p>Vidyut updates through your package manager. This window never downloads or replaces binaries.</p>
          <div class="row-actions">
            <a class="btn outlined" id="open-releases" href="https://github.com/Snehit70/vidyut/releases">Open releases</a>
          </div>
          <p class="note">Install a newer .rpm or .deb with dnf or apt.</p>
        </section>
      </main>
    </div>
  </div>
  <div id="snack" class="snack" role="status" aria-live="polite" hidden></div>
  <script type="application/json" id="boot">${embedJson(state)}</script>
  <script>${shellScript()}</script>
</body>
</html>
`;
}

function deviceWord(count: number): string {
  return count === 1 ? "device" : "devices";
}

function iconSprite(): string {
  const symbols = Object.entries(SHELL_ICON_PATHS)
    .map(
      ([name, path]) =>
        `<symbol id="i-${name}" viewBox="0 0 24 24"><path d="${path}"/></symbol>`,
    )
    .join("");
  return `<svg class="sprite" aria-hidden="true" focusable="false" xmlns="http://www.w3.org/2000/svg">${symbols}</svg>`;
}

function escapeHtml(value: string): string {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

function embedJson(value: unknown): string {
  return JSON.stringify(value)
    .replaceAll("<", "\\u003c")
    .replaceAll(">", "\\u003e")
    .replaceAll("&", "\\u0026");
}

/**
 * Colour, type, and shape tokens mirror design/tokens.css, which mirrors
 * app/lib/src/design/{palette,theme}.dart. tests/design-tokens.test.ts fails if
 * the three drift apart.
 *
 * The metrics below the token block are desktop-specific and deliberately not
 * tokens: the phone's 48px control height is a touch target, and a mouse-driven
 * window wants a denser row. Nothing here changes a shared value.
 */
const SHELL_CSS = `
@font-face {
  font-family: "Manrope";
  font-style: normal;
  font-weight: 200 800;
  font-display: swap;
  src: url("/ui/manrope.ttf") format("truetype");
}
:root {
  --ground: #FFFFFF;
  --mist: #FDF0F4;
  --petal: #F8D3DE;
  --raspberry: #C83861;
  --ink: #33202B;
  --muted: #856774;
  --hairline: #9D878F;
  --error: #B3283E;
  --success: #2D8A4A;
  --success-mist: #EDF8F0;
  --warning: #A05A00;
  --warning-mist: #FFF7E8;

  --surface-page: var(--ground);
  --surface-card: var(--mist);
  --surface-emphasis: var(--petal);
  --surface-secondary: var(--mist);
  --surface-snack: var(--ink);

  --text-body: var(--ink);
  --text-muted: var(--muted);
  --text-error: var(--error);
  --text-on-primary: #FFFFFF;
  --text-on-emphasis: var(--ink);
  --text-on-snack: #FFFFFF;

  --border-hairline: var(--hairline);
  --border-focus: var(--raspberry);
  --hairline-soft: color-mix(in srgb, var(--hairline) 40%, transparent);

  --font-sans: "Manrope", system-ui, sans-serif;

  --type-title-lg-size: 18px;
  --type-title-lg-weight: 700;
  --type-title-md-size: 16px;
  --type-title-md-weight: 700;
  --type-title-sm-size: 14px;
  --type-title-sm-weight: 700;
  --type-body-md-size: 14px;
  --type-label-lg-size: 14px;
  --type-label-lg-weight: 600;
  --type-label-sm-size: 11px;
  --type-label-sm-weight: 600;
  --type-line-height: 1.35;

  --radius-card: 16px;
  --radius-control: 12px;
  --radius-tile: 8px;
  --focus-border: 1.5px;
  --ease-out-cubic: cubic-bezier(0.33, 1, 0.68, 1);
  --dur-press-down: 100ms;
  --dur-press-up: 150ms;
  --press-scale: 0.96;

  /* Desktop metrics. */
  --bar-height: 44px;
  --sidebar-width: 212px;
  --control-height-compact: 34px;
  --row-height: 40px;
  --pane-pad: 20px;
  --gap: 12px;
}
@media (prefers-color-scheme: dark) {
  :root {
    --ground: #171116;
    --mist: #241A20;
    --petal: #8F2949;
    --raspberry: #FFB1C3;
    --ink: #F8EAF0;
    --muted: #D4B8C4;
    --hairline: #805F6C;
    --error: #FFB3BD;
    --success: #8DDB9F;
    --success-mist: #241A20;
    --warning: #FFB870;
    --warning-mist: #241A20;

    --surface-snack: var(--mist);
    --text-on-primary: var(--ground);
    --text-on-snack: var(--ink);
  }
}
* { box-sizing: border-box; }
/* An author display rule outranks the user agent [hidden] rule, so anything
   toggled with the hidden attribute needs this to actually disappear. */
[hidden] { display: none !important; }
html, body { height: 100%; }
body {
  margin: 0;
  background: var(--surface-page);
  color: var(--text-body);
  font-family: var(--font-sans);
  font-size: var(--type-label-lg-size);
  font-weight: 500;
  line-height: var(--type-line-height);
  -webkit-font-smoothing: antialiased;
  overflow: hidden;
}
.sprite { position: absolute; width: 0; height: 0; overflow: hidden; }
.icon {
  width: 1em;
  height: 1em;
  display: block;
  fill: currentColor;
  flex: none;
}
.app { height: 100vh; display: flex; flex-direction: column; }

/* Title bar: identity left, live state right. Flat, hairline-ruled, no shadow. */
.titlebar {
  height: var(--bar-height);
  flex: none;
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: var(--gap);
  padding: 0 var(--pane-pad);
  border-bottom: 1px solid var(--hairline-soft);
}
.titlebar-id { display: flex; align-items: baseline; gap: 8px; min-width: 0; }
.titlebar-end { display: flex; align-items: center; gap: 12px; flex: none; }
/* Named Quit, not Stop, and it sits in the title bar rather than beside the
   relay controls: stopping the Relay and closing the shell are different
   actions and must not read alike. */
.quit {
  font: inherit;
  font-size: var(--type-label-lg-size);
  font-weight: var(--type-label-lg-weight);
  color: var(--text-muted);
  background: none;
  border: 1px solid var(--hairline);
  border-radius: var(--radius-control);
  padding: 3px 10px;
  cursor: pointer;
}
.quit:hover { color: var(--text-body); border-color: var(--muted); }
.quit:focus-visible { outline: 2px solid var(--focus-border); outline-offset: 2px; }
h1 {
  margin: 0;
  font-size: var(--type-title-md-size);
  font-weight: var(--type-title-md-weight);
  letter-spacing: -0.2px;
}
.sep { color: var(--text-muted); }
.relay-name {
  color: var(--text-muted);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.status {
  margin: 0;
  display: flex;
  align-items: center;
  gap: 8px;
  flex: none;
  font-weight: var(--type-label-lg-weight);
}
.status-dot {
  width: 8px;
  height: 8px;
  border-radius: 999px;
  background: var(--muted);
  flex: none;
}
body[data-sync="ready"] .status-dot { background: var(--success); }
body[data-sync="sync_needs_attention"] .status-dot { background: var(--warning); }
body[data-sync="relay_down"] .status-dot { background: var(--error); }
body[data-sync="relay_down"] .status { color: var(--text-error); }

/* Only when the state is not healthy. Ready stays quiet in the title bar. */
.banner {
  flex: none;
  display: flex;
  align-items: center;
  gap: 10px;
  padding: 10px var(--pane-pad);
  background: var(--warning-mist);
  color: var(--text-body);
  border-bottom: 1px solid var(--hairline-soft);
  font-size: var(--type-label-lg-size);
}
.banner .icon { color: var(--warning); font-size: 20px; }
.banner p { margin: 0; }
body[data-sync="relay_down"] .banner { background: var(--surface-card); }
body[data-sync="relay_down"] .banner .icon { color: var(--error); }

.body { flex: 1; display: flex; min-height: 0; }

/* Sidebar */
.sidebar {
  width: var(--sidebar-width);
  flex: none;
  display: flex;
  flex-direction: column;
  justify-content: space-between;
  gap: var(--gap);
  padding: var(--gap) 10px;
  border-right: 1px solid var(--hairline-soft);
}
.nav { display: flex; flex-direction: column; gap: 2px; }
.nav-item {
  display: flex;
  align-items: center;
  gap: 10px;
  height: var(--row-height);
  padding: 0 10px;
  border: none;
  border-radius: var(--radius-tile);
  background: none;
  color: var(--text-body);
  font: inherit;
  font-weight: 500;
  text-align: left;
  cursor: pointer;
  transition: background-color var(--dur-press-up) var(--ease-out-cubic);
}
.nav-item .icon { font-size: 18px; color: var(--muted); }
.nav-item span { flex: 1; }
.nav-item:hover { background: var(--surface-card); }
.nav-item[aria-selected="true"] {
  background: var(--surface-emphasis);
  color: var(--raspberry);
  font-weight: var(--type-label-lg-weight);
}
.nav-item[aria-selected="true"] .icon { color: var(--raspberry); }
kbd {
  font-family: inherit;
  font-size: var(--type-label-sm-size);
  color: var(--text-muted);
  background: none;
}
.sidebar-foot { padding-top: var(--gap); border-top: 1px solid var(--hairline-soft); }

/* Content pane: one section at a time, scrolls internally. */
.pane {
  flex: 1;
  min-width: 0;
  overflow-y: auto;
  padding: var(--pane-pad);
}
/* Cap the measure so a wide window does not stretch rows to the far edge, and
   centre it so the leftover space is balanced rather than all on one side. */
.pane > * { max-width: 880px; margin-inline: auto; }
.pane:focus-visible { outline: var(--focus-border) solid var(--border-focus); outline-offset: -2px; }
.pane-head { margin-bottom: var(--pane-pad); }
h2 {
  margin: 0 0 4px;
  font-size: var(--type-title-lg-size);
  font-weight: var(--type-title-lg-weight);
  letter-spacing: -0.3px;
}
h3 {
  margin: 0 0 var(--gap);
  font-size: var(--type-label-lg-size);
  font-weight: var(--type-label-lg-weight);
}
p { margin: 0; }
.pane-head p, .block > p, .note { color: var(--text-muted); }
.note { font-size: var(--type-label-sm-size); margin-top: 8px; }

.pairing-grid {
  display: grid;
  grid-template-columns: auto minmax(0, 1fr);
  gap: var(--pane-pad);
  align-items: start;
}
.qr-frame {
  padding: 10px;
  background: var(--ground);
  border: 1px solid var(--hairline-soft);
  border-radius: var(--radius-control);
}
.qr { display: block; width: 168px; height: 168px; }

.facts { margin: 0; display: flex; flex-direction: column; gap: 10px; }
.facts > div { display: grid; grid-template-columns: 76px minmax(0, 1fr); gap: var(--gap); align-items: baseline; }
dt { color: var(--text-muted); font-size: var(--type-label-sm-size); font-weight: var(--type-label-lg-weight); text-transform: uppercase; letter-spacing: 0.4px; }
dd { margin: 0; overflow-wrap: anywhere; user-select: all; }

.row-actions { display: flex; gap: 10px; margin-top: var(--pane-pad); }
.block { margin-top: 24px; padding-top: var(--pane-pad); border-top: 1px solid var(--hairline-soft); }
.block:first-of-type { margin-top: 0; }
.block-head { display: flex; align-items: center; justify-content: space-between; gap: var(--gap); margin-bottom: 6px; }
.block-head h3 { margin: 0; }

.btn {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  gap: 8px;
  min-height: var(--control-height-compact);
  padding: 0 14px;
  border: 1px solid transparent;
  border-radius: var(--radius-control);
  font: inherit;
  font-weight: var(--type-label-lg-weight);
  line-height: 1.2;
  text-decoration: none;
  white-space: nowrap;
  cursor: pointer;
  transition: transform var(--dur-press-down) var(--ease-out-cubic);
}
.btn:active:not(:disabled) { transform: scale(var(--press-scale)); }
.btn.filled { width: 100%; background: var(--raspberry); color: var(--text-on-primary); }
.btn.outlined {
  background: var(--surface-page);
  color: var(--raspberry);
  border-color: var(--hairline);
}
.btn.danger {
  color: var(--text-error);
  border-color: var(--error);
}
.btn.danger:hover { background: color-mix(in srgb, var(--error) 8%, var(--surface-page)); }
.sidebar-foot .btn { width: 100%; }
.btn:disabled { opacity: 0.45; cursor: default; }
.btn:focus-visible, a:focus-visible, .nav-item:focus-visible {
  outline: var(--focus-border) solid var(--border-focus);
  outline-offset: 2px;
}
.btn-row { display: flex; gap: 10px; margin-top: var(--pane-pad); }
.btn-row .btn { flex: 1; }

.confirm {
  margin-top: var(--gap);
  padding: var(--gap);
  background: var(--surface-emphasis);
  border-radius: var(--radius-control);
  color: var(--text-on-emphasis);
}
.confirm p { margin-bottom: 10px; }
.confirm .btn-row { margin-top: 0; }

.summary {
  display: flex;
  gap: var(--pane-pad);
  padding: 10px 14px;
  margin-bottom: var(--pane-pad);
  background: var(--surface-card);
  border-radius: var(--radius-control);
}
.summary div { display: flex; flex-direction: column; }
.summary b { font-size: var(--type-title-md-size); font-weight: var(--type-title-md-weight); }
.summary span { color: var(--text-muted); font-size: var(--type-label-sm-size); font-weight: var(--type-label-lg-weight); }
.summary .bad b { color: var(--text-error); }

.rows { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 2px; }
.rows li {
  display: flex;
  align-items: flex-start;
  gap: 10px;
  min-height: var(--row-height);
  padding: 8px 10px;
  border-radius: var(--radius-tile);
}
.rows li:not(.empty):hover { background: var(--surface-card); }
.rows .icon { width: 18px; height: 18px; margin-top: 2px; color: var(--muted); }
.rows .icon.good { color: var(--success); }
.rows .icon.warn { color: var(--warning); }
.rows .icon.bad { color: var(--error); }
.rows .grow { flex: 1; min-width: 0; }
.row-title { font-size: var(--type-label-lg-size); font-weight: var(--type-label-lg-weight); }
.row-detail { color: var(--text-muted); font-size: var(--type-label-sm-size); }
.row-fix { color: var(--text-error); font-size: var(--type-label-sm-size); margin-top: 2px; }
.rows .trailing { color: var(--text-muted); font-size: var(--type-label-sm-size); white-space: nowrap; margin-top: 2px; }
.empty { color: var(--text-muted); }
.stale {
  margin: 0 0 var(--gap);
  padding: 8px 12px;
  background: var(--surface-card);
  border-left: 2px solid var(--warning);
  border-radius: var(--radius-tile);
  color: var(--text-muted);
  font-size: var(--type-label-sm-size);
}
body[data-stale="true"] .rows { opacity: 0.55; }
.checked { margin: -6px 0 var(--gap); color: var(--text-muted); font-size: var(--type-label-sm-size); }
.group-label {
  margin: 16px 0 6px;
  font-size: var(--type-label-sm-size);
  font-weight: var(--type-label-lg-weight);
  text-transform: uppercase;
  letter-spacing: 0.4px;
  color: var(--text-muted);
}

.snack {
  position: fixed;
  left: 50%;
  bottom: 20px;
  transform: translateX(-50%);
  max-width: calc(100% - 40px);
  padding: 10px 16px;
  background: var(--surface-snack);
  color: var(--text-on-snack);
  border-radius: var(--radius-control);
  box-shadow: 0 6px 20px rgb(0 0 0 / 18%);
}

/* Narrow window: the sidebar becomes a tab strip. The window is resizable, so
   this is a real layout, not a phone breakpoint. */
@media (max-width: 680px) {
  .body { flex-direction: column; }
  .sidebar {
    width: auto;
    flex-direction: row;
    align-items: center;
    gap: 10px;
    padding: 8px 10px;
    border-right: none;
    border-bottom: 1px solid var(--hairline-soft);
  }
  .nav { flex-direction: row; flex: 1; overflow-x: auto; }
  .nav-item kbd { display: none; }
  .sidebar-foot { padding-top: 0; border-top: none; }
  .sidebar-foot .btn { width: auto; }
  .pairing-grid { grid-template-columns: minmax(0, 1fr); }
  .qr-frame { justify-self: start; }
}

/* ADR 0013: this window has no entrance choreography. Motion is limited to
   press and state feedback, and stands down when reduced motion is requested. */
@media (prefers-reduced-motion: reduce) {
  .btn, .nav-item { transition: none; }
  .btn:active:not(:disabled) { transform: none; }
}
`;

function shellScript(): string {
  return `
(function () {
  var POLL_MS = 4000;
  var SETUP_TITLES = {
    relay_running: "Relay running",
    wayland: "Wayland",
    wl_clipboard: "wl-clipboard",
    imagemagick: "ImageMagick",
    autostart: "Autostart",
    firewall: "Firewall"
  };
  var STATUS = ${JSON.stringify(STATUS_COPY)};
  var PANES = ${JSON.stringify(PANES.map((pane) => pane.id))};
  var ATTENTION = ["failed", "completed_with_issues", "waiting_for_source", "expired"];
  // Error codes are internal identifiers. The vocabulary is fixed by
  // src/transfer, so map it once instead of leaking snake_case at the user.
  var FAILURES = {
    body_digest_mismatch: "The file changed while it was moving.",
    hash_mismatch: "The file changed while it was moving.",
    source_changed: "The file changed after you picked it.",
    source_short_read: "The file ended sooner than expected.",
    chunk_auth_failed: "This device is no longer paired.",
    transfer_auth_failed: "This device is no longer paired.",
    chunk_too_large: "The file is too large to send.",
    file_too_large: "The file is too large to send.",
    destination_short_write: "The other device ran out of space.",
    insufficient_storage: "The other device ran out of space.",
    finalization_interrupted: "Saving the file was interrupted.",
    verification_interrupted: "Checking the file was interrupted.",
    invalid_chunk: "The transfer got out of step and was stopped.",
    invalid_offset: "The transfer got out of step and was stopped.",
    offset_not_confirmed: "The transfer got out of step and was stopped.",
    partial_state_missing: "The transfer's saved state was incomplete.",
    checkpoint_failed: "The transfer lost its place and could not resume.",
    peer_disconnected: "The other device went away mid-transfer.",
    terminal_processing_failed: "The transfer failed.",
    transfer_failed: "The transfer failed.",
    transfer_expired: "The resumable window passed."
  };

  function failureText(code) {
    if (!code) return "";
    if (FAILURES[code]) return FAILURES[code];
    return String(code).replace(/_/g, " ").replace(/^./, function (ch) {
      return ch.toUpperCase();
    }) + ".";
  }
  var snackTimer;
  var lastSecret = "";
  var state = {};
  var missed = 0;
  var lastGoodAt = 0;
  var lastSetupRows = null;
  var MISSES_BEFORE_DOWN = 2;

  function $(id) { return document.getElementById(id); }

  function bootState() {
    var node = $("boot");
    try { return JSON.parse(node.textContent || "{}"); }
    catch (err) { return {}; }
  }

  function snack(text) {
    var el = $("snack");
    el.textContent = text;
    el.hidden = false;
    clearTimeout(snackTimer);
    snackTimer = setTimeout(function () { el.hidden = true; }, 2800);
  }

  function setText(id, value) {
    var node = $(id);
    if (node) node.textContent = value;
  }

  function setAllText(id, value) {
    setText(id, value);
    setText(id + "-2", value);
  }

  // Ready claims a live phone-to-relay connection and a healthy clipboard
  // watcher. An unrecognised state satisfies neither, so it must not fall
  // through to Ready: a newer Relay adding a state the shell has not learned
  // would otherwise be reported as the best case.
  function statusCopyFor(syncState) {
    return Object.prototype.hasOwnProperty.call(STATUS, syncState)
      ? STATUS[syncState]
      : {
          label: "Sync needs attention",
          detail: "The Relay reported a state this window does not recognise.",
          icon: "syncProblem",
          tone: "warn",
        };
  }

  function renderState(next, fresh) {
    state = next;
    var copy = fresh === false ? STATUS.relay_down : statusCopyFor(next.syncState);
    document.body.setAttribute("data-sync", copy === STATUS.relay_down ? "relay_down" : next.syncState);
    setText("status-label", copy.label);
    $("status-icon").setAttribute("href", "#i-" + copy.icon);
    setText("status-detail", copy.detail);
    $("banner").hidden = copy.tone === "good";
    setAllText("relay-name", next.relayName);
    setAllText("endpoint", next.host + ":" + next.port);
    setAllText("devices", String(next.authenticatedDeviceCount));
    setAllText("devices-label", Number(next.authenticatedDeviceCount) === 1 ? "device" : "devices");
    setText("pairing-hint", Number(next.authenticatedDeviceCount) > 0
      ? "Already paired. Scan again to add another phone."
      : "Point the phone at this QR. The Relay is reachable only on this WiFi network.");
    if (next.pairingSecret !== lastSecret) {
      lastSecret = next.pairingSecret;
      $("qr").src = "/control/v1/qr.svg?v=" + encodeURIComponent(next.pairingSecret);
    }
  }

  // The Relay cannot report its own death: if it were down there would be
  // nothing to ask. So the client is the only place that knows, and it must
  // not guess from a single hiccup. Two consecutive failures, then say so.
  function markUnreachable() {
    renderState({
      syncState: "relay_down",
      relayName: state.relayName,
      host: state.host,
      port: state.port,
      pairingSecret: lastSecret,
      manual: state.manual,
      authenticatedDeviceCount: 0
    }, false);
  }

  // The QR is the entire point before pairing and near-pointless after it, so
  // the window opens on Pairing only while unpaired. Once a device is paired
  // the common task is sending, so open there instead.
  function defaultPane() {
    return Number(state.authenticatedDeviceCount || 0) > 0 ? "files" : "pairing";
  }

  function selectPane(id, focusTab) {
    if (PANES.indexOf(id) === -1) return;
    document.body.setAttribute("data-pane", id);
    for (var paneId of PANES) {
      var tab = $("tab-" + paneId);
      var pane = $("pane-" + paneId);
      var selected = paneId === id;
      tab.setAttribute("aria-selected", String(selected));
      tab.tabIndex = selected ? 0 : -1;
      pane.hidden = !selected;
    }
    if (focusTab) $("tab-" + id).focus();
  }

  function batchLabel(status) {
    if (status === "completed_with_issues") return "Completed with issues";
    if (status === "waiting_for_source") return "Waiting for source";
    if (!status) return "";
    return status.replace(/_/g, " ").replace(/^./, function (ch) { return ch.toUpperCase(); });
  }

  function ago(ms) {
    if (!ms) return "";
    var seconds = Math.max(0, Math.round((Date.now() - ms) / 1000));
    if (seconds < 10) return "just now";
    if (seconds < 60) return seconds + " seconds ago";
    var minutes = Math.round(seconds / 60);
    if (minutes < 60) return minutes + (minutes === 1 ? " minute ago" : " minutes ago");
    var hours = Math.round(minutes / 60);
    if (hours < 24) return hours + (hours === 1 ? " hour ago" : " hours ago");
    var days = Math.round(hours / 24);
    return days === 1 ? "yesterday" : days + " days ago";
  }

  function bytes(size) {
    if (!size || size < 1) return "";
    if (size < 1024) return size + " B";
    if (size < 1048576) return Math.round(size / 1024) + " KB";
    return (size / 1048576).toFixed(1) + " MB";
  }

  function batchTitle(batch) {
    var files = Array.isArray(batch.files) ? batch.files : [];
    var names = files.map(function (file) { return file.filename; }).filter(Boolean);
    if (names.length === 1) return names[0];
    if (names.length > 1) return names.length + " files";
    return batch.transferId || "Transfer";
  }

  function batchRow(batch) {
    var needsAttention = ATTENTION.indexOf(batch.status) !== -1;
    var tone = needsAttention ? " bad" : (batch.status === "completed" ? " good" : "");
    var direction = batch.direction === "phone_to_laptop" ? "From phone" : "To phone";
    var parts = [direction, batchLabel(batch.status)];
    var when = ago(batch.updatedAtMs || batch.createdAtMs);
    if (when) parts.push(when);
    var failed = (batch.files || []).filter(function (file) { return file.errorCode; })[0];
    return '<li><svg class="icon' + tone + '" viewBox="0 0 24 24" aria-hidden="true" focusable="false"><use href="#i-' +
      (needsAttention ? "warningAmber" : "checkCircle") + '"/></svg>' +
      '<div class="grow"><div class="row-title">' + escapeHtml(batchTitle(batch)) + '</div>' +
      '<div class="row-detail">' + escapeHtml(parts.join(" · ")) + '</div>' +
      (failed ? '<div class="row-fix">' + escapeHtml(failureText(failed.errorCode)) + '</div>' : "") +
      '</div></li>';
  }

  function renderTransfers(snapshot) {
    var list = $("transfers");
    var summary = $("file-summary");
    var batches = snapshot && Array.isArray(snapshot.batches) ? snapshot.batches : [];
    var ordered = batches.slice().sort(function (a, b) {
      return (b.updatedAtMs || b.createdAtMs || 0) - (a.updatedAtMs || a.createdAtMs || 0);
    });
    var attention = ordered.filter(function (batch) {
      return ATTENTION.indexOf(batch.status) !== -1;
    });
    var active = ordered.filter(function (batch) {
      return batch.status === "queued" || batch.status === "active" || batch.status === "paused";
    });

    summary.hidden = !ordered.length;
    if (ordered.length) {
      summary.innerHTML =
        '<div><b>' + active.length + '</b><span>Active</span></div>' +
        '<div><b>' + ordered.length + '</b><span>Transfers</span></div>' +
        '<div class="' + (attention.length ? "bad" : "") + '"><b>' + attention.length + '</b><span>Need attention</span></div>';
    }

    if (!ordered.length) {
      list.innerHTML = '<li class="empty">No transfers yet.</li>';
      return;
    }
    var html = "";
    if (attention.length) {
      html += '<li class="group-label">Needs attention</li>';
      html += attention.map(batchRow).join("");
    }
    html += '<li class="group-label">History</li>';
    html += ordered
      .filter(function (batch) { return ATTENTION.indexOf(batch.status) === -1; })
      .map(batchRow).join("");
    list.innerHTML = html;
  }

  function renderSetup(snapshot, checkedAt) {
    var list = $("setup");
    var summary = $("setup-summary");
    var rows = snapshot && Array.isArray(snapshot.rows) ? snapshot.rows.slice() : [];
    if (!rows.length) {
      list.innerHTML = '<li class="empty">Checking laptop setup status.</li>';
      return;
    }
    lastSetupRows = rows;
    // The Relay hardcodes its own row to healthy, because a Relay that is down
    // cannot answer. Only this client knows it lost contact, so it is the only
    // place that row can be corrected.
    var unreachable = missed >= MISSES_BEFORE_DOWN;
    rows = rows.map(function (row) {
      if (row.id !== "relay_running") return row;
      return unreachable
        ? { id: row.id, ok: false, detail: "The Relay is not answering." }
        : row;
    });
    var broken = rows.filter(function (row) { return !row.ok; });
    summary.hidden = false;
    summary.innerHTML = broken.length
      ? '<div class="bad"><b>' + broken.length + '</b><span>Needs a fix</span></div>' +
        '<div><b>' + (rows.length - broken.length) + '</b><span>Healthy</span></div>'
      : '<div><b>' + rows.length + '</b><span>All clear</span></div>';
    list.innerHTML = rows.map(function (row) {
      var title = SETUP_TITLES[row.id] || row.id;
      var fix = row.fix ? '<div class="row-fix">' + escapeHtml(row.fix) + '</div>' : "";
      return '<li><svg class="icon ' + (row.ok ? "good" : "warn") + '" viewBox="0 0 24 24" aria-hidden="true" focusable="false"><use href="#i-' +
        (row.ok ? "checkCircle" : "warningAmber") + '"/></svg>' +
        '<div class="grow"><div class="row-title">' + escapeHtml(title) + '</div>' +
        '<div class="row-detail">' + escapeHtml(row.detail || "") + '</div>' + fix + '</div></li>';
    }).join("");
    if (checkedAt) $("setup-checked").textContent = "Checked " + ago(checkedAt) + ".";
  }

  function escapeHtml(value) {
    return String(value)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");
  }

  async function getJson(path) {
    var response = await fetch(path, { cache: "no-store" });
    if (!response.ok) throw new Error(String(response.status));
    return response.json();
  }

  var refreshing = false;
  async function refresh() {
    if (refreshing) return;
    refreshing = true;
    try {
      var live;
      try {
        live = await getJson("/control/v1/state");
      } catch (err) {
        // One missed poll is not a dead Relay. Hold the last known state until
        // the failure repeats, then say so and mark the data stale.
        missed += 1;
        if (missed >= MISSES_BEFORE_DOWN) {
          markUnreachable();
          showStale();
        }
        return;
      }
      missed = 0;
      lastGoodAt = Date.now();
      var wasPaired = Number(state.authenticatedDeviceCount || 0) > 0;
      renderState(live, true);
      showStale();
      // Re-anchor once, when the pairing situation actually changes, so the
      // window does not yank a pane out from under someone mid-task.
      var isPaired = Number(state.authenticatedDeviceCount || 0) > 0;
      if (isPaired !== wasPaired) selectPane(defaultPane(), false);
      try { renderTransfers(await getJson("/control/v1/transfers"), lastGoodAt); }
      catch (err) { /* keep the last transfer history */ }
      try {
        var probed = await getJson("/control/v1/setup");
        renderSetup(probed, probed.checkedAtMs);
      } catch (err) { /* keep the last laptop setup status */ }
    } finally {
      refreshing = false;
    }
  }

  // Anything the Relay told us is only as fresh as the last check. Say so
  // rather than letting a frozen snapshot look live.
  function showStale() {
    var stale = missed >= MISSES_BEFORE_DOWN && lastGoodAt > 0;
    document.body.setAttribute("data-stale", String(stale));
    for (var id of ["transfers-stale", "setup-stale"]) {
      var node = $(id);
      if (!node) continue;
      node.hidden = !stale;
      if (stale) node.textContent = "Last checked " + ago(lastGoodAt) + ". The Relay is not answering.";
    }
    // The setup list still shows a hardcoded "Relay is answering" row from the
    // last good response. Re-render it so the correction is not stranded
    // waiting for a success that will never come.
    if (stale && lastSetupRows) renderSetup({ rows: lastSetupRows }, lastGoodAt);
  }

  function tauriCore() {
    return window.__TAURI__ && window.__TAURI__.core;
  }

  function hasShell() {
    var core = tauriCore();
    return Boolean(core && typeof core.invoke === "function");
  }

  function wireRelayButtons() {
    if (!hasShell()) return;
    for (var id of ["start-relay", "stop-relay"]) {
      var button = $(id);
      button.disabled = false;
      button.removeAttribute("title");
    }
    $("start-relay").addEventListener("click", async function () {
      try {
        await tauriCore().invoke("start_relay");
        snack("Starting the Relay.");
        setTimeout(refresh, 800);
      } catch (err) {
        snack("The Relay did not start.");
      }
    });
    $("stop-relay").addEventListener("click", async function () {
      try {
        await tauriCore().invoke("stop_relay");
        snack("Stopped the Relay. This window is still open.");
        setTimeout(refresh, 400);
      } catch (err) {
        snack("The Relay did not stop.");
      }
    });
  }

  // Without the Tauri shell behind it there is nothing to invoke, so say so
  // instead of leaving a control that looks live and does nothing.
  //
  // The explanation goes on the button's parent, not the button. A disabled
  // button emits no pointer events, so a title set on it never produces a
  // tooltip and the reason would be unreachable.
  function markShellOnly() {
    var explanation = "Start and stop relay run in the Vidyut desktop shell.";
    for (var id of ["start-relay", "stop-relay"]) {
      var button = $(id);
      if (!button.disabled) continue;
      var wrapper = button.closest("[data-explains]");
      if (wrapper && !wrapper.hasAttribute("title")) {
        wrapper.setAttribute("title", explanation);
        button.setAttribute(
          "aria-label",
          button.getAttribute("aria-label") + " " + explanation,
        );
      }
    }
    // Quitting is a shell action, so a browser tab has nothing to quit. This
    // runs again once Tauri finishes loading, because on the first pass the
    // bridge is not there yet and the control would stay hidden for good.
    $("quit-shell").hidden = !hasShell();
  }

  // The Relay caches the probe for 30s. "Check again" is how a user says they
  // just fixed something, so it bypasses the cache instead of making them wait.
  $("setup-recheck").addEventListener("click", async function () {
    var button = $("setup-recheck");
    button.disabled = true;
    try {
      var probed = await getJson("/control/v1/setup?refresh=1");
      renderSetup(probed, probed.checkedAtMs);
    } catch (err) {
      snack("Could not re-check laptop setup status.");
    } finally {
      button.disabled = false;
    }
  });

  $("copy-manual").addEventListener("click", async function () {
    try {
      await navigator.clipboard.writeText(state.manual || "");
      snack("Copied the pairing line.");
    } catch (err) {
      snack("Could not reach the clipboard.");
    }
  });

  $("send-files").addEventListener("click", async function () {
    if (!hasShell()) {
      snack("Send files from the Vidyut desktop shell, or its tray.");
      return;
    }
    try {
      var queued = await tauriCore().invoke("pick_and_send_files");
      if (!queued) return;
      selectPane("files", false);
      snack("Queued.");
      await refresh();
    } catch (err) {
      snack("The Relay did not accept that batch.");
    }
  });

  function setRotateOpen(open) {
    $("rotate-confirm").hidden = !open;
    $("rotate-open").setAttribute("aria-expanded", String(open));
    if (open) $("rotate-go").focus();
    else $("rotate-open").focus();
  }

  $("rotate-open").addEventListener("click", function () { setRotateOpen(true); });
  $("rotate-cancel").addEventListener("click", function () { setRotateOpen(false); });
  $("rotate-go").addEventListener("click", async function () {
    try {
      var response = await fetch("/control/v1/rotate-secret", { method: "POST" });
      if (!response.ok) throw new Error(String(response.status));
      renderState(await response.json());
      setRotateOpen(false);
      snack("Every phone must scan the new QR.");
    } catch (err) {
      snack("The pairing secret was not rotated.");
    }
  });

  $("open-releases").addEventListener("click", function (event) {
    if (!hasShell()) return;
    event.preventDefault();
    tauriCore().invoke("open_releases").catch(function () {});
  });

  // Sidebar navigation: click, arrow keys, and Ctrl+1..4.
  $("nav").addEventListener("click", function (event) {
    var tab = event.target.closest("[data-pane]");
    if (tab) selectPane(tab.getAttribute("data-pane"), false);
  });
  $("nav").addEventListener("keydown", function (event) {
    var step = event.key === "ArrowDown" ? 1 : event.key === "ArrowUp" ? -1 : 0;
    if (!step) return;
    event.preventDefault();
    var current = PANES.indexOf(document.body.getAttribute("data-pane"));
    var next = (current + step + PANES.length) % PANES.length;
    selectPane(PANES[next], true);
  });
  document.addEventListener("keydown", function (event) {
    if (event.key === "Escape" && !$("rotate-confirm").hidden) {
      setRotateOpen(false);
      return;
    }
    if (!event.ctrlKey && !event.metaKey) return;
    if (event.key >= "1" && event.key <= "4") {
      event.preventDefault();
      selectPane(PANES[Number(event.key) - 1], false);
    }
    if (event.key.toLowerCase() === "o") {
      event.preventDefault();
      $("send-files").click();
    }
    // The window's close button hides to the tray rather than quitting, so
    // without this there is no way to stop the shell from the keyboard. The
    // Relay keeps running either way; see ADR 0018.
    if (event.key.toLowerCase() === "q" && hasShell()) {
      event.preventDefault();
      quitShell();
    }
  });

  function quitShell() {
    if (!hasShell()) return;
    tauriCore()
      .invoke("quit_shell")
      .catch(function () {
        snack("The desktop shell did not quit.");
      });
  }

  state = bootState();
  lastSecret = state.pairingSecret || "";
  selectPane(defaultPane(), false);
  markShellOnly();
  $("quit-shell").addEventListener("click", quitShell);
  wireRelayButtons();
  (function waitTauri(tries) {
    if (hasShell() || tries <= 0) {
      wireRelayButtons();
      markShellOnly();
      return;
    }
    setTimeout(function () { waitTauri(tries - 1); }, 200);
  })(10);
  refresh();
  // Keep polling even while the window is hidden. Hiding to the tray is this
  // shell's normal state, so a visibility guard would leave it blind exactly
  // when it is supposed to be reporting health.
  setInterval(refresh, POLL_MS);
  document.addEventListener("visibilitychange", function () {
    if (!document.hidden) refresh();
  });
})();
`;
}
