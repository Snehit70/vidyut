import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { createHash } from "node:crypto";
import { mkdir, mkdtemp, rm, utimes, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  fileUri,
  LaptopThumbnailer,
  type RunTool,
} from "../src/transfer/laptop-thumbnails";

const png = Buffer.concat([
  Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
  Buffer.alloc(32, 1),
]);
const jpeg = Buffer.concat([Buffer.from([0xff, 0xd8, 0xff, 0xe0]), Buffer.alloc(32, 2)]);

let dir: string;
let cache: string;
let photo: string;

beforeEach(async () => {
  dir = await mkdtemp(join(tmpdir(), "vidyut-thumbs-"));
  cache = join(dir, "cache");
  photo = join(dir, "My Photo #1.jpg");
  await writeFile(photo, "not really a jpeg");
  await writeFile(join(dir, "notes.txt"), "text");
});

afterEach(async () => {
  await rm(dir, { recursive: true, force: true });
});

/** A runner that writes `bytes` where the tool was told to, and records its calls. */
function fakeTool(bytes: Buffer, calls: Array<[string, string[]]> = []): RunTool {
  return async (command, args) => {
    calls.push([command, args]);
    const output =
      command === "pdftoppm"
        ? `${args.at(-1)}.png`
        : command === "ffmpegthumbnailer"
          ? args[args.indexOf("-o") + 1]!
          : args.at(-1)!;
    await writeFile(output, bytes);
  };
}

async function cached(size: string, file: string, bytes: Buffer, age = 0) {
  await mkdir(join(cache, size), { recursive: true });
  const path = join(cache, size, `${createHash("md5").update(fileUri(file)).digest("hex")}.png`);
  await writeFile(path, bytes);
  if (age !== 0) {
    const when = new Date(Date.now() + age);
    await utimes(path, when, when);
  }
}

describe("laptop thumbnails", () => {
  test("escapes a path the way GLib does for the cache name", () => {
    expect(fileUri("/home/a b/c#d/é.jpg")).toBe("file:///home/a%20b/c%23d/%C3%A9.jpg");
    expect(fileUri("/x/a&b=c,d;e:f@g+h$i.jpg")).toBe("file:///x/a&b=c,d;e:f@g+h$i.jpg");
  });

  test("uses the desktop's cached thumbnail without running a tool", async () => {
    await cached("large", photo, png);
    const calls: Array<[string, string[]]> = [];
    const thumbnailer = new LaptopThumbnailer({ cacheDir: cache, run: fakeTool(jpeg, calls) });

    const thumb = await thumbnailer.thumbnail(photo, "small");

    expect(thumb?.mime).toBe("image/png");
    expect(thumb?.data.equals(png)).toBe(true);
    expect(calls).toEqual([]);
  });

  test("ignores a cached thumbnail older than its file", async () => {
    await cached("large", photo, png, -60_000);
    const calls: Array<[string, string[]]> = [];
    const thumbnailer = new LaptopThumbnailer({ cacheDir: cache, run: fakeTool(jpeg, calls) });

    const thumb = await thumbnailer.thumbnail(photo, "small");

    expect(thumb?.mime).toBe("image/jpeg");
    expect(calls.map(([command]) => command)).toEqual(["magick"]);
  });

  test("makes one with the system tool for the file's type, then remembers it", async () => {
    const calls: Array<[string, string[]]> = [];
    const thumbnailer = new LaptopThumbnailer({ cacheDir: cache, run: fakeTool(png, calls) });
    await writeFile(join(dir, "clip.mp4"), "v");
    await writeFile(join(dir, "doc.pdf"), "p");

    await thumbnailer.thumbnail(photo, "small");
    await thumbnailer.thumbnail(photo, "small");
    await thumbnailer.thumbnail(join(dir, "clip.mp4"), "small");
    await thumbnailer.thumbnail(join(dir, "doc.pdf"), "small");

    expect(calls.map(([command]) => command)).toEqual([
      "magick",
      "ffmpegthumbnailer",
      "pdftoppm",
    ]);
    expect(calls[0]![1]).toEqual([
      `${photo}[0]`, "-auto-orient", "-thumbnail", "256x256", "-strip", calls[0]![1].at(-1)!,
    ]);
  });

  test("has no picture for other types, or when the tool is missing, and does not retry", async () => {
    let attempts = 0;
    const missing: RunTool = async () => {
      attempts += 1;
      throw new Error("ENOENT");
    };
    const thumbnailer = new LaptopThumbnailer({ cacheDir: cache, run: missing });

    expect(await thumbnailer.thumbnail(join(dir, "notes.txt"), "small")).toBeUndefined();
    expect(attempts).toBe(0);
    expect(await thumbnailer.thumbnail(photo, "small")).toBeUndefined();
    expect(await thumbnailer.thumbnail(photo, "small")).toBeUndefined();
    expect(attempts).toBe(1);
  });

  test("refuses output that is not a PNG or JPEG", async () => {
    const thumbnailer = new LaptopThumbnailer({
      cacheDir: cache,
      run: fakeTool(Buffer.from("<html>")),
    });

    expect(await thumbnailer.thumbnail(photo, "small")).toBeUndefined();
  });

  test("a large preview retries smaller when the first is over the limit", async () => {
    const calls: Array<[string, string[]]> = [];
    const sizes: number[] = [];
    const run: RunTool = async (command, args) => {
      calls.push([command, args]);
      const pixels = Number(args[args.indexOf("-thumbnail") + 1]!.split("x")[0]);
      sizes.push(pixels);
      await writeFile(args.at(-1)!, pixels > 700 ? Buffer.concat([png, Buffer.alloc(500)]) : png);
    };
    const thumbnailer = new LaptopThumbnailer({ cacheDir: cache, run, maxLargeBytes: 200 });

    const thumb = await thumbnailer.thumbnail(photo, "large");

    expect(sizes).toEqual([1024, 640]);
    expect(thumb?.data.equals(png)).toBe(true);
  });

  test("a large preview falls back to the small cached picture", async () => {
    await cached("large", photo, png);
    const thumbnailer = new LaptopThumbnailer({
      cacheDir: cache,
      run: async () => {
        throw new Error("no tool");
      },
    });

    const thumb = await thumbnailer.thumbnail(photo, "large");

    expect(thumb?.data.equals(png)).toBe(true);
  });

  test("runs at most two tools at once", async () => {
    let active = 0;
    let peak = 0;
    const run: RunTool = async (_command, args) => {
      active += 1;
      peak = Math.max(peak, active);
      await Bun.sleep(15);
      await writeFile(args.at(-1)!, png);
      active -= 1;
    };
    const thumbnailer = new LaptopThumbnailer({ cacheDir: cache, run });
    const files: string[] = [];
    for (let index = 0; index < 6; index++) {
      const file = join(dir, `p${index}.png`);
      await writeFile(file, String(index));
      files.push(file);
    }

    const all = await Promise.all(files.map((file) => thumbnailer.thumbnail(file, "small")));

    expect(all.every((thumb) => thumb !== undefined)).toBe(true);
    expect(peak).toBe(2);
  });
});
