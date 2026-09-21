let meta = #{
    name: "linux-desktop-shell",
    description: "Implement the Linux desktop shell on the current branch, verify, and open a PR",
    when_to_use: "Build the loopback control plane, Tauri tray, packaging, tests, and PR on the current Vidyut branch",
    phases: [
        #{ title: "Control plane", detail: "loopback-gated pairing JSON/HTML and tests" },
        #{ title: "Shell UI", detail: "branded control pages: status, files, setup, rotate" },
        #{ title: "Tauri", detail: "window, tray, systemd start, replace yad" },
        #{ title: "Packaging", detail: "rpm/deb scripts, install path, docs" },
        #{ title: "Verify", detail: "typecheck, tests, build, adversarial review" },
        #{ title: "Fix", detail: "close verified gaps" },
        #{ title: "Pull request", detail: "commit remainder, push, open PR" },
    ],
};

let result_schema = #{
    "type": "object",
    "required": ["ok", "summary"],
    "properties": #{
        "ok": #{ "type": "boolean" },
        "summary": #{ "type": "string" },
        "blockers": #{
            "type": "array",
            "items": #{ "type": "string" },
        },
    },
};

let findings_schema = #{
    "type": "object",
    "required": ["findings"],
    "properties": #{
        "findings": #{
            "type": "array",
            "maxItems": 10,
            "items": #{
                "type": "object",
                "required": ["file", "issue"],
                "properties": #{
                    "file": #{ "type": "string" },
                    "issue": #{ "type": "string" },
                },
            },
        },
    },
};

fn common_rules() {
    let p = "Work in the existing git checkout only. Do not create a worktree or a new branch. ";
    p += "The branch is already named feat/linux-desktop-shell. ";
    p += "Read files before editing. Keep diffs scoped. Conventional commits, no AI attribution, no Co-authored-by. Never commit secrets. ";
    p += "Use CONTEXT.md terms: Relay, Pool, Payload, Device, Pairing, desktop shell, laptop setup status, rotate pairing secret, Ready, Sync needs attention, Transfer, Files. ";
    p += "Do not implement Windows, X11 clipboard, Activity on the laptop, Electron, or Flutter desktop. ";
    p += "The hang-fix commit 37914c7 must stay. Do not revert it. ";
    p += "Use tools. Do not answer from memory. After code changes run bunx tsc --noEmit and bun test, and do not leave them red. ";
    p += "Return JSON {ok, summary, blockers} via the schema. ok=true only if you ran the relevant tests and they passed.\n";
    p
}

fn control_prompt() {
    let p = common_rules();
    p += "PHASE: loopback control plane in the Relay.\n";
    p += "Design (locked): Relay binds 0.0.0.0:17321. Control routes on that same port MUST 404 unless Bun requestIP is loopback (127.0.0.1, ::1, 127.*, ::ffff:127.*). ";
    p += "LAN WebSocket, /health, and authenticated /transfer/v1/ stay as they are. /health must not include the pairing secret.\n";
    p += "Implement TDD. Write failing tests first in tests/relay-control-plane.test.ts (or similar), then code.\n";
    p += "Required routes, all loopback-gated:\n";
    p += "1. GET / and GET /ui/ serving a branded HTML shell (can be a first pairing+status page; later phase fills files/setup).\n";
    p += "2. GET /control/v1/state JSON: relayName, host, port, pairingSecret, manual pairing line, syncState (ready|sync_needs_attention|relay_down), clipboard health, authenticated device count, pool metadata (type/mime/bytes/origin/age only, never ciphertext or plaintext).\n";
    p += "3. GET /control/v1/qr.svg (or png) QR of the existing pairing JSON from createPairingCode. Not ascii from qrcode-terminal.\n";
    p += "4. POST /control/v1/rotate-secret: persist a new pairing secret into relay.json (mode 600), update the in-memory secret used by websocket auth and transfers, return the new state. Existing phones must fail auth. Do not kill the process.\n";
    p += "5. GET /control/v1/transfers: transfer history the Relay already stores.\n";
    p += "6. POST /control/v1/transfers/enqueue JSON {paths: string[]} using the existing laptop local enqueue path internally.\n";
    p += "7. GET /control/v1/setup: laptop setup status rows: relay_running (true if this answers), wayland (WAYLAND_DISPLAY), wl_clipboard (wl-paste --version, note if below 2.3), imagemagick (magick), autostart (systemctl --user is-enabled vidyut-relay.service when possible), firewall (best-effort or unknown).\n";
    p += "createRelay must take a mutable pairing secret (object/ref) so rotate works. Wire this from cli.ts loadOrCreateRelayConfig. Persist via the existing config writer if one exists; otherwise add a tight helper next to config.ts.\n";
    p += "Tests must prove: loopback GET /control/v1/state is 200 and includes secret; a non-loopback client gets 404 and the body has no secret. ";
    p += "If you cannot spoof requestIP, bind 0.0.0.0, fetch via 127.0.0.1 (200) and via a LAN IPv4 from getLanIPv4Addresses() (404). Skip the LAN case only if no LAN IP exists. ";
    p += "/health from loopback still 200 and JSON.stringify(health) must not contain the pairing secret. Rotate secret test: auth with old secret fails, new secret works. Enqueue/setup can be thinner but must 404 off loopback.\n";
    p += "Commit as feat(relay): loopback-gated desktop control plane\n";
    p
}

