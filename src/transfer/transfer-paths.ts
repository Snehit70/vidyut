import { basename, dirname, join } from "node:path";

export function partialPathFor(
  destinationPath: string,
  fileId: string,
): string {
  return join(
    dirname(destinationPath),
    `.${basename(destinationPath)}.${fileId}.vidyut-part`,
  );
}
