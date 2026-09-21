export interface DesktopShellState {
  relayName: string;
  host: string;
  port: number;
  pairingSecret: string;
  manual: string;
  syncState: "ready" | "sync_needs_attention" | "relay_down";
  authenticatedDeviceCount: number;
}

export function desktopShellHtml(state: DesktopShellState): string {
  const status = statusCopy(state.syncState);
  return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8"/>
  <meta name="viewport" content="width=device-width, initial-scale=1"/>
  <meta name="color-scheme" content="light only"/>
  <title>Vidyut</title>
  <link rel="preconnect" href="https://fonts.googleapis.com"/>
  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin/>
  <link href="https://fonts.googleapis.com/css2?family=Plus+Jakarta+Sans:wght@500;600;800&display=swap" rel="stylesheet"/>
  <link href="https://fonts.googleapis.com/icon?family=Material+Icons+Outlined" rel="stylesheet"/>
  <style>${SHELL_CSS}</style>
</head>
<body data-sync="${escapeHtml(state.syncState)}">
  <main>
    <header class="masthead enter" style="animation-delay:0ms">
      <h1>Vidyut</h1>
      <p class="lede">Pairing, files, and laptop setup status for this Relay.</p>
    </header>

    <section class="hero enter" id="status-card" style="animation-delay:100ms">
      <span class="hero-dot" aria-hidden="true"></span>
      <div>
        <h2 id="status-label">${escapeHtml(status.label)}</h2>
        <p id="status-detail">${escapeHtml(status.detail)}</p>
      </div>
    </section>

    <section class="card enter" style="animation-delay:200ms">
      <h2>Pairing</h2>
      <p class="body">Point the phone at this pairing QR. One secret is shared by every device.</p>
      <img class="qr" id="qr" alt="Pairing QR" src="/control/v1/qr.svg" width="224" height="224"/>
      <dl>
        <dt>Laptop</dt><dd id="relay-name">${escapeHtml(state.relayName)}</dd>
        <dt>Host</dt><dd id="host">${escapeHtml(state.host)}</dd>
        <dt>Port</dt><dd id="port">${escapeHtml(String(state.port))}</dd>
        <dt>Secret</dt><dd id="secret">${escapeHtml(state.pairingSecret)}</dd>
        <dt>Manual</dt><dd id="manual">${escapeHtml(state.manual)}</dd>
        <dt>Devices</dt><dd id="devices">${escapeHtml(String(state.authenticatedDeviceCount))}</dd>
      </dl>
      <button type="button" class="btn outlined" id="copy-manual">Copy manual line</button>
    </section>

    <section class="card enter" style="animation-delay:300ms">
      <h2>Send files</h2>
      <p class="body">Enqueue a batch from this laptop. The browser cannot see file paths, so type each path on its own line. A file picker can fill paths when the desktop shell provides them.</p>
      <input id="file-input" type="file" multiple/>
      <label class="field-label" for="path-input">Paths</label>
      <textarea id="path-input" rows="4" placeholder="One filesystem path per line" spellcheck="false"></textarea>
      <button type="button" class="btn filled" id="send-files">Send files</button>
    </section>

    <section class="card enter" style="animation-delay:400ms">
      <h2>Transfer history</h2>
      <ul class="list" id="transfers">
        <li class="muted">No transfers yet.</li>
      </ul>
    </section>

    <section class="card enter" style="animation-delay:500ms">
      <h2>Laptop setup status</h2>
      <p class="body">Live health for the conditions that can degrade this Relay.</p>
      <ul class="list" id="setup"></ul>
    </section>

    <section class="card enter" style="animation-delay:600ms">
      <h2>Rotate pairing secret</h2>
      <p class="body">Replaces the Relay's single pairing secret. Every phone must scan again. There is no per-phone roster.</p>
      <button type="button" class="btn outlined" id="rotate-open">Rotate pairing secret</button>
      <div id="rotate-confirm" class="confirm" hidden>
        <p>Every phone must scan the new QR. Clipboard and transfers pause until they pair again.</p>
        <div class="btn-row">
          <button type="button" class="btn outlined" id="rotate-cancel">Cancel</button>
          <button type="button" class="btn filled" id="rotate-go">Rotate</button>
        </div>
      </div>
    </section>

    <section class="card enter" style="animation-delay:700ms">
      <h2>Relay</h2>
      <p class="body">Start and stop live in the desktop shell, which talks to the systemd user unit. A browser tab cannot change it.</p>
      <div class="btn-row">
        <button type="button" class="btn outlined" id="start-relay" disabled title="Use the desktop shell">Start relay</button>
        <button type="button" class="btn outlined" id="stop-relay" disabled title="Use the desktop shell">Stop relay</button>
      </div>
    </section>

    <p class="footnote enter" style="animation-delay:800ms">Closing this window does not stop the Relay.</p>
    <p class="footnote enter" style="animation-delay:850ms"><a id="open-releases" href="https://github.com/Snehit70/vidyut/releases">Open releases</a>. Install a newer .rpm or .deb with dnf or apt. This window does not update Vidyut.</p>
  </main>
  <div id="snack" class="snack" hidden></div>
  <script type="application/json" id="boot">${embedJson(state)}</script>
  <script>${SHELL_SCRIPT}</script>
</body>
</html>
`;
}

function statusCopy(syncState: DesktopShellState["syncState"]): {
  label: string;
  detail: string;
} {
  if (syncState === "sync_needs_attention") {
    return {
      label: "Sync needs attention",
      detail: "Connected, but automatic clipboard sync needs recovery.",
    };
  }
  if (syncState === "relay_down") {
    return {
      label: "Relay down",
      detail:
        "The Relay is not answering. Clipboard and transfers pause until it is running.",
    };
  }
  return {
    label: "Ready",
    detail: "Automatic clipboard sync is ready between your devices.",
  };
}

function escapeHtml(value: string): string {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

function embedJson(value: unknown): string {
  return JSON.stringify(value)
    .replaceAll("<", "\\u003c")
    .replaceAll(">", "\\u003e")
    .replaceAll("&", "\\u0026");
}

const SHELL_CSS = `
:root {
  --ground: #FFFFFF;
  --mist: #FDF0F4;
  --petal: #F8D3DE;
  --raspberry: #C83861;
  --ink: #33202B;
  --muted: #856774;
  --hairline: #9D878F;
  --error: #B3283E;
  --font-sans: "Plus Jakarta Sans", system-ui, sans-serif;
  --radius-card: 20px;
  --radius-input: 16px;
  --radius-pill: 999px;
  --button-height: 54px;
  --ease-spring: cubic-bezier(0.34, 1.56, 0.64, 1);
  --ease-out-cubic: cubic-bezier(0.33, 1, 0.68, 1);
}
* { box-sizing: border-box; }
html, body { background: var(--ground); color: var(--ink); }
body {
  margin: 0;
  font-family: var(--font-sans);
  font-size: 14px;
  font-weight: 500;
  line-height: 1.3;
  color-scheme: only light;
}
main {
  max-width: 560px;
  margin: 0 auto;
  padding: 24px 20px 96px;
  display: flex;
  flex-direction: column;
  gap: 16px;
}
h1 {
  margin: 0;
  font-size: 26px;
  font-weight: 800;
  letter-spacing: -0.03em;
}
h2 {
  margin: 0 0 8px;
  font-size: 16px;
  font-weight: 600;
}
.lede, .body, .footnote {
  margin: 0;
  color: var(--muted);
}
.footnote { padding: 4px 4px 0; }
a { color: var(--raspberry); font-weight: 600; }
.hero, .card {
  border-radius: var(--radius-card);
  padding: 20px;
  box-shadow: none;
}
.hero {
  display: flex;
  gap: 14px;
  align-items: flex-start;
  background: var(--petal);
}
body[data-sync="sync_needs_attention"] .hero,
body[data-sync="relay_down"] .hero {
  background: var(--mist);
}
body[data-sync="relay_down"] #status-label { color: var(--error); }
.hero h2 { margin: 0 0 4px; font-size: 20px; font-weight: 800; letter-spacing: -0.03em; }
.hero p { margin: 0; color: var(--muted); }
.hero-dot {
  width: 12px;
  height: 12px;
  margin-top: 6px;
  border-radius: 999px;
  background: var(--raspberry);
  box-shadow: 0 0 0 8px color-mix(in srgb, var(--raspberry) 18%, transparent);
  animation: pulse 1.4s ease-out infinite;
}
body[data-sync="relay_down"] .hero-dot { background: var(--error); box-shadow: none; animation: none; }
.card { background: var(--mist); }
.qr {
  display: block;
  width: 224px;
  height: 224px;
  margin: 16px 0;
  background: var(--ground);
  border-radius: var(--radius-input);
}
dl {
  display: grid;
  grid-template-columns: 7rem 1fr;
  gap: 8px 12px;
  margin: 0 0 16px;
}
dt { color: var(--muted); font-size: 12px; font-weight: 600; }
dd { margin: 0; overflow-wrap: anywhere; user-select: all; }
.btn {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  width: 100%;
  height: var(--button-height);
  padding: 0 24px;
  border: none;
  border-radius: var(--radius-pill);
  font-family: inherit;
  font-size: 15px;
  font-weight: 600;
  line-height: 1.3;
  cursor: pointer;
  transition: transform 120ms var(--ease-out-cubic);
}
.btn:active:not(:disabled) { transform: scale(0.93); }
.btn.filled { background: var(--raspberry); color: #FFFFFF; }
.btn.outlined {
  background: var(--ground);
  color: var(--raspberry);
  border: 1.5px solid var(--petal);
}
.btn:disabled { opacity: 0.5; cursor: default; }
.btn-row { display: flex; gap: 10px; }
.btn-row .btn { flex: 1; }
#file-input, textarea {
  display: block;
  width: 100%;
  margin: 12px 0 0;
  padding: 14px 16px;
  border: 1px solid var(--hairline);
  border-radius: var(--radius-input);
  background: var(--ground);
  color: var(--ink);
  font-family: inherit;
  font-size: 14px;
  font-weight: 500;
  line-height: 1.3;
}
#file-input { padding: 12px; }
textarea:focus, #file-input:focus {
  outline: none;
  border: 1.6px solid var(--raspberry);
}
.field-label {
  display: block;
  margin: 16px 0 0;
  font-size: 12px;
  font-weight: 600;
  color: var(--raspberry);
}
#send-files { margin-top: 16px; }
.list { list-style: none; margin: 12px 0 0; padding: 0; display: flex; flex-direction: column; gap: 10px; }
.list li {
  background: var(--ground);
  border-radius: var(--radius-input);
  padding: 14px 16px;
}
.row-title { font-size: 14px; font-weight: 600; }
.row-detail, .muted { color: var(--muted); font-size: 12px; }
.row-fix { margin: 4px 0 0; color: var(--error); font-size: 12px; }
.setup-row { display: flex; gap: 12px; align-items: flex-start; }
.material-icons-outlined {
  font-family: "Material Icons Outlined";
  font-weight: normal;
  font-style: normal;
  font-size: 22px;
  line-height: 1;
  letter-spacing: normal;
  text-transform: none;
  display: inline-block;
  white-space: nowrap;
  word-wrap: normal;
  direction: ltr;
  color: var(--raspberry);
  font-feature-settings: "liga";
  -webkit-font-smoothing: antialiased;
}
.material-icons-outlined.warn { color: var(--error); }
.confirm {
  margin-top: 16px;
  padding: 16px;
  background: var(--petal);
  border-radius: var(--radius-input);
}
.confirm p { margin: 0 0 12px; }
.snack {
  position: fixed;
  left: 50%;
  bottom: 24px;
  transform: translateX(-50%);
  max-width: calc(100% - 40px);
  padding: 12px 20px;
  background: var(--ink);
  color: #FFFFFF;
  border-radius: var(--radius-pill);
  font-size: 14px;
  font-weight: 500;
  box-shadow: none;
}
.enter {
  animation: rise 600ms var(--ease-spring) both;
}
@keyframes rise {
  from { opacity: 0; transform: translateY(30px); }
  to { opacity: 1; transform: none; }
}
@keyframes pulse {
  0% { box-shadow: 0 0 0 0 color-mix(in srgb, var(--raspberry) 28%, transparent); }
  100% { box-shadow: 0 0 0 12px transparent; }
}
`;

const SHELL_SCRIPT = `
(function () {
  var POLL_MS = 4000;
  var setupTitles = {
    relay_running: "Relay running",
    wayland: "Wayland",
    wl_clipboard: "wl-clipboard",
    imagemagick: "ImageMagick",
    autostart: "Autostart",
    firewall: "Firewall"
  };
  var snackTimer;
  var lastSecret = "";

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

  function statusCopy(syncState) {
    if (syncState === "sync_needs_attention") {
      return {
        label: "Sync needs attention",
        detail: "Connected, but automatic clipboard sync needs recovery."
      };
    }
    if (syncState === "relay_down") {
      return {
        label: "Relay down",
        detail: "The Relay is not answering. Clipboard and transfers pause until it is running."
      };
    }
    return {
      label: "Ready",
      detail: "Automatic clipboard sync is ready between your devices."
    };
  }

  function setText(id, value) {
    var node = $(id);
    if (node) node.textContent = value;
  }

  function renderState(state) {
    var copy = statusCopy(state.syncState);
    document.body.setAttribute("data-sync", state.syncState);
    setText("status-label", copy.label);
    setText("status-detail", copy.detail);
    setText("relay-name", state.relayName);
    setText("host", state.host);
    setText("port", String(state.port));
    setText("secret", state.pairingSecret);
    setText("manual", state.manual);
    setText("devices", String(state.authenticatedDeviceCount));
    if (state.pairingSecret !== lastSecret) {
      lastSecret = state.pairingSecret;
      $("qr").src = "/control/v1/qr.svg?v=" + encodeURIComponent(state.pairingSecret);
    }
  }

  function batchLabel(status) {
    if (status === "completed_with_issues") return "Completed with issues";
    if (status === "laptop_to_phone") return "To phone";
    if (status === "phone_to_laptop") return "From phone";
    if (!status) return "";
    return status.replace(/_/g, " ").replace(/^./, function (ch) { return ch.toUpperCase(); });
  }

  function renderTransfers(snapshot) {
    var list = $("transfers");
    var batches = snapshot && Array.isArray(snapshot.batches) ? snapshot.batches : [];
    if (!batches.length) {
      list.innerHTML = '<li class="muted">No transfers yet.</li>';
      return;
    }
    list.innerHTML = batches.map(function (batch) {
      var names = (batch.files || []).map(function (file) { return file.filename; }).filter(Boolean);
      var title = names.length ? names.join(", ") : (batch.transferId || "Transfer");
      var direction = batch.direction === "phone_to_laptop" ? "From phone" : "To phone";
      return '<li><div class="row-title">' + escapeHtml(title) + '</div>' +
        '<div class="row-detail">' + escapeHtml(direction + " · " + batchLabel(batch.status)) + '</div></li>';
    }).join("");
  }

  function renderSetup(status) {
    var list = $("setup");
    var rows = status && Array.isArray(status.rows) ? status.rows : [];
    if (!rows.length) {
      list.innerHTML = '<li class="muted">Checking laptop setup status.</li>';
      return;
    }
    list.innerHTML = rows.map(function (row) {
      var title = setupTitles[row.id] || row.id;
      var icon = row.ok ? "check_circle" : "warning_amber";
      var markClass = row.ok
        ? "material-icons-outlined"
        : "material-icons-outlined warn";
      var fix = row.fix
        ? '<p class="row-fix">' + escapeHtml(row.fix) + '</p>'
        : "";
      return '<li class="setup-row"><span class="' + markClass + '">' + icon + '</span>' +
        '<div><div class="row-title">' + escapeHtml(title) + '</div>' +
        '<div class="row-detail">' + escapeHtml(row.detail || "") + '</div>' + fix + '</div></li>';
    }).join("");
  }

  function escapeHtml(value) {
    return String(value)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");
  }

  function collectPaths() {
    var typed = $("path-input").value.split(/\\n/).map(function (line) {
      return line.trim();
    }).filter(Boolean);
    var files = $("file-input").files;
    var fromFiles = [];
    for (var i = 0; i < files.length; i++) {
      if (files[i].path) fromFiles.push(files[i].path);
    }
    return fromFiles.length ? fromFiles : typed;
  }

  async function getJson(path) {
    var response = await fetch(path, { cache: "no-store" });
    if (!response.ok) throw new Error(String(response.status));
    return response.json();
  }

  async function refresh() {
    try {
      var state = await getJson("/control/v1/state");
      renderState(state);
    } catch (err) {
      renderState({
        syncState: "relay_down",
        relayName: $("relay-name").textContent,
        host: $("host").textContent,
        port: $("port").textContent,
        pairingSecret: $("secret").textContent,
        manual: $("manual").textContent,
        authenticatedDeviceCount: $("devices").textContent
      });
      return;
    }
    try { renderTransfers(await getJson("/control/v1/transfers")); }
    catch (err) { /* keep last transfer history */ }
    try { renderSetup(await getJson("/control/v1/setup")); }
    catch (err) { /* keep last laptop setup status */ }
  }

  $("copy-manual").addEventListener("click", async function () {
    var line = $("manual").textContent || "";
    try {
      await navigator.clipboard.writeText(line);
      snack("Copied the manual pairing line.");
    } catch (err) {
      snack("Select the manual line and copy it.");
    }
  });

  $("file-input").addEventListener("change", function () {
    var files = $("file-input").files;
    var paths = [];
    for (var i = 0; i < files.length; i++) {
      if (files[i].path) paths.push(files[i].path);
    }
    if (paths.length) $("path-input").value = paths.join("\\n");
  });

  function tauriCore() {
    return window.__TAURI__ && window.__TAURI__.core;
  }

  function wireRelayButtons() {
    var core = tauriCore();
    var start = $("start-relay");
    var stop = $("stop-relay");
    if (!core || start.dataset.wired === "1") return;
    start.dataset.wired = "1";
    start.disabled = false;
    stop.disabled = false;
    start.removeAttribute("title");
    stop.removeAttribute("title");
    start.addEventListener("click", async function () {
      try {
        await core.invoke("start_relay");
        snack("Starting the Relay.");
        setTimeout(refresh, 800);
      } catch (err) {
        snack("The Relay did not start.");
      }
    });
    stop.addEventListener("click", async function () {
      try {
        await core.invoke("stop_relay");
        snack("Stop relay does not quit the desktop shell.");
        setTimeout(refresh, 400);
      } catch (err) {
        snack("The Relay did not stop.");
      }
    });
  }

  $("send-files").addEventListener("click", async function () {
    var paths = collectPaths();
    var core = tauriCore();
    if (!paths.length && core) {
      try {
        var queued = await core.invoke("pick_and_send_files");
        if (!queued) return;
        snack("Queued.");
        await refresh();
      } catch (err) {
        snack("The Relay did not accept that batch.");
      }
      return;
    }
    if (!paths.length) {
      snack("Type each filesystem path on its own line.");
      return;
    }
    try {
      var response = await fetch("/control/v1/transfers/enqueue", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ paths: paths })
      });
      if (response.status === 503) {
        snack("Send files needs the desktop shell.");
        return;
      }
      if (!response.ok) {
        var body = await response.json().catch(function () { return {}; });
        snack(body.message || "The batch was not queued.");
        return;
      }
      $("path-input").value = "";
      $("file-input").value = "";
      snack("Queued.");
      await refresh();
    } catch (err) {
      snack("The Relay did not accept that batch.");
    }
  });

  $("rotate-open").addEventListener("click", function () {
    $("rotate-confirm").hidden = false;
  });
  $("rotate-cancel").addEventListener("click", function () {
    $("rotate-confirm").hidden = true;
  });
  $("rotate-go").addEventListener("click", async function () {
    try {
      var response = await fetch("/control/v1/rotate-secret", { method: "POST" });
      if (!response.ok) {
        snack("The pairing secret was not rotated.");
        return;
      }
      var state = await response.json();
      renderState(state);
      $("rotate-confirm").hidden = true;
      snack("Every phone must scan the new QR.");
    } catch (err) {
      snack("The pairing secret was not rotated.");
    }
  });

  $("open-releases").addEventListener("click", function (event) {
    var core = tauriCore();
    if (!core || typeof core.invoke !== "function") return;
    event.preventDefault();
    core.invoke("open_releases").catch(function () {});
  });

  lastSecret = (bootState().pairingSecret || $("secret").textContent || "");
  wireRelayButtons();
  (function waitTauri(tries) {
    if (tauriCore() || tries <= 0) {
      wireRelayButtons();
      return;
    }
    setTimeout(function () { waitTauri(tries - 1); }, 200);
  })(10);
  refresh();
  setInterval(refresh, POLL_MS);
})();
`;
