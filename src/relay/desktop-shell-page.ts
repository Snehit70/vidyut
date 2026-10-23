import { SHELL_ICON_PATHS, type ShellIconName } from "./shell-assets";
// Bun's text loader inlines both files as strings, so the compiled Relay
// carries them like the rest of the page.
import SHELL_CSS from "./desktop-shell.css" with { type: "text" };
import SHELL_SCRIPT from "./desktop-shell.js" with { type: "text" };

export interface DesktopShellState {
  relayName: string;
  host: string;
  port: number;
  pairingSecret: string;
  manual: string;
  syncState: "ready" | "sync_paused" | "sync_needs_attention" | "relay_down";
  authenticatedDeviceCount: number;
  clipboard?: { paused?: boolean; pausedUntil?: number } | undefined;
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
  sync_paused: {
    label: "Sync paused",
    detail: "Clipboard sync is paused on this laptop. Files still move.",
    icon: "pauseCircle",
    tone: "warn",
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
  const paused = state.clipboard?.paused === true;
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
      <button type="button" class="btn outlined" id="banner-resume"${paused ? "" : " hidden"}>Resume</button>
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
        <section class="block">
          <h3>Shared with the phone</h3>
          <p>The phone can browse and download from these folders. Hidden files and links are never shown.</p>
          <ul class="rows" id="shared-folders">
            <li class="empty">Loading…</li>
          </ul>
          <div class="add-folder">
            <input type="text" id="share-path" class="field" placeholder="/home/you/Pictures or ~/Pictures" aria-label="Folder to share" aria-describedby="share-error" autocomplete="off" spellcheck="false"/>
            <button type="button" class="btn outlined" id="share-add">Share folder</button>
          </div>
          <p class="field-error" id="share-error" role="alert" hidden></p>
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
          <h3>Clipboard sync</h3>
          <p id="pause-summary">${paused ? "Paused. Files still move." : "Pausing stops this laptop sending what you copy and taking what the phone sends. Files still move."}</p>
          <div class="btn-row" id="pause-options"${paused ? " hidden" : ""}>
            <button type="button" class="btn outlined" data-pause-minutes="15">Pause 15 min</button>
            <button type="button" class="btn outlined" data-pause-minutes="60">Pause 1 hour</button>
            <button type="button" class="btn outlined" data-pause-minutes="">Until I resume</button>
          </div>
          <div class="btn-row" id="pause-resume-row"${paused ? "" : " hidden"}>
            <button type="button" class="btn filled" id="pause-resume">Resume clipboard sync</button>
          </div>
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
  <script type="application/json" id="shell">${embedJson({
    status: STATUS_COPY,
    panes: PANES.map((pane) => pane.id),
  })}</script>
  <script>${SHELL_SCRIPT}</script>
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

