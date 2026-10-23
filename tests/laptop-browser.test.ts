import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { mkdir, mkdtemp, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  answerBrowse,
  BrowseError,
  LaptopBrowser,
} from "../src/transfer/laptop-browser";
import { isBrowseRequest } from "../src/shared/wire";
import { LaptopThumbnailer } from "../src/transfer/laptop-thumbnails";
import type { LaptopFileEntry } from "../src/transfer/transfer-coordinator";

let dir: string;
let downloads: string;
let outside: string;

beforeEach(async () => {
  dir = await mkdtemp(join(tmpdir(), "vidyut-browse-"));
  downloads = join(dir, "Downloads");
  outside = join(dir, "outside");
  await mkdir(join(downloads, "Trip", "Day 1"), { recursive: true });
  await mkdir(join(downloads, ".secret"), { recursive: true });
  await mkdir(outside);
  await writeFile(join(downloads, "report.pdf"), "pdf");
  await writeFile(join(downloads, "b.txt"), "b");
  await writeFile(join(downloads, ".hidden"), "x");
  await writeFile(join(downloads, ".secret", "key"), "x");
  await writeFile(join(downloads, "Trip", "a.jpg"), "aa");
  await writeFile(join(downloads, "Trip", "Day 1", "b.jpg"), "bbb");
  await writeFile(join(downloads, "Trip", ".DS_Store"), "x");
  await writeFile(join(outside, "private.txt"), "private");
  await symlink(outside, join(downloads, "escape"));
  await symlink(join(outside, "private.txt"), join(downloads, "Trip", "link.txt"));
});

afterEach(async () => {
  await rm(dir, { recursive: true, force: true });
});

async function code(promise: Promise<unknown>): Promise<string | undefined> {
  try {
    await promise;
    return undefined;
  } catch (error) {
    return error instanceof BrowseError ? error.code : String(error);
  }
}

describe("laptop browser", () => {
  test("lists only shared folders that exist, with distinct names", async () => {
    await mkdir(join(dir, "other", "Downloads"), { recursive: true });
    const browser = new LaptopBrowser({
      folders: [downloads, join(dir, "missing"), join(dir, "other", "Downloads")],
    });

    expect(await browser.roots()).toEqual([
      { id: "0", name: "Downloads" },
      { id: "2", name: "Downloads (2)" },
    ]);
  });

  test("lists folders first and leaves out hidden entries and symlinks", async () => {
    const browser = new LaptopBrowser({ folders: [downloads] });

    const { entries, truncated } = await browser.list("0");

    expect(truncated).toBe(false);
    expect(entries.map((entry) => [entry.name, entry.kind, entry.size])).toEqual([
      ["Trip", "folder", undefined],
      ["b.txt", "file", 1],
      ["report.pdf", "file", 3],
    ]);
    expect((await browser.list("0", "Trip")).entries.map((entry) => entry.name)).toEqual([
      "Day 1",
      "a.jpg",
    ]);
  });

  test("caps a listing and says it was cut short", async () => {
    const browser = new LaptopBrowser({ folders: [downloads], maxEntries: 2 });

    const { entries, truncated } = await browser.list("0");

    expect(entries).toHaveLength(2);
    expect(truncated).toBe(true);
  });

  test("refuses paths that climb out, name hidden entries, or leave through a symlink", async () => {
    const browser = new LaptopBrowser({ folders: [downloads] });

    expect(await code(browser.list("0", ".."))).toBe("invalid_path");
    expect(await code(browser.list("0", "Trip/../.."))).toBe("invalid_path");
    expect(await code(browser.list("0", "/etc"))).toBe("invalid_path");
    expect(await code(browser.list("0", ".secret"))).toBe("invalid_path");
    expect(await code(browser.list("0", "escape"))).toBe("invalid_path");
    expect(await code(browser.collect("0", ["Trip/link.txt"]))).toBe("invalid_path");
    expect(await code(browser.list("1"))).toBe("root_not_found");
    expect(await code(browser.list("0", "gone"))).toBe("not_found");
    expect(await code(browser.list("0", "report.pdf"))).toBe("not_a_folder");
  });

  test("collects a folder's files with their subfolders, named from the folder down", async () => {
    const browser = new LaptopBrowser({ folders: [downloads] });

    const files = await browser.collect("0", ["Trip", "report.pdf", "Trip/a.jpg"]);

    expect(sorted(files)).toEqual(
      sorted([
        { path: join(downloads, "Trip", "Day 1", "b.jpg"), folder: "Trip/Day 1" },
        { path: join(downloads, "Trip", "a.jpg"), folder: "Trip" },
        { path: join(downloads, "report.pdf") },
      ]),
    );
  });

  test("pulls a whole shared folder under its own name", async () => {
    const browser = new LaptopBrowser({ folders: [downloads] });

    const files = await browser.collect("0", [""]);

    expect(files.map((file) => file.folder).sort()).toEqual([
      "Downloads",
      "Downloads",
      "Downloads/Trip",
      "Downloads/Trip/Day 1",
    ]);
  });

  test("caps the number of files in one pull", async () => {
    const browser = new LaptopBrowser({ folders: [downloads], maxPullFiles: 2 });

    expect(await code(browser.collect("0", [""]))).toBe("too_many_files");
  });

  test("answers a pull with what was queued, and a refusal as a failed answer", async () => {
    const browser = new LaptopBrowser({ folders: [downloads] });
    const queued: LaptopFileEntry[][] = [];
    const enqueue = (entries: LaptopFileEntry[]) => {
      queued.push(entries);
    };

    expect(
      await answerBrowse(
        { v: 1, kind: "browse_pull", requestId: "browse-request-0001", root: "0", paths: ["Trip"] },
        browser,
        enqueue,
      ),
    ).toEqual({ ok: true, queued: { files: 2, bytes: 5 } });
    expect(queued).toHaveLength(1);

    expect(
      await answerBrowse(
        { v: 1, kind: "browse_list", requestId: "browse-request-0002", root: "0", path: ".." },
        browser,
        enqueue,
      ),
    ).toEqual({ ok: false, code: "invalid_path", message: "That path cannot be shared." });
  });

  test("refuses a pull holding a file larger than the phone accepts, before queueing", async () => {
    const browser = new LaptopBrowser({ folders: [downloads] });
    const queued: LaptopFileEntry[][] = [];

    expect(
      await answerBrowse(
        { v: 1, kind: "browse_pull", requestId: "browse-request-0003", root: "0", paths: ["b.txt", "report.pdf"] },
        browser,
        (entries) => queued.push(entries),
        2,
      ),
    ).toEqual({
      ok: false,
      code: "file_too_large",
      message: "report.pdf is larger than the phone accepts.",
    });
    expect(queued).toEqual([]);
  });
});

