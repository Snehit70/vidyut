import { lstat, readdir, realpath, stat } from "node:fs/promises";
import { basename, join, sep } from "node:path";
import type {
  BrowseAnswer,
  BrowseEntry,
  BrowseRequest,
  BrowseRoot,
} from "../shared/wire";
import type { LaptopFileEntry } from "./transfer-coordinator";

export class BrowseError extends Error {
  constructor(
    readonly code: string,
    message: string,
  ) {
    super(message);
  }
}

export interface LaptopBrowserOptions {
  /** The folders the phone may read, as absolute paths (ADR 0026). */
  folders: readonly string[];
  maxEntries?: number;
  maxPullFiles?: number;
}

const defaultMaxEntries = 2000;
const defaultMaxPullFiles = 1000;

/**
 * Read-only view of the laptop's shared folders for the phone. Paths from the
 * phone are relative to a shared folder and must stay inside it once symlinks
 * resolve. Hidden entries and symlinks are never listed or pulled, so sharing
 * the home folder does not expose `~/.ssh`.
 */
export class LaptopBrowser {
  private readonly maxEntries: number;
  private readonly maxPullFiles: number;

  constructor(private readonly options: LaptopBrowserOptions) {
    this.maxEntries = options.maxEntries ?? defaultMaxEntries;
    this.maxPullFiles = options.maxPullFiles ?? defaultMaxPullFiles;
  }

  /** Shared folders that exist right now. Ids are stable while the config is. */
  async roots(): Promise<BrowseRoot[]> {
    const roots: BrowseRoot[] = [];
    const names = new Set<string>();
    for (const [index, folder] of this.options.folders.entries()) {
      const info = await stat(folder).catch(() => undefined);
      if (!info?.isDirectory()) continue;
      let name = basename(folder) || folder;
      for (let suffix = 2; names.has(name); suffix++) {
        name = `${basename(folder) || folder} (${suffix})`;
      }
      names.add(name);
      roots.push({ id: String(index), name });
    }
    return roots;
  }

  async list(
    rootId: string,
    path = "",
  ): Promise<{ entries: BrowseEntry[]; truncated: boolean }> {
    const { target } = await this.resolve(rootId, path);
    const info = await stat(target);
    if (!info.isDirectory()) {
      throw new BrowseError("not_a_folder", "That is not a folder.");
    }
    const entries: BrowseEntry[] = [];
    let truncated = false;
    for (const dirent of await readDir(target)) {
      if (!isShareableName(dirent.name)) continue;
      if (!dirent.isFile() && !dirent.isDirectory()) continue;
      if (entries.length >= this.maxEntries) {
        truncated = true;
        break;
      }
      const entryInfo = await stat(join(target, dirent.name)).catch(
        () => undefined,
      );
      if (!entryInfo) continue;
      entries.push(
        dirent.isDirectory()
          ? {
              name: dirent.name,
              kind: "folder",
              modifiedMs: Math.trunc(entryInfo.mtimeMs),
            }
          : {
              name: dirent.name,
              kind: "file",
              size: entryInfo.size,
              modifiedMs: Math.trunc(entryInfo.mtimeMs),
            },
      );
    }
    entries.sort(
      (a, b) =>
        (a.kind === b.kind ? 0 : a.kind === "folder" ? -1 : 1) ||
        a.name.localeCompare(b.name, undefined, { sensitivity: "base" }),
    );
    return { entries, truncated };
  }

  /**
   * The files behind `paths`: a file as itself, a folder as every file under
   * it with the subfolder it sits in, named from the pulled folder down.
   */
  async collect(
    rootId: string,
    paths: readonly string[],
  ): Promise<LaptopFileEntry[]> {
    const collected: LaptopFileEntry[] = [];
    const seen = new Set<string>();
    const add = (entry: LaptopFileEntry) => {
      if (seen.has(entry.path)) return;
      if (collected.length >= this.maxPullFiles) {
        throw new BrowseError(
          "too_many_files",
          `Pull at most ${this.maxPullFiles} files at a time.`,
        );
      }
      seen.add(entry.path);
      collected.push(entry);
    };
    for (const path of paths) {
      const { target, name } = await this.resolve(rootId, path);
      const info = await lstat(target);
      if (info.isFile()) {
        add({ path: target });
      } else if (info.isDirectory()) {
        await this.walk(target, name, add);
      }
    }
    if (collected.length === 0) {
      throw new BrowseError("nothing_to_pull", "There are no files to pull.");
    }
    return collected;
  }

