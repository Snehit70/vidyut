import { realpath, stat } from "node:fs/promises";
import { homedir } from "node:os";
import { isAbsolute, join, resolve, sep } from "node:path";
import type { SharedFolderControl, SharedFolderInfo } from "./control-plane";

/**
 * The shared folders (ADR 0026) while the Relay runs. Edits from the desktop
 * shell land in the browser at once and in `relay.json` for the next start.
 */
export class SharedFolders implements SharedFolderControl {
  private folders: string[];

  constructor(
    initial: readonly string[],
    private readonly apply: (folders: string[]) => void,
    private readonly persist: (folders: string[]) => Promise<void>,
  ) {
    this.folders = [...initial];
  }

  async list(): Promise<SharedFolderInfo[]> {
    return Promise.all(
      this.folders.map(async (path) => ({
        path,
        exists: (await stat(path).catch(() => undefined))?.isDirectory() === true,
      })),
    );
  }

  async add(input: string): Promise<SharedFolderInfo[]> {
    const path = await validateFolder(input);
    if (this.folders.includes(path)) {
      throw new Error("That folder is already shared.");
    }
    return this.change([...this.folders, path]);
  }

  async remove(input: string): Promise<SharedFolderInfo[]> {
    if (!this.folders.includes(input)) {
      throw new Error("That folder is not shared.");
    }
    return this.change(this.folders.filter((folder) => folder !== input));
  }

  private async change(next: string[]): Promise<SharedFolderInfo[]> {
    await this.persist(next);
    this.folders = next;
    this.apply(next);
    return this.list();
  }
}

/** An existing folder, as the absolute real path that gets shared. */
export async function validateFolder(input: string): Promise<string> {
  const typed = input.trim();
  const expanded =
    typed === "~" ? homedir() : typed.startsWith(`~${sep}`) ? join(homedir(), typed.slice(2)) : typed;
  if (!isAbsolute(expanded)) {
    throw new Error("Use a full path, like /home/you/Pictures or ~/Pictures.");
  }
  const path = resolve(expanded);
  let real: string;
  try {
    real = await realpath(path);
    if (!(await stat(real)).isDirectory()) throw new Error();
  } catch {
    throw new Error("That folder does not exist.");
  }
  if (real === sep) {
    throw new Error("Sharing the whole disk is not allowed.");
  }
  return real;
}
