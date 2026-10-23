/**
 * The desktop shell's stylesheet and script are imported with Bun's `text`
 * loader, which hands over the file's contents rather than a module.
 */
declare module "*.css" {
  const text: string;
  export default text;
}