  private async walk(
    directory: string,
    folder: string,
    add: (entry: LaptopFileEntry) => void,
  ): Promise<void> {
    for (const dirent of await readDir(directory)) {
      if (!isShareableName(dirent.name)) continue;
      const path = join(directory, dirent.name);
      if (dirent.isFile()) {
        add({ path, folder });
      } else if (dirent.isDirectory()) {
        await this.walk(path, `${folder}/${dirent.name}`, add);
      }
    }
  }

  private async resolve(
    rootId: string,
    path: string,
  ): Promise<{ target: string; name: string }> {
    const folder = /^\d+$/.test(rootId)
      ? this.options.folders[Number(rootId)]
      : undefined;
    if (folder === undefined) {
      throw new BrowseError("root_not_found", "That shared folder is gone.");
    }
    const segments = path === "" ? [] : path.split("/");
    if (segments.some((segment) => !isShareableName(segment))) {
      throw new BrowseError("invalid_path", "That path cannot be shared.");
    }
    let root: string;
    try {
      root = await realpath(folder);
    } catch {
      throw new BrowseError("root_not_found", "That shared folder is gone.");
    }
    let target: string;
    try {
      target = await realpath(join(root, ...segments));
    } catch {
      throw new BrowseError("not_found", "That file or folder is gone.");
    }
    if (target !== root && !target.startsWith(root + sep)) {
      throw new BrowseError("invalid_path", "That path cannot be shared.");
    }
    const rootName =
      (await this.roots()).find((candidate) => candidate.id === rootId)
        ?.name ?? basename(root);
    return {
      target,
      name: segments.length === 0 ? rootName : segments.at(-1)!,
    };
  }
}

/**
 * Answers one phone request. Errors the phone should see become a failed
 * answer; anything else is the relay's problem and is rethrown. A pull is
 * answered once its files are listed and size-checked; hashing and queueing
 * them can take minutes, so [enqueue] runs after the answer, not before it.
 */
export async function answerBrowse(
  request: BrowseRequest,
  browser: LaptopBrowser,
  enqueue: (entries: LaptopFileEntry[]) => void,
  maxFileBytes = Number.POSITIVE_INFINITY,
): Promise<BrowseAnswer> {
  try {
    if (request.kind === "browse_list") {
      if (request.root === undefined) {
        return { ok: true, roots: await browser.roots() };
      }
      const { entries, truncated } = await browser.list(
        request.root,
        request.path ?? "",
      );
      return truncated
        ? { ok: true, entries, truncated: true }
        : { ok: true, entries };
    }
    const files = await browser.collect(request.root, request.paths);
    let bytes = 0;
    for (const file of files) {
      const { size } = await stat(file.path);
      if (size > maxFileBytes) {
        return {
          ok: false,
          code: "file_too_large",
          message: `${basename(file.path)} is larger than the phone accepts.`,
        };
      }
      bytes += size;
    }
    enqueue(files);
    return { ok: true, queued: { files: files.length, bytes } };
  } catch (error) {
    if (error instanceof BrowseError) {
      return { ok: false, code: error.code, message: error.message };
    }
    throw error;
  }
}

/** Names a phone may see and receive: not hidden, and valid as an offer filename. */
function isShareableName(name: string): boolean {
  return (
    name.length > 0 &&
    !name.startsWith(".") &&
    new TextEncoder().encode(name).byteLength <= 255 &&
    !/[\u0000-\u001f\u007f\\/]/u.test(name)
  );
}

async function readDir(directory: string) {
  try {
    return await readdir(directory, { withFileTypes: true });
  } catch (error) {
    if (
      error &&
      typeof error === "object" &&
      "code" in error &&
      error.code === "EACCES"
    ) {
      throw new BrowseError(
        "permission_denied",
        "The laptop cannot read that folder.",
      );
    }
    throw error;
  }
}
