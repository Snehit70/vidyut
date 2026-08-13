---
name: Vidyut
description: A quiet, precise Android utility for moving clipboard content and files between a phone and laptop.
colors:
  primary: "#D9486E"
  primary-container: "#F8D3DE"
  surface: "#FFFFFF"
  surface-container-low: "#FDF0F4"
  on-surface: "#33202B"
  on-surface-variant: "#8F717E"
  outline: "#E9CBD5"
  error: "#B3283E"
  success: "#2D8A4A"
  warning: "#A05A00"
  dark-surface: "#171116"
  dark-surface-container-low: "#241A20"
  dark-on-surface: "#F8EAF0"
  dark-on-surface-variant: "#D4B8C4"
  dark-primary: "#FFB1C3"
  dark-primary-container: "#8F2949"
typography:
  display:
    fontFamily: "Manrope, sans-serif"
    fontSize: "28sp"
    fontWeight: 700
    lineHeight: 1.2
    letterSpacing: "-0.02em"
  headline:
    fontFamily: "Manrope, sans-serif"
    fontSize: "24sp"
    fontWeight: 700
    lineHeight: 1.25
    letterSpacing: "-0.02em"
  title:
    fontFamily: "Manrope, sans-serif"
    fontSize: "18sp"
    fontWeight: 700
    lineHeight: 1.35
  body:
    fontFamily: "Manrope, sans-serif"
    fontSize: "14sp"
    fontWeight: 500
    lineHeight: 1.45
  label:
    fontFamily: "Manrope, sans-serif"
    fontSize: "12sp"
    fontWeight: 600
    lineHeight: 1.35
rounded:
  xs: "4dp"
  sm: "8dp"
  md: "12dp"
  lg: "16dp"
  pill: "999dp"
spacing:
  xs: "4dp"
  sm: "8dp"
  md: "12dp"
  lg: "16dp"
  xl: "24dp"
  xxl: "32dp"
components:
  button-primary:
    backgroundColor: "{colors.primary}"
    textColor: "#FFFFFF"
    rounded: "{rounded.md}"
    padding: "12dp 20dp"
    height: "48dp"
  surface-card:
    backgroundColor: "{colors.surface-container-low}"
    textColor: "{colors.on-surface}"
    rounded: "{rounded.lg}"
    padding: "16dp"
  list-row:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.on-surface}"
    rounded: "{rounded.sm}"
    padding: "12dp 0dp"

---

# Design System: Vidyut

## Overview

**Creative North Star: "The Quiet Bridge"**

Vidyut should feel like a dependable local connection that disappears into the
user's workflow. The interface is calm and precise: it communicates whether
automatic clipboard synchronization is ready, makes manual file sending easy,
and exposes recovery without turning a background utility into a dashboard
full of controls.

The current raspberry identity is retained but disciplined. Brand expression
comes through semantic color, Manrope typography, restrained squircle
geometry, and deliberate state motion. Material 3 governs Android structure,
navigation, touch behavior, and system integration.

**Key Characteristics:**

- Operational clarity before decoration.
- Geometric softness rather than inflated roundness.
- Tonal surfaces rather than card piles and shadows.
- State communication through label, icon, and supporting copy—not color alone.
- One shared system for every screen and future contribution.

## Colors

The palette is raspberry on warm white with plum ink. Raspberry is a focused
action and state accent, not a background wash. All implementation should use
semantic Material color roles so light and dark schemes remain coherent.

### Primary

- **Raspberry** (`#D9486E`): primary actions, active navigation, focused
  controls, and positive brand emphasis.
- **Petal** (`#F8D3DE`): primary-container tone for selected or emphasized
  surfaces; never use it as a substitute for every card background.

### Neutral

- **White** (`#FFFFFF`): light app background and elevated content ground.
- **Mist** (`#FDF0F4`): low tonal surface for grouped content and cards.
- **Plum ink** (`#33202B`): primary text and high-contrast icons.
- **Muted plum** (`#8F717E`): supporting text and low-priority metadata.
- **Petal outline** (`#E9CBD5`): restrained dividers and field outlines.

### Semantic states

- **Error** (`#B3283E`): failed, blocked, or destructive outcomes.
- **Success** (`#2D8A4A`): completed and healthy outcomes, paired with text or
  an icon.
- **Warning** (`#A05A00`): degraded or attention-required states when the
  situation is not a hard failure.

### Dark scheme

Dark mode is a first-class static scheme using deep plum surfaces, light warm
text, and a lighter raspberry primary. Android Dynamic Color is deferred until
the branded light and dark schemes are stable.

**The Signal Clarity Rule.** Never communicate an important state through color
alone. Pair color with a state label, meaningful icon, and useful next action.

## Typography

**Display Font:** Manrope (locally packaged, with a sans-serif fallback)

**Body Font:** Manrope (locally packaged, with a sans-serif fallback)

**Character:** Geometric, contemporary, and friendly without becoming
playful. Manrope is the only product typeface; Roboto remains the Android
reference for scale and hierarchy, not a second font family.

### Hierarchy

- **Display** (700, 28sp, 1.2): the primary status or screen statement; use
  sparingly.
- **Headline** (700, 24sp, 1.25): major surface titles and onboarding steps.
- **Title** (700, 18sp, 1.35): section titles, card titles, and important state
  labels.
- **Body** (500, 14sp, 1.45): explanations, metadata, and operational copy.
- **Label** (600, 12sp, 1.35): buttons, compact statuses, filters, and section
  labels.

