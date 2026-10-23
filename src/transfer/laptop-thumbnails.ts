import { execFile } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdtemp, readFile, rm, stat } from "node:fs/promises";
import { homedir, tmpdir } from "node:os";
import { extname, join } from "node:path";
import type { BrowseThumbSize } from "../shared/wire";

export interface Thumbnail {
  mime: "image/png" | "image/jpeg";
  data: Buffer;
}

/** Runs one thumbnailer; rejects when it is missing, fails or runs too long. */
export type RunTool = (command: string, args: string[]) => Promise<void>;

export interface LaptopThumbnailerOptions {
  /** The freedesktop thumbnail cache; defaults to `$XDG_CACHE_HOME/thumbnails`. */
  cacheDir?: string;
  run?: RunTool;
  maxSmallBytes?: number;
  maxLargeBytes?: number;
}

const defaultMaxSmallBytes = 160 * 1024;
const defaultMaxLargeBytes = 3 * 1024 * 1024;
const toolTimeoutMs = 8000;
const concurrentTools = 2;
const memoryBudgetBytes = 24 * 1024 * 1024;
const maxRememberedMisses = 2000;

// freedesktop thumbnail sizes: normal 128, large 256, x-large 512, xx-large 1024.
const smallPixels = 256;
const largePixels = [1024, 640];
const smallCaches = ["large", "normal"];
const largeCaches = ["xx-large", "x-large"];

const imageTypes = new Set([
  ".jpg", ".jpeg", ".png", ".gif", ".webp", ".bmp", ".tif", ".tiff",
  ".heic", ".heif", ".avif", ".svg",
]);
const videoTypes = new Set([
  ".mp4", ".mkv", ".webm", ".mov", ".avi", ".m4v", ".wmv", ".flv", ".3gp",
]);

/**
 * Pictures of laptop files for the phone's browser (ADR 0027). It reuses the
 * thumbnails the desktop's file manager already cached, and otherwise asks the
 * system's own thumbnailers (gdk-pixbuf for images, ffmpegthumbnailer for
 * video, pdftoppm for PDFs). A missing tool just means no picture.
 *
 * Nothing is written to the desktop's cache: made thumbnails live in memory
 * for this process, within a fixed budget.
 */
export class LaptopThumbnailer {
  private readonly cacheDir: string;
  private readonly run: RunTool;
  private readonly maxSmallBytes: number;
  private readonly maxLargeBytes: number;
  private readonly made = new Map<string, Thumbnail>();
  private madeBytes = 0;
  private readonly misses = new Set<string>();
  private running = 0;
  private readonly waiting: Array<() => void> = [];

  constructor(options: LaptopThumbnailerOptions = {}) {
    this.cacheDir =
      options.cacheDir ??
      join(process.env.XDG_CACHE_HOME || join(homedir(), ".cache"), "thumbnails");
    this.run = options.run ?? execTool;
    this.maxSmallBytes = options.maxSmallBytes ?? defaultMaxSmallBytes;
    this.maxLargeBytes = options.maxLargeBytes ?? defaultMaxLargeBytes;
  }

  /** `file` is an absolute, resolved path to a regular file. */
  async thumbnail(
    file: string,
    size: BrowseThumbSize,
  ): Promise<Thumbnail | undefined> {
    const info = await stat(file);
    const key = `${size}:${file}:${info.mtimeMs}:${info.size}`;
    const remembered = this.made.get(key);
    if (remembered) {
      // Re-insert so the least recently used entry is the first one evicted.
      this.made.delete(key);
      this.made.set(key, remembered);
      return remembered;
    }
    if (this.misses.has(key)) return undefined;

    const limit = size === "small" ? this.maxSmallBytes : this.maxLargeBytes;
    const found =
      size === "small"
        ? (await this.fromCache(file, info.mtimeMs, smallCaches, limit)) ??
          (await this.generate(file, [smallPixels], limit))
        : (await this.fromCache(file, info.mtimeMs, largeCaches, limit)) ??
          (await this.generate(file, largePixels, limit)) ??
          (await this.fromCache(file, info.mtimeMs, smallCaches, limit));

    if (found) this.remember(key, found);
    else this.misses.add(key);
    if (this.misses.size > maxRememberedMisses) {
      this.misses.delete(this.misses.values().next().value!);
    }
    return found;
  }