fn ui_prompt() {
    let p = common_rules();
    p += "PHASE: branded desktop-shell HTML that the Relay already serves on loopback.\n";
    p += "Read .claude/skills/vidyut-design/readme.md, tokens in .claude/skills/vidyut-design/tokens/, CONTEXT.md, ADRs 0018-0021.\n";
    p += "The page is Flat Raspberry Pink: ground #FFFFFF, mist #FDF0F4, petal #F8D3DE, raspberry #C83861, ink #33202B, muted #856774, hairline #9D878F, error #B3283E. ";
    p += "Plus Jakarta Sans from Google Fonts. 20px card radius, pill buttons, no shadows, no dark mode, no emoji, sentence case, no exclamation marks.\n";
    p += "Surfaces: pairing card (QR image from /control/v1/qr.svg, host/port/secret, copy manual line); status Ready / Sync needs attention / Relay down from /control/v1/state; Send files (file input + enqueue); transfer history; laptop setup status checklist; rotate pairing secret behind a confirmation that every phone must scan again; a note that closing this window does not stop the Relay.\n";
    p += "No Activity timeline. Start/stop Relay buttons may exist as disabled hints in the browser page, because systemd stop is the Tauri shell's job. Do not make GET / stop the process.\n";
    p += "Poll state every few seconds. Works at http://127.0.0.1:17321/ without Tauri.\n";
    p += "Keep loopback tests green. Add a test that the HTML is 200 on loopback and 404 off loopback.\n";
    p += "Commit as feat(relay): branded loopback desktop shell pages\n";
    p
}

fn tauri_prompt() {
    let p = common_rules();
    p += "PHASE: Tauri 2 desktop shell around the loopback page.\n";
    p += "Create a Tauri 2 project (Rust is installed: rustc 1.95). Webview loads http://127.0.0.1:17321/ (or /ui/). ";
    p += "If the Relay is down, run `systemctl --user start vidyut-relay.service` and retry. Do not embed the Relay inside the Tauri process.\n";
    p += "Tray stays when the window closes. Tray menu: Show, Send files (native file dialog then POST enqueue or `vidyut-relay --send`), Quit. Quit does NOT stop the Relay. ";
    p += "Window has explicit Start relay / Stop relay that call systemctl --user start|stop vidyut-relay.service.\n";
    p += "Desktop autostart .desktop for the Tauri binary, replacing packaging/desktop/vidyut-tray.desktop and scripts/vidyut-tray. ";
    p += "Update scripts/install-relay.sh: stop installing yad tray; install the Tauri binary if it was built; keep Dolphin/Nautilus send actions; zenity only if still needed for vidyut-send with no args, otherwise open the shell.\n";
    p += "Do not require yad. Document extra Fedora packages for Tauri/webkit if needed in INSTALL.md.\n";
    p += "If a full `cargo tauri build` is too heavy for this step, still produce a compilable project and a script `bun run build:shell` (or similar). Run `cargo check` in src-tauri at minimum.\n";
    p += "Commit as feat(desktop): Tauri tray around the loopback Relay UI\n";
    p
}

fn packaging_prompt() {
    let p = common_rules();
    p += "PHASE: Linux packages and docs.\n";
    p += "Add a way to build .rpm and .deb from GitHub Releases later: nfpm.yaml or equivalent, plus scripts/build-linux-packages.sh. ";
    p += "Packages depend on wl-clipboard and ImageMagick, install vidyut-relay, systemd user unit, desktop file for the shell, Dolphin/Nautilus actions. They do not require Bun at runtime.\n";
    p += "Update docs/INSTALL.md, docs/SETUP.md, docs/USAGE.md, README.md: pairing QR is in the desktop shell, not journalctl as the primary path. journalctl can remain as fallback. ";
    p += "No auto-update. Mention that a newer GitHub release is installed with dnf/apt. The shell may later show a GitHub link; a simple 'Open releases' link is enough.\n";
    p += "CI (.github/workflows/ci.yml) must still typecheck, bun test, and build the relay. Add a packages job only if it will stay green on ubuntu-latest without secrets. Do not break release.yml version bump (it only expects pubspec + package.json from the bump step).\n";
    p += "Commit as feat(packaging): linux rpm/deb packaging for relay and desktop shell\n";
    p
}

