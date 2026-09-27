/**
 * Bun's `file` import loader inlines an asset as a path into the compiled
 * bundle, so the Relay ships Manrope inside its own binary. The desktop shell
 * must render with no font CDN (ADR 0011).
 */
declare module "*.ttf" {
  const url: string;
  export default url;
}