**The One Family Rule.** Do not introduce a second type family for contrast.
Use weight, size, color role, and spacing to establish hierarchy.

## Layout

Use a 4dp spacing base with the shared rhythm `4 / 8 / 12 / 16 / 24 / 32dp`.
Compact phone screens use 16dp horizontal margins and moderate vertical
density. Keep at least 8dp between adjacent targets and 48dp minimum touch
targets.

Home order is fixed: automatic sync status, **Send files**, and latest
activity. Files is a first-class route from the app bar and the Home action;
phones do not use a persistent bottom navigation bar. Settings remains a
secondary route. Settings is one continuous scroll surface organized as
grouped list sections: Appearance, Connection, Clipboard & screenshots, Files,
Notifications, Troubleshooting, About, and Danger zone. Use one tonal group
container with internal dividers where helpful; do not stack an independent
Card around every setting.

On expanded Android widths, adapt to a compact Material navigation rail with
Home and Files destinations. Do not stretch a phone layout across a tablet;
recompose the shell while keeping the same hierarchy and components.

Respect system insets, predictive Back, keyboard/IME space, Android text
scaling, and reduced-motion settings.

## Motion

Motion is operational feedback, not decoration. Use Material route transitions,
100–150ms press feedback, and 150–300ms state transitions for connection,
transfer, completion, and theme changes. Searching and active progress may use
bounded loops. Long scrollable surfaces render immediately; do not stagger
their rows into visibility. Honor Android reduced motion by replacing movement
with instant or short opacity/color feedback while keeping state changes clear.

Async settings values reserve their row from the first frame and show a compact
loading or unavailable state inline. A screen must never look empty because a
staggered entrance animation is still running.

## Elevation & Depth

The system is flat-by-default and uses tonal layering as its primary depth
cue. A surface should become distinct through background role, spacing, and
typography before adding a shadow. Use standard Material elevation for dialogs,
bottom sheets, and genuinely floating controls only.

**The Tonal Depth Rule.** Do not add a shadow to make a repeated card pattern
feel finished. First ask whether the grouping, spacing, and surface role are
correct.

## Shapes

The form language is geometric softness: squircle-like corners with a short,
deliberate radius scale. Use 16dp for primary containers, 12dp for controls and
cards, 8dp for compact rows, and pills only for filters, badges, and compact
selection states. Avoid large 20–24dp radii as the default for every surface.

Borders are quiet and purposeful. Prefer tonal separation; use an outline for
inputs, selected boundaries, and separators that need explicit affordance.

## Components

### Buttons

- **Shape:** 12dp squircle, 48dp minimum height.
- **Primary:** Raspberry fill, white label, 12dp vertical and 20dp horizontal
  padding.
- **Secondary:** tonal or outlined Material button; never compete with the
  primary action through equal color weight.
- **Focus / pressed:** visible Material state layer; reduced-motion users get
  the same state change without scale animation.

### Chips

- **Style:** pill shape only for filters, compact status, and selection.
- **State:** selected uses the primary-container role and a clear label/icon;
  unselected uses a neutral surface or outline.

### Cards / containers

- **Corner style:** 16dp for primary grouped containers, 12dp for smaller
  cards, 8dp for dense rows.
- **Background:** semantic tonal surfaces, not arbitrary per-screen colors.
- **Shadow strategy:** flat or tonal at rest; standard Material depth only when
  the container floats.
- **Internal padding:** normally 16dp; dense rows use 12dp.

### Inputs / fields

- **Style:** semantic surface fill, 12dp corners, quiet outline.
- **Focus:** primary outline/state layer with a clear focus indicator.
- **Error / disabled:** semantic error or disabled roles with explanatory
  supporting text; never rely on a red border alone.

### Navigation

- **Compact:** Home default; Files in the app bar and reachable from the Home
  primary action; Settings secondary.
- **Expanded:** Material navigation rail with Home and Files.
- **Back:** system Back and predictive Back remain authoritative.

### Status indicator

The status indicator is a restrained geometric component, not an ambient
decoration. It combines icon, label, and supporting copy for `Ready`, searching,
offline, and `Sync needs attention`. Animation is reserved for searching,
progress, connection changes, and success.

## Do's and Don'ts

### Do:

- **Do** use the shared Material roles, Manrope type ramp, spacing rhythm, and
  radius scale.
- **Do** make the actual operational state visible in text and iconography.
- **Do** keep Home focused on sync, file sending, and latest activity.
- **Do** design light and dark states together.
- **Do** honor large text, reduced motion, insets, and 48dp touch targets.
- **Do** add a new token or component contract when a genuinely new pattern is
  needed.

### Don't:

- **Don't** add a persistent phone bottom bar for only Home and Files.
- **Don't** make every piece of information a large rounded card.
- **Don't** use raw per-screen colors, radii, font sizes, or animation timings.
- **Don't** use decorative morphing blobs or looping motion as default chrome.
- **Don't** make color the only indication of success, failure, or degraded
  sync.
- **Don't** put recurring setup diagnostics on Home.
- **Don't** introduce a second typeface without an explicit design-system
  decision.

## Contribution Contract

Future UI changes must consume the shared design tokens and primitives. A new
color, radius, type step, shadow, motion behavior, or component variant requires
an intentional update to this document and the Flutter design source before it
is used in a feature. Exceptions must state why the existing system cannot
express the requirement and must include accessibility and state behavior.
