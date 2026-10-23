import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { mkdir, mkdtemp, rm, symlink, writeFile } from "node:fs/promises";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";
import { SharedFolders, validateFolder } from "../src/relay/shared-folders";

let dir: string;

beforeEach(async () => {
  dir = await mkdtemp(join(tmpdir(), "vidyut-shared-"));
  await mkdir(join(dir, "Pictures"));
  await mkdir(join(dir, "Trips"));
  await writeFile(join(dir, "note.txt"), "x");
});

afterEach(async () => {
  await rm(dir, { recursive: true, force: true });
});

function make(initial: string[] = []) {
  const applied: string[][] = [];
  const saved: string[][] = [];
  const folders = new SharedFolders(
    initial,
    (next) => applied.push(next),
    async (next) => void saved.push(next),
  );
  return { folders, applied, saved };
}

describe("shared folders", () => {
  test("adds a folder, applies it at once and saves it", async () => {
    const { folders, applied, saved } = make();
    const real = await validateFolder(join(dir, "Pictures"));

    const list = await folders.add(join(dir, "Pictures"));

    expect(list).toEqual([{ path: real, exists: true }]);
    expect(applied).toEqual([[real]]);
    expect(saved).toEqual([[real]]);
  });

  test("removes a folder and keeps the others", async () => {
    const pictures = join(dir, "Pictures");
    const trips = join(dir, "Trips");
    const { folders, applied } = make([pictures, trips]);

    const list = await folders.remove(pictures);

    expect(list.map((folder) => folder.path)).toEqual([trips]);
    expect(applied).toEqual([[trips]]);
  });

  test("reports a folder that has gone missing instead of dropping it", async () => {
    const { folders } = make([join(dir, "Pictures"), join(dir, "gone")]);

    expect(await folders.list()).toEqual([
      { path: join(dir, "Pictures"), exists: true },
      { path: join(dir, "gone"), exists: false },
    ]);
  });

  test("refuses a duplicate, an unknown removal, and keeps state when saving fails", async () => {
    const pictures = join(dir, "Pictures");
    const { folders } = make([pictures]);
    await expect(folders.add(pictures)).rejects.toThrow("already shared");
    await expect(folders.remove(join(dir, "Trips"))).rejects.toThrow("not shared");

    const applied: string[][] = [];
    const failing = new SharedFolders(
      [],
      (next) => applied.push(next),
      async () => {
        throw new Error("disk full");
      },
    );
    await expect(failing.add(pictures)).rejects.toThrow("disk full");
    expect(applied).toEqual([]);
    expect(await failing.list()).toEqual([]);
  });

  test("validates the path a person typed", async () => {
    expect(await validateFolder(`  ${join(dir, "Pictures")}/  `)).toBe(
      await validateFolder(join(dir, "Pictures")),
    );
    await expect(validateFolder("")).rejects.toThrow("full path");
    await expect(validateFolder("Pictures")).rejects.toThrow("full path");
    await expect(validateFolder(join(dir, "missing"))).rejects.toThrow("does not exist");
    await expect(validateFolder(join(dir, "note.txt"))).rejects.toThrow("does not exist");
    await expect(validateFolder("/")).rejects.toThrow("whole disk");
    expect(await validateFolder("~")).toBe(await validateFolder(homedir()));
  });

  test("shares where a link points, not the link", async () => {
    await symlink(join(dir, "Trips"), join(dir, "alias"));

    expect(await validateFolder(join(dir, "alias"))).toBe(
      await validateFolder(join(dir, "Trips")),
    );
  });
});
