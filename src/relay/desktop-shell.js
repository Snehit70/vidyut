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
  // Status copy and pane order are defined in desktop-shell-page.ts, which
  // also renders the markup, and arrive as JSON like the boot state.
  var SHELL = JSON.parse(document.getElementById("shell").textContent);
  var STATUS = SHELL.status;
  var PANES = SHELL.panes;
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
    setText("status-detail", pauseDetail(next, copy));
    $("banner").hidden = copy.tone === "good";
    renderPause(next, copy);
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

  function pausedUntil(next) {
    var until = next.clipboard && next.clipboard.pausedUntil;
    return typeof until === "number" ? new Date(until) : null;
  }

  function untilText(date) {
    return date.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
  }

  function pauseDetail(next, copy) {
    if (copy !== STATUS.sync_paused) return copy.detail;
    var until = pausedUntil(next);
    return until
      ? "Clipboard sync is paused until " + untilText(until) + ". Files still move."
      : "Clipboard sync is paused until you resume it. Files still move.";
  }

  // A degraded watcher reports needs-attention even while paused, so the
  // controls follow the clipboard fields rather than the headline state.
  function renderPause(next, copy) {
    var paused = copy !== STATUS.relay_down && !!(next.clipboard && next.clipboard.paused);
    $("banner-resume").hidden = !paused;
    $("pause-options").hidden = paused;
    $("pause-resume-row").hidden = !paused;
    var until = pausedUntil(next);
    setText("pause-summary", paused
      ? (until ? "Paused until " + untilText(until) + "." : "Paused until you resume it.") + " Files still move."
      : "Pausing stops this laptop sending what you copy and taking what the phone sends. Files still move.");
  }

  async function postJson(path, body) {
    var response = await fetch(path, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(body || {})
    });
    if (!response.ok) throw new Error(String(response.status));
    return response.json();
  }

  async function resumeClipboard() {
    try {
      renderState(await postJson("/control/v1/clipboard/resume"));
      snack("Clipboard sync resumed.");
    } catch (err) {
      snack("Clipboard sync was not resumed.");
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

  $("pause-options").addEventListener("click", async function (event) {
    var button = event.target.closest("[data-pause-minutes]");
    if (!button) return;
    var minutes = button.getAttribute("data-pause-minutes");
    try {
      renderState(await postJson("/control/v1/clipboard/pause", minutes ? { minutes: Number(minutes) } : {}));
      snack("Clipboard sync paused.");
    } catch (err) {
      snack("Clipboard sync was not paused.");
    }
  });
  $("pause-resume").addEventListener("click", resumeClipboard);
  $("banner-resume").addEventListener("click", resumeClipboard);

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
