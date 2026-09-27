# Vidyut Design System

Vidyut is a **LAN-only clipboard pool** connecting a Linux/Wayland laptop and an Android phone. A Bun relay runs on the laptop (encrypted WebSocket, latest-write-wins pool, mDNS discovery, QR/manual pairing); a Flutter Android app pairs with it to sync clipboard text, screenshots, and shared images in both directions.

## Sources

- GitHub: https://github.com/Snehit70/vidyut — explore this repo to design better against the real product.
- Local folder attachment `vidyut/` (same repo). The design source of truth is `app/lib/src/design/` — `palette.dart`, `theme.dart`, `motion.dart`, `widgets.dart` — plus the screens in `app/lib/src/{onboarding,pairing,settings,foreground,debug}`.

## Products

One product surface, two hosts: the **Android app** ("Vidyut"), Material 3 Flutter, and the **Linux desktop shell**, a Tauri window and tray around the Relay's loopback control plane. Both render the same tokens, the same status vocabulary, and the same Manrope ramp, so a state reads identically on either device.

**Token source of truth**: `design/tokens.css` at the repo root. It mirrors `app/lib/src/design/palette.dart` and `app/lib/src/design/theme.dart`, which are the reference implementation. `tests/design-tokens.test.ts` fails if the three disagree. This file and `tokens/` document that file — do not redeclare a token here.

Screens: onboarding wizard (permission steps + pairing finale), home/pairing (status panel + nearby relays + manual pairing), settings, setup-status checklist, send-clipboard, QR scanner, debug log. Desktop shell: status hero, pairing QR, send files, transfer history, laptop setup status, rotate pairing secret, relay start/stop.

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

- **Color**: two pinks on pure white with plum ink. White page (`--ground`), flat mist `#FDF0F4` cards, petal `#F8D3DE` emphasis surfaces, raspberry `#C83861` as the only strong accent, ink `#33202B` text, muted plum `#856774` secondary text, hairline `#9D878F` borders, deep `#B3283E` errors. No gradients, no imagery. **Dark mode is implemented** (`Palette.dark*`, `buildVidyutDarkTheme`, user-selectable system/light/dark) and the desktop shell follows `prefers-color-scheme`. Status colors exist and are not green-free: success `#2D8A4A`, warning `#A05A00`, active `#A85B00`, each with a pale container.
- **Elevation: none.** Everything is flat — zero shadows, zero surface tints. Hierarchy comes from surface color (white → mist → petal) and hairlines.
- **Type**: Manrope only (ADR 0011), locally packaged. Weight-driven hierarchy: 700 with tight tracking for display (28px/−0.56), headline (24px/−0.48), titles (18/16/14), and app bar (20px/−0.2); 600 for labels and buttons; 500 for body. Line-height 1.35 everywhere. Muted color = secondary.
- **Radii**: 16px cards, 12px controls (buttons, inputs, chips, snackbar), 8px list tiles. Full pill (999) only for chips and step dots — buttons and cards are rounded rectangles.
- **Buttons**: full-width 48px minimum, 12px radius. Filled = raspberry/onPrimary; outlined = transparent with a 1px hairline border and raspberry text; text button = raspberry at 48x48 minimum. 14px/600 labels. Press squashes to 0.96.
- **Inputs**: mist fill, 12px radius, hairline border; focus = 1.5px raspberry border; floating label turns raspberry 12px/600; prefix icons muted.
- **Motion**: signature spring `cubic-bezier(0.34,1.56,0.64,1)`. Entrances rise 30px + fade over 300ms, staggered 50ms per sibling, and are used only for finite flows (onboarding, setup checklist) — long scrollable surfaces such as Home, Files, Settings, Activity, and the desktop shell render immediately with no stagger (ADR 0013). Press = squash to 0.96 (100ms down, 150ms up). Ambient loop: pulsing dot halo (1.4s), gated on `Motion.loopsEnabled` and the platform reduced-motion setting.
- **Status motif**: a **52x52 rounded-12 glyph chip** whose fill is the state's container color and whose glyph is the state icon, paired with a state label and one line of plain explanation. On the phone the chip sits in a tappable 16px-radius row with a chevron; on the desktop shell it is centered in a status hero. The earlier morphing blob is retired. The unpaired phone screen still has a 96x96 rounded-16 hero box.
- **Cards**: mist fill, 20px radius, no border, no shadow, zero margin (spacing via gaps). Status/setup banners use petal.
- **Feedback**: snackbar = ink fill (darkMist in dark), 12px radius, 14px/500 text, floating. Errors render as `--error` text or an `error_outline` glyph, never a red fill.
- **Layout**: single column, 20px screen padding (24px onboarding), full-width stretch CTAs pinned near the bottom on wizard steps, centered heroes. No fixed bars beyond the flat white app bar (no elevation even scrolled).
- **Transparency/blur**: none. Only alpha use is motion halos/rings fading out.

## ICONOGRAPHY

- Icon set: **Material Icons** (Flutter built-in `Icons.*`), mostly outlined variants: `notifications_active`, `photo_library`, `battery_charging_full`, `bug_report`, `settings`, `sync`, `sync_problem`, `link`, `link_off`, `wifi_find`, `cloud_off`, `qr_code_scanner`, `dns`, `router`, `settings_ethernet`, `key`, `refresh`, `check_circle`, `check`, `error_outline`, `warning_amber`, `chevron_right`, `tune`, `ios_share`, `delete_sweep`, `priority_high`.
- The phone renders them from Flutter's bundled icon font. The desktop shell renders the same shapes as **inline SVG paths** in `src/relay/shell-assets.ts` — no icon webfont, so nothing renders as ligature text when offline.
- Icon coloring: raspberry on light chips (petal/mist/white circles), ink in app bars, muted for chevrons/prefixes, error for warnings. Icons almost always sit inside a rounded chip or circle, never bare next to text (except list trailing).
- No emoji, no unicode-as-icon. **Logo**: `app/assets/icon/icon-legacy.png` — pink image-card spilling into a plum clipboard (the app launcher icon; the only mark in the repo). The desktop shell has no in-window logo; its tray and window icon come from `src-tauri/icons/`.

## Index

- `design/tokens.css` (repo root) — **the** token source. `tokens/colors.css` imports it; `tokens/fonts.css` points at the packaged Manrope.
- `assets/ic_launcher.png` — app icon / logo
- `components/motion/` — MorphingBlob, PulsingDot, RippleRings, PressableScale, Entrance (the app's own widget library, `widgets.dart`)
- `components/core/` — Button, IconButton, TextField, Card, Switch, Snackbar, MIcon (recreations of the theme.dart-styled Material widgets + the Material icon glyph helper)
- `components/pairing/` — NearbyRelaysCard, ManualPairingForm, StatusHero, SetupBanner
- `guidelines/` — foundation specimen cards (Design System tab)
- `ui_kits/android/` — interactive recreation of the app's core screens
- `SKILL.md` — agent skill entry point

**Intentional additions**: `components/core/*` are not standalone widgets in the repo — they are the Material widgets as styled by `theme.dart` (FilledButton, OutlinedButton, TextField, Card, Switch, SnackBar), recreated so consumers can compose screens. Values copied verbatim from the theme.

**Font note**: the repo *does* ship the typeface. `app/assets/fonts/Manrope[wght].ttf` is a 165KB variable font declared in `app/pubspec.yaml` and bundled into the APK; the desktop shell serves the same file from the Relay at `/ui/manrope.ttf`. There is no `google_fonts` dependency and no font CDN anywhere in the product.