fn verify_prompt() {
    let p = common_rules();
    p += "PHASE: verify. Run bunx tsc --noEmit and bun test. Run bun run build:relay. If the Tauri project exists, run cargo check in it. ";
    p += "Read git diff against origin/main (or main) and confirm: loopback 404 for control routes, /health has no secret, rotate pairing secret, yad no longer required, file-manager actions remain, CONTEXT.md and ADRs 0018-0021 present. ";
    p += "ok=true only if tsc and bun test passed. Put failures in blockers.\n";
    p
}

fn review_prompt() {
    let p = "Review the current workspace diff vs main for the Vidyut Linux desktop shell. ";
    p += "Use tools: git diff main...HEAD, git status, read the changed files. Do not answer from memory. ";
    p += "Look for: pairing secret leaking on LAN, control routes without loopback gate, tests that never fail the LAN case, Activity added to the laptop, Electron, Windows code, yad still required, missing tests, tsc issues, secrets in git. ";
    p += "Report at most 10 concrete {file, issue} findings. Empty list is valid only after you read the diff.\n";
    p
}

let implement_opts = #{
    capability_mode: "all",
    output_schema: result_schema,
};

phase("Control plane");
log("Implementing loopback-gated control plane");
let control = agent(control_prompt(), #{
    label: "control-plane",
    capability_mode: "all",
    output_schema: result_schema,
});

phase("Shell UI");
log("Implementing branded loopback pages");
let ui = agent(ui_prompt(), #{
    label: "shell-ui",
    capability_mode: "all",
    output_schema: result_schema,
});

phase("Tauri");
log("Implementing Tauri tray");
let tauri = agent(tauri_prompt(), #{
    label: "tauri-shell",
    capability_mode: "all",
    output_schema: result_schema,
});

phase("Packaging");
log("Packaging and docs");
let packaging = agent(packaging_prompt(), #{
    label: "packaging",
    capability_mode: "all",
    output_schema: result_schema,
});

phase("Verify");
log("Running tests and review");
let verified = agent(verify_prompt(), #{
    label: "verify",
    capability_mode: "all",
    output_schema: result_schema,
});

let review = agent(review_prompt(), #{
    label: "review",
    capability_mode: "read-only",
    output_schema: findings_schema,
});

let findings = [];
if review != () && review.success && review.output != () && review.output.findings != () {
    findings = review.output.findings;
}

phase("Fix");
if findings.len() > 0 {
    log("Fixing " + findings.len().to_string() + " review findings");
    let fixp = common_rules();
    fixp += "PHASE: fix verified gaps from review. Findings JSON:\n";
    fixp += json_encode(findings);
    fixp += "\nFix real bugs and secret leaks. Skip nits that fight the locked design. Re-run bunx tsc --noEmit and bun test. Commit as fix(desktop): address review findings\n";
    let fixed = agent(fixp, #{
        label: "fix-findings",
        capability_mode: "all",
        output_schema: result_schema,
    });
    if fixed == () || !fixed.success {
        log("fix agent failed; continuing to PR agent to report status");
    }
} else {
    log("No review findings to fix");
}

let verify_ok = verified != () && verified.success && verified.output != () && verified.output.ok == true;

phase("Pull request");
let prp = common_rules();
prp += "PHASE: open the GitHub PR. Current branch must be feat/linux-desktop-shell. ";
prp += "Commit any leftover tracked work in focused conventional commits. Do not commit secrets, dist binaries, target/, node_modules. ";
prp += "Rebase is unnecessary. Push origin feat/linux-desktop-shell. ";
prp += "Create a PR into main with gh pr create. Title like: feat: Linux desktop shell and relay clipboard hang fix. ";
prp += "Body must describe: hang fix (5s kill, mutex, watch try/catch, ack not waiting on wl-copy); loopback control plane; Tauri tray; packages; glossary/ADRs 0018-0021. ";
prp += "No AI attribution. If tests are red, still open the PR and say so in the body, but prefer green. ";
prp += "summary must include the PR URL. ok=true only if the PR exists.\n";
if !verify_ok {
    prp += "NOTE: verify reported failure. Still open the PR if the branch has the work, and list blockers in the PR body.\n";
}
let pr = agent(prp, #{
    label: "open-pr",
    capability_mode: "all",
    output_schema: result_schema,
});

let pr_ok = pr != () && pr.success && pr.output != () && pr.output.ok == true;
let pr_summary = "";
if pr != () && pr.success && pr.output != () && pr.output.summary != () {
    pr_summary = pr.output.summary;
}

let report = "# Linux desktop shell workflow\n\n";
report += "PR: ";
report += pr_summary;
report += "\nVerify ok: ";
report += verify_ok.to_string();
report += "\nFindings fixed from: ";
report += findings.len().to_string();
report += "\n";
let path = write_scratch_file("report.md", report);
complete(#{
    path: path,
    pr_ok: pr_ok,
    verify_ok: verify_ok,
    summary: pr_summary,
});