describe("laptop browser folder changes", () => {
  test("shares a folder added while running and stops sharing one removed", async () => {
    const browser = new LaptopBrowser({ folders: [downloads] });
    expect((await browser.roots()).map((root) => root.name)).toEqual(["Downloads"]);

    browser.setFolders([downloads, outside]);
    expect((await browser.roots()).map((root) => root.name)).toEqual(["Downloads", "outside"]);
    expect((await browser.list("1", "")).entries.map((entry) => entry.name)).toEqual([
      "private.txt",
    ]);

    browser.setFolders([]);
    expect(await browser.roots()).toEqual([]);
    expect(await code(browser.list("0", ""))).toBe("root_not_found");
  });
});

describe("laptop browser search and thumbnails", () => {
  const request = (fields: Record<string, unknown>) =>
    ({ v: 1, requestId: "browse-request-0009", ...fields }) as never;

  test("refuses a link to a hidden file inside the share", async () => {
    await symlink(join(downloads, ".secret", "key"), join(downloads, "Trip", "innocent.txt"));
    const browser = new LaptopBrowser({ folders: [downloads] });

    expect(await code(browser.collect("0", ["Trip/innocent.txt"]))).toBe("invalid_path");
    expect(await code(browser.thumbnail("0", "Trip/innocent.txt", "small"))).toBe("invalid_path");
  });

  test("finds names across the shared folders, shallow matches first", async () => {
    const browser = new LaptopBrowser({ folders: [downloads] });

    const { matches, truncated } = await browser.search("JPG");

    expect(truncated).toBe(false);
    expect(matches.map((match) => [match.root, match.path, match.kind, match.size])).toEqual([
      ["0", "Trip/a.jpg", "file", 2],
      ["0", "Trip/Day 1/b.jpg", "file", 3],
    ]);
  });

  test("needs every word, finds folders, and stays inside one folder when asked", async () => {
    const browser = new LaptopBrowser({ folders: [downloads] });

    expect((await browser.search("day trip")).matches).toEqual([]);
    expect((await browser.search("day 1")).matches.map((match) => [match.path, match.kind])).toEqual([
      ["Trip/Day 1", "folder"],
    ]);
    expect((await browser.search("b", "0", "Trip")).matches.map((match) => match.path)).toEqual([
      "Trip/Day 1/b.jpg",
    ]);
  });

  test("never matches hidden entries, links or what lies behind them", async () => {
    const browser = new LaptopBrowser({ folders: [downloads] });

    for (const query of ["secret", "key", "private", "link", "escape", "hidden", "DS_Store"]) {
      expect((await browser.search(query)).matches).toEqual([]);
    }
  });

  test("stops at its limits and says the answer is partial", async () => {
    const browser = new LaptopBrowser({ folders: [downloads], maxSearchMatches: 1 });
    expect(await browser.search("jpg")).toMatchObject({ truncated: true });
    expect((await browser.search("jpg")).matches).toHaveLength(1);

    const visited = new LaptopBrowser({ folders: [downloads], maxSearchVisited: 2 });
    expect((await visited.search("zzz")).truncated).toBe(true);
  });

  test("answers a thumbnail with base64 bytes, and a file with none as a failed answer", async () => {
    const png = Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47]), Buffer.alloc(8, 7)]);
    const thumbnailer = new LaptopThumbnailer({
      cacheDir: join(dir, "no-cache"),
      run: async (_command, args) => {
        await writeFile(args.at(-1)!, png);
      },
    });
    const browser = new LaptopBrowser({ folders: [downloads], thumbnailer });
    const enqueue = () => {};

    expect(
      await answerBrowse(request({ kind: "browse_thumb", root: "0", path: "Trip/a.jpg" }), browser, enqueue),
    ).toEqual({ ok: true, thumb: { mime: "image/png", data: png.toString("base64") } });
    expect(
      await answerBrowse(request({ kind: "browse_thumb", root: "0", path: "b.txt" }), browser, enqueue),
    ).toMatchObject({ ok: false, code: "no_thumbnail" });
    expect(
      await answerBrowse(request({ kind: "browse_thumb", root: "0", path: "Trip" }), browser, enqueue),
    ).toMatchObject({ ok: false, code: "not_a_file" });
  });

  test("answers a search and a bad search path", async () => {
    const browser = new LaptopBrowser({ folders: [downloads] });
    const enqueue = () => {};

    expect(
      await answerBrowse(request({ kind: "browse_search", query: "report" }), browser, enqueue),
    ).toEqual({
      ok: true,
      matches: [
        expect.objectContaining({ root: "0", path: "report.pdf", name: "report.pdf", kind: "file", size: 3 }),
      ],
    });
    expect(
      await answerBrowse(
        request({ kind: "browse_search", query: "report", root: "0", path: "../.." }),
        browser,
        enqueue,
      ),
    ).toMatchObject({ ok: false, code: "invalid_path" });
  });

  test("validates thumbnail and search requests", () => {
    expect(isBrowseRequest(request({ kind: "browse_thumb", root: "0", path: "a.jpg" }))).toBe(true);
    expect(isBrowseRequest(request({ kind: "browse_thumb", root: "0", path: "a.jpg", size: "large" }))).toBe(true);
    expect(isBrowseRequest(request({ kind: "browse_thumb", root: "0", path: "a.jpg", size: "huge" }))).toBe(false);
    expect(isBrowseRequest(request({ kind: "browse_thumb", root: "0", path: "" }))).toBe(false);
    expect(isBrowseRequest(request({ kind: "browse_search", query: "trip" }))).toBe(true);
    expect(isBrowseRequest(request({ kind: "browse_search", query: "trip", root: "0", path: "A" }))).toBe(true);
    expect(isBrowseRequest(request({ kind: "browse_search", query: "t" }))).toBe(false);
    expect(isBrowseRequest(request({ kind: "browse_search", query: "  " }))).toBe(false);
    expect(isBrowseRequest(request({ kind: "browse_search", query: "x".repeat(101) }))).toBe(false);
    expect(isBrowseRequest(request({ kind: "browse_search", query: "trip", path: "A" }))).toBe(false);
  });
});

function sorted(entries: LaptopFileEntry[]): LaptopFileEntry[] {
  return [...entries].sort((a, b) => a.path.localeCompare(b.path));
}
