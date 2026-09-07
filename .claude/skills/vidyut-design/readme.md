# Vidyut Design System

Vidyut is a **LAN-only clipboard pool** connecting a Linux/Wayland laptop and an Android phone. A Bun relay runs on the laptop (encrypted WebSocket, latest-write-wins pool, mDNS discovery, QR/manual pairing); a Flutter Android app pairs with it to sync clipboard text, screenshots, and shared images in both directions.

## Sources

- GitHub: https://github.com/Snehit70/vidyut — explore this repo to design better against the real product.
- Local folder attachment `vidyut/` (same repo). The design source of truth is `app/lib/src/design/` — `palette.dart`, `theme.dart`, `motion.dart`, `widgets.dart` — plus the screens in `app/lib/src/{onboarding,pairing,settings,foreground,debug}`.

## Products

One product surface: the **Android app** ("Vidyut"), Material 3 Flutter with a fully custom theme the code calls **"Flat Raspberry Pink"** — white grounds, flat mist/petal surfaces, 20px radii, pill buttons, Plus Jakarta Sans with weight-driven hierarchy. The laptop side is a headless CLI relay (no UI).

Screens: onboarding wizard (permission steps + pairing finale), home/pairing (status hero + nearby relays + manual pairing), settings, setup-status checklist, send-clipboard, QR scanner, debug log.

---

## CONTENT FUNDAMENTALS

- **Voice**: calm, plain-spoken, second person ("you"), first-person-plural for the app's limits ("we can't check them for you"). Sentence case everywhere — titles, buttons, list rows. No exclamation marks, no emoji.
- **Titles are short and warm-metaphorical**: "Stay in the loop", "Spot your screenshots", "Keep the link alive", "Xiaomi needs a little extra", "Almost — one change needed".
- **Body copy explains the why in one or two sentences**, then the mechanics: "Android puts idle apps to sleep, which drops the connection to your laptop."
- **Honest consequences, never nagging**: every skippable step states the cost as "If you skip: …" ("You won't see receipts when the laptop sends you things.").
- **Buttons are 1–3 words**: Allow, Skip, Continue, Done, Pair manually, Scan QR, Open settings, Reset pairing.
- **Status words are single**: Connected / Searching / Offline / Unpaired. Em-dashes and contractions used freely ("can't", "won't").
- Technical values shown plainly in muted text: `192.168.1.4:17321`, `text (1.2 MB) from laptop`.

## VISUAL FOUNDATIONS

- **Color**: two pinks on pure white with plum ink. White page (`--ground`), flat mist `#FDF0F4` cards, petal `#F8D3DE` emphasis surfaces, raspberry `#C83861` as the only strong accent, ink `#33202B` text, muted plum `#856774` secondary text, hairline `#9D878F` borders, deep `#B3283E` errors. No gradients, no imagery, no dark mode.
- **Elevation: none.** Everything is flat — zero shadows, zero surface tints. Hierarchy comes from surface color (white → mist → petal) and hairlines.
- **Type**: Plus Jakarta Sans only. Weight-driven hierarchy: 800 with tight −0.03em tracking for display/titles (26px) and app-bar (20px); 600 for section titles/labels/buttons; 500 for body. Line-height 1.3 everywhere. Muted color = secondary.
- **Radii**: 20px cards, 16px inputs/tiles, 14px app-bar icon chips, 13px list leading icons, full pill (999) for buttons, chips, snackbar, step dots.
- **Buttons**: full-width 54px-tall pills. Filled = raspberry/white; outlined = white with 1.5px petal border, raspberry text; text button = raspberry (or muted for Skip). 15px/600 labels.
- **Inputs**: mist fill, 16px radius, hairline border; focus = 1.6px raspberry border; floating label turns raspberry 12px/600; prefix icons muted.
- **Motion**: signature spring `cubic-bezier(0.34,1.56,0.64,1)`. Screen entrances rise 30px + fade over 600ms, staggered 100ms per sibling. Press = squash to 0.93 (120ms easeOutCubic down, 300ms spring up) — applied by wrapping, not color change. Ambient loops: morphing blob (10s reverse loop), pulsing dot halo (1.4s), ripple rings (2.2s ×3 rings).
- **Hero motif**: the **morphing organic blob** — a raspberry (or petal) rounded blob slowly shifting silhouette, with a white circle + raspberry icon centered inside. Used on home status, onboarding steps, success states (wrapped in ripple rings).
- **Cards**: mist fill, 20px radius, no border, no shadow, zero margin (spacing via gaps). Status/setup banners use petal.
- **Feedback**: snackbar = ink pill, white 14px/500 text, floating. Errors render inside mist boxes with an `error_outline` icon, never red fills.
- **Layout**: single column, 20px screen padding (24px onboarding), full-width stretch CTAs pinned near the bottom on wizard steps, centered heroes. No fixed bars beyond the flat white app bar (no elevation even scrolled).
- **Transparency/blur**: none. Only alpha use is motion halos/rings fading out.

## ICONOGRAPHY

- Icon set: **Material Icons** (Flutter built-in `Icons.*`), mostly outlined variants: `notifications_active`, `photo_library`, `battery_charging_full`, `bug_report`, `settings`, `link`, `link_off`, `wifi_find`, `cloud_off`, `qr_code_scanner`, `dns`, `router`, `settings_ethernet`, `key`, `refresh`, `check_circle`, `check`, `error_outline`, `warning_amber`, `chevron_right`, `tune`, `ios_share`, `delete_sweep`, `priority_high`.
- Loaded from Google Fonts CDN (`Material Icons` + `Material Icons Outlined`) in `tokens/fonts.css` — same glyphs the app renders.
- Icon coloring: raspberry on light chips (petal/mist/white circles), ink in app bars, muted for chevrons/prefixes, error for warnings. Icons almost always sit inside a rounded chip or circle, never bare next to text (except list trailing).
- No emoji, no unicode-as-icon. **Logo**: `assets/ic_launcher.png` — pink image-card spilling into a plum clipboard (the app launcher icon; the only mark in the repo).

## Index

- `styles.css` → `tokens/` (`colors.css`, `typography.css`, `spacing.css`, `motion.css`, `fonts.css`)
- `assets/ic_launcher.png` — app icon / logo
- `components/motion/` — MorphingBlob, PulsingDot, RippleRings, PressableScale, Entrance (the app's own widget library, `widgets.dart`)
- `components/core/` — Button, IconButton, TextField, Card, Switch, Snackbar, MIcon (recreations of the theme.dart-styled Material widgets + the Material icon glyph helper)
- `components/pairing/` — NearbyRelaysCard, ManualPairingForm, StatusHero, SetupBanner
- `guidelines/` — foundation specimen cards (Design System tab)
- `ui_kits/android/` — interactive recreation of the app's core screens
- `SKILL.md` — agent skill entry point

**Intentional additions**: `components/core/*` are not standalone widgets in the repo — they are the Material widgets as styled by `theme.dart` (FilledButton, OutlinedButton, TextField, Card, Switch, SnackBar), recreated so consumers can compose screens. Values copied verbatim from the theme.

**Font note**: the repo ships no font binaries (fonts come via the `google_fonts` package at runtime), so Plus Jakarta Sans is loaded from Google Fonts CDN — this is the exact family the app uses, not a substitution.