  private async fromCache(
    file: string,
    sourceMtimeMs: number,
    sizes: readonly string[],
    limit: number,
  ): Promise<Thumbnail | undefined> {
    const name = `${createHash("md5").update(fileUri(file)).digest("hex")}.png`;
    for (const size of sizes) {
      const path = join(this.cacheDir, size, name);
      try {
        const info = await stat(path);
        // A thumbnail older than its file shows what the file used to be.
        if (info.mtimeMs < sourceMtimeMs || info.size > limit) continue;
        return { mime: "image/png", data: await readFile(path) };
      } catch {
        // Not cached at this size.
      }
    }
    return undefined;
  }

  private async generate(
    file: string,
    pixels: readonly number[],
    limit: number,
  ): Promise<Thumbnail | undefined> {
    const kind = toolFor(file);
    if (!kind) return undefined;
    for (const size of pixels) {
      const made = await this.withSlot(() => this.makeOne(kind, file, size));
      if (made && made.data.byteLength <= limit) return made;
      if (!made) return undefined;
    }
    return undefined;
  }

  private async makeOne(
    kind: ToolKind,
    file: string,
    pixels: number,
  ): Promise<Thumbnail | undefined> {
    const work = await mkdtemp(join(tmpdir(), "vidyut-thumb-"));
    try {
      const output = join(work, kind === "video" ? "out.jpg" : "out.png");
      switch (kind) {
        case "image":
          await this.run("gdk-pixbuf-thumbnailer", ["-s", String(pixels), file, output]);
          break;
        case "video":
          await this.run("ffmpegthumbnailer", ["-i", file, "-o", output, "-s", String(pixels), "-q", "8"]);
          break;
        case "pdf":
          await this.run("pdftoppm", [
            "-png", "-singlefile", "-f", "1", "-l", "1",
            "-scale-to", String(pixels), file, join(work, "out"),
          ]);
          break;
      }
      const data = await readFile(output);
      const mime = sniffMime(data);
      return mime ? { mime, data } : undefined;
    } catch {
      return undefined;
    } finally {
      await rm(work, { recursive: true, force: true });
    }
  }

  private remember(key: string, thumbnail: Thumbnail): void {
    this.made.set(key, thumbnail);
    this.madeBytes += thumbnail.data.byteLength;
    for (const [oldest, evicted] of this.made) {
      if (this.madeBytes <= memoryBudgetBytes || oldest === key) break;
      this.made.delete(oldest);
      this.madeBytes -= evicted.data.byteLength;
    }
  }

  private async withSlot<T>(task: () => Promise<T>): Promise<T> {
    if (this.running >= concurrentTools) {
      await new Promise<void>((resolve) => this.waiting.push(resolve));
    }
    this.running += 1;
    try {
      return await task();
    } finally {
      this.running -= 1;
      this.waiting.shift()?.();
    }
  }
}

type ToolKind = "image" | "video" | "pdf";

function toolFor(file: string): ToolKind | undefined {
  const extension = extname(file).toLowerCase();
  if (imageTypes.has(extension)) return "image";
  if (videoTypes.has(extension)) return "video";
  if (extension === ".pdf") return "pdf";
  return undefined;
}

/** The `file://` URI the freedesktop spec hashes: GLib's escaping of a path. */
export function fileUri(path: string): string {
  const escaped = path
    .split("/")
    .map((segment) =>
      encodeURIComponent(segment).replace(
        /%(24|26|2B|2C|3B|3D|3A|40)/g,
        (_, hex: string) => String.fromCharCode(parseInt(hex, 16)),
      ),
    )
    .join("/");
  return `file://${escaped}`;
}

function sniffMime(data: Buffer): Thumbnail["mime"] | undefined {
  if (data.byteLength > 8 && data.readUInt32BE(0) === 0x89504e47) return "image/png";
  if (data.byteLength > 3 && data[0] === 0xff && data[1] === 0xd8) return "image/jpeg";
  return undefined;
}

const execTool: RunTool = (command, args) =>
  new Promise((resolve, reject) => {
    execFile(
      command,
      args,
      { timeout: toolTimeoutMs, killSignal: "SIGKILL", maxBuffer: 1024 * 1024 },
      (error) => (error ? reject(error) : resolve()),
    );
  });
