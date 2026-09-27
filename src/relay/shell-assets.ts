/**
 * Desktop shell assets that must be available with no network.
 *
 * The shell used to pull Manrope and the Material icon font from Google Fonts.
 * That made a LAN-only product depend on the public internet to draw its own
 * interface, and offline the icon font fell back to rendering the ligature
 * names ("link_off", "check_circle") as body text. ADR 0011 requires Manrope to
 * be locally packaged. Icons are now inline SVG paths taken from the same
 * Material set the Android app renders through Flutter's bundled font.
 */

/** Manrope variable font, inlined into the compiled Relay at build time. */
import manropeUrl from "../../app/assets/fonts/Manrope[wght].ttf" with {
  type: "file",
};

export const manropeFontUrl: string = manropeUrl;

export const manropeFontBytes = (): Promise<ArrayBuffer> =>
  Bun.file(manropeFontUrl).arrayBuffer();

/**
 * 24x24 path data for the glyphs the shell renders. Keep this list to what the
 * surface actually draws; each entry is a real Material Design Icons path, so
 * the shell and the phone show the same shapes for the same meaning.
 */
export const SHELL_ICON_PATHS = {
  /** Ready. The phone's paired home uses Icons.sync_outlined. */
  sync:
    "M12 4V1L8 5l4 4V6c3.31 0 6 2.69 6 6c0 1.01-.25 1.97-.7 2.8l1.46 1.46A7.93 7.93 0 0 0 20 12c0-4.42-3.58-8-8-8m0 14c-3.31 0-6-2.69-6-6c0-1.01.25-1.97.7-2.8L5.24 7.74A7.93 7.93 0 0 0 4 12c0 4.42 3.58 8 8 8v3l4-4l-4-4z",
  /** Sync needs attention. The phone uses Icons.sync_problem_outlined. */
  syncProblem:
    "M3 12c0 2.21.91 4.2 2.36 5.64L3 20h6v-6l-2.24 2.24A6 6 0 0 1 5 12a5.99 5.99 0 0 1 4-5.65V4.26C5.55 5.15 3 8.27 3 12m8 5h2v-2h-2zM21 4h-6v6l2.24-2.24A6 6 0 0 1 19 12a5.99 5.99 0 0 1-4 5.65v2.09c3.45-.89 6-4.01 6-7.74c0-2.21-.91-4.2-2.36-5.64zm-10 9h2V7h-2z",
  /** Relay down. The phone uses Icons.cloud_off_outlined for Offline. */
  cloudOff:
    "M24 15c0-2.64-2.05-4.78-4.65-4.96A7.49 7.49 0 0 0 12 4c-1.33 0-2.57.36-3.65.97l1.49 1.49C10.51 6.17 11.23 6 12 6c3.04 0 5.5 2.46 5.5 5.5v.5H19a2.996 2.996 0 0 1 1.79 5.4l1.41 1.41c1.09-.92 1.8-2.27 1.8-3.81M4.41 3.86L3 5.27l2.77 2.77h-.42A5.994 5.994 0 0 0 0 14c0 3.31 2.69 6 6 6h11.73l2 2l1.41-1.41zM6 18c-2.21 0-4-1.79-4-4s1.79-4 4-4h1.73l8 8z",
  /** A setup row is healthy. The phone uses Icons.check_circle. */
  checkCircle:
    "M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10s10-4.48 10-10S17.52 2 12 2m-2 15l-5-5l1.41-1.41L10 14.17l7.59-7.59L19 8z",
  /** A setup row needs recovery. The phone uses Icons.warning_amber_rounded. */
  warningAmber:
    "M12 5.99L19.53 19H4.47zM2.74 18c-.77 1.33.19 3 1.73 3h15.06c1.54 0 2.5-1.67 1.73-3L13.73 4.99c-.77-1.33-2.69-1.33-3.46 0zM11 11v2c0 .55.45 1 1 1s1-.45 1-1v-2c0-.55-.45-1-1-1s-1 .45-1 1m0 5h2v2h-2z",
  /** Send files, and the Files nav destination. The phone's Send files is a
   * FilledButton.icon with a folder. */
  folderOpen:
    "M20 6h-8l-2-2H4c-1.1 0-1.99.9-1.99 2L2 18c0 1.1.9 2 2 2h16c1.1 0 2-.9 2-2V8c0-1.1-.9-2-2-2m0 12H4V8h16z",
  /** Pairing nav destination. */
  qrCode:
    "M15 21h-2v-2h2zm-2-7h-2v5h2zm8-2h-2v4h2zm-2-2h-2v2h2zM7 12H5v2h2zm-2-2H3v2h2zm7-5h2V3h-2zm-7.5-.5v3h3v-3zM9 9H3V3h6zm-4.5 7.5v3h3v-3zM9 21H3v-6h6zm7.5-16.5v3h3v-3zM21 9h-6V3h6zm-2 10v-3h-4v2h2v3h4v-2zm-2-7h-4v2h4zm-4-2H7v2h2v2h2v-2h2zm1-1V7h-2V5h-2v4zM6.75 5.25h-1.5v1.5h1.5zm0 12h-1.5v1.5h1.5zm12-12h-1.5v1.5h1.5z",
  /** Laptop setup status nav destination. */
  tune:
    "M3 17v2h6v-2H3zM3 5v2h10V5H3zm10 16v-2h8v-2h-8v-2h-2v6h2zM7 9v2H3v2h4v2h2V9H7zm14 4v-2H11v2h10zm-6-4h2V7h4V5h-4V3h-2v6z",
  /** Relay nav destination. */
  dns:
    "M19 15v4H5v-4zm1-2H4c-.55 0-1 .45-1 1v6c0 .55.45 1 1 1h16c.55 0 1-.45 1-1v-6c0-.55-.45-1-1-1M7 18.5c-.82 0-1.5-.67-1.5-1.5s.68-1.5 1.5-1.5s1.5.67 1.5 1.5s-.67 1.5-1.5 1.5M19 5v4H5V5zm1-2H4c-.55 0-1 .45-1 1v6c0 .55.45 1 1 1h16c.55 0 1-.45 1-1V4c0-.55-.45-1-1-1M7 8.5c-.82 0-1.5-.67-1.5-1.5S6.18 5.5 7 5.5s1.5.68 1.5 1.5S7.83 8.5 7 8.5",
  /** Filled status dot in the header bar. */
  dot: "M12 2C6.47 2 2 6.47 2 12s4.47 10 10 10s10-4.47 10-10S17.53 2 12 2",
} as const satisfies Record<string, string>;

export type ShellIconName = keyof typeof SHELL_ICON_PATHS;
