#!/usr/bin/env bun

import { readFile, writeFile } from "node:fs/promises";

type StageSpan = {
  startMs: number;
  endMs?: number;
};

type TimingAttempt = {
  attempt: number;
  stages: Record<string, StageSpan>;
};

type TimingSummary = {
  v: 1;
  wallAnchorMs: number;
  offerWallMs?: number;
  acceptWallMs?: number;
  attempts: TimingAttempt[];
};

type TransferFile = {
  fileId: string;
  filename: string;
  mime: string;
  size: number;
  sha256: string;
  status: string;
  confirmedOffset: number;
  timing?: TimingSummary;
};

type TransferSnapshot = {
  v: 1;
  batches: Array<{
    transferId: string;
    batchId: string;
    origin: string;
    direction: string;
    createdAtMs: number;
    status: string;
    files: TransferFile[];
  }>;
};

type BenchmarkMetadata = {
  scenario?: string;
  run?: number;
  device?: Record<string, unknown>;
  build?: Record<string, unknown>;
  network?: Record<string, unknown>;
  relay?: {
    cpuPercent?: number;
    rssBytes?: number;
  };
  disconnects?: number;
};

export type TransferBenchmarkRow = {
  schemaVersion: 1;
  capturedAtMs: number;
  scenario: string | null;
  run: number | null;
  transferId: string;
  batchId: string;
  fileId: string;
  direction: string;
  filename: string;
  mime: string;
  status: string;
  payloadBytes: number;
  confirmedBytes: number;
  retries: number;
  disconnects: number | null;
  sha256: string;
  device: Record<string, unknown> | null;
  build: Record<string, unknown> | null;
  network: Record<string, unknown> | null;
  relayCpuPercent: number | null;
  relayRssBytes: number | null;
  timing: {
    wallAnchorMs: number;
    offerWallMs: number | null;
    acceptWallMs: number | null;
    attempts: TimingAttempt[];
    stages: Record<string, {
      startMs: number;
      endMs: number | null;
      durationMs: number | null;
    }>;
  } | null;
};

type CliOptions = {
  queuePath: string;
  outputPath?: string;
  markdownPath?: string;
  metadataPath?: string;
  format: "jsonl" | "csv";
};

const options = parseArgs(Bun.argv.slice(2));
const snapshot = parseSnapshot(await readFile(options.queuePath, "utf8"));
const metadata = options.metadataPath
  ? parseMetadata(await readFile(options.metadataPath, "utf8"))
  : {};
const rows = captureTransferRows(snapshot, metadata);
const output = options.format === "csv"
  ? toCsv(rows)
  : rows.map((row) => JSON.stringify(row)).join("\n") + (rows.length ? "\n" : "");

if (options.outputPath) {
  await writeFile(options.outputPath, output, "utf8");
} else {
  process.stdout.write(output);
}
if (options.markdownPath) {
  await writeFile(options.markdownPath, toMarkdown(rows), "utf8");
}

export function captureTransferRows(
  snapshot: TransferSnapshot,
  metadata: BenchmarkMetadata = {},
  capturedAtMs = Date.now(),
): TransferBenchmarkRow[] {
  return snapshot.batches.flatMap((batch) =>
    batch.files.map((file) => {
      const attempts = file.timing?.attempts ?? [];
      const stages = flattenStages(attempts);
      return {
        schemaVersion: 1,
        capturedAtMs,
        scenario: metadata.scenario ?? null,
        run: metadata.run ?? null,
        transferId: batch.transferId,
        batchId: batch.batchId,
        fileId: file.fileId,
        direction: batch.direction,
        filename: file.filename,
        mime: file.mime,
        status: file.status,
        payloadBytes: file.size,
        confirmedBytes: file.confirmedOffset,
        retries: Math.max(0, attempts.length - 1),
        disconnects: metadata.disconnects ?? null,
        sha256: file.sha256,
        device: metadata.device ?? null,
        build: metadata.build ?? null,
        network: metadata.network ?? null,
        relayCpuPercent: metadata.relay?.cpuPercent ?? null,
        relayRssBytes: metadata.relay?.rssBytes ?? null,
        timing: file.timing
          ? {
              wallAnchorMs: file.timing.wallAnchorMs,
              offerWallMs: file.timing.offerWallMs ?? null,
              acceptWallMs: file.timing.acceptWallMs ?? null,
              attempts,
              stages,
            }
          : null,
      } satisfies TransferBenchmarkRow;
    }),
  );
}

function flattenStages(
  attempts: TimingAttempt[],
): TransferBenchmarkRow["timing"]["stages"] {
  const latest = new Map<string, StageSpan>();
  for (const attempt of attempts) {
    for (const [name, span] of Object.entries(attempt.stages)) {
      latest.set(name, span);
    }
  }
  return Object.fromEntries(
    [...latest.entries()].map(([name, span]) => [name, {
      startMs: span.startMs,
      endMs: span.endMs ?? null,
      durationMs: span.endMs === undefined
        ? null
        : Math.max(0, span.endMs - span.startMs),
    }]),
  );
}

function toCsv(rows: TransferBenchmarkRow[]): string {
  const header = [
    "schemaVersion", "capturedAtMs", "scenario", "run", "transferId",
    "batchId", "fileId", "direction", "filename", "mime", "status",
    "payloadBytes", "confirmedBytes", "retries", "disconnects", "sha256",
    "relayCpuPercent", "relayRssBytes", "timingJson", "deviceJson",
    "buildJson", "networkJson",
  ];
  const lines = [header.join(",")];
  for (const row of rows) {
    lines.push([
      row.schemaVersion,
      row.capturedAtMs,
      row.scenario,
      row.run,
      row.transferId,
      row.batchId,
      row.fileId,
      row.direction,
      row.filename,
      row.mime,
      row.status,
      row.payloadBytes,
      row.confirmedBytes,
      row.retries,
      row.disconnects,
      row.sha256,
      row.relayCpuPercent,
      row.relayRssBytes,
      JSON.stringify(row.timing),
      JSON.stringify(row.device),
      JSON.stringify(row.build),
      JSON.stringify(row.network),
    ].map(csvCell).join(","));
  }
  return lines.join("\n") + "\n";
}

function toMarkdown(rows: TransferBenchmarkRow[]): string {
  const durations = new Map<string, number[]>();
  for (const row of rows) {
    for (const [stage, span] of Object.entries(row.timing?.stages ?? {})) {
      if (span.durationMs !== null) {
        const values = durations.get(stage) ?? [];
        values.push(span.durationMs);
        durations.set(stage, values);
      }
    }
  }
  const lines = [
    "# Transfer benchmark capture",
    "",
    `Rows: ${rows.length}`,
    "",
    "| Stage | Samples | Median (ms) | Range (ms) |",
    "| --- | ---: | ---: | ---: |",
  ];
  for (const [stage, values] of [...durations.entries()].sort()) {
    const sorted = [...values].sort((a, b) => a - b);
    lines.push(
      `| ${stage} | ${sorted.length} | ${median(sorted)} | ` +
      `${sorted[0]}–${sorted.at(-1)} |`,
    );
  }
  lines.push("", "Run metadata is embedded in each JSONL/CSV row.");
  return lines.join("\n") + "\n";
}

function median(values: number[]): number {
  const middle = Math.floor(values.length / 2);
  return values.length % 2 === 0
    ? (values[middle - 1] + values[middle]) / 2
    : values[middle];
}

function csvCell(value: unknown): string {
  const text = value === null || value === undefined ? "" : String(value);
  return /[",\n]/.test(text) ? `"${text.replaceAll('"', '""')}"` : text;
}

function parseSnapshot(raw: string): TransferSnapshot {
  const parsed: unknown = JSON.parse(raw);
  if (!parsed || typeof parsed !== "object" || !Array.isArray((parsed as TransferSnapshot).batches)) {
    throw new Error("Queue file must contain a transfer queue snapshot.");
  }
  return parsed as TransferSnapshot;
}

function parseMetadata(raw: string): BenchmarkMetadata {
  const parsed: unknown = JSON.parse(raw);
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new Error("Benchmark metadata must be a JSON object.");
  }
  return parsed as BenchmarkMetadata;
}

function parseArgs(args: string[]): CliOptions {
  let queuePath: string | undefined;
  const options: Omit<CliOptions, "queuePath"> = { format: "jsonl" };
  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index];
    const next = args[index + 1];
    if (arg === "--queue" && next) {
      queuePath = next;
      index += 1;
    } else if (arg === "--out" && next) {
      options.outputPath = next;
      index += 1;
    } else if (arg === "--markdown" && next) {
      options.markdownPath = next;
      index += 1;
    } else if (arg === "--metadata" && next) {
      options.metadataPath = next;
      index += 1;
    } else if (arg === "--format" && (next === "jsonl" || next === "csv")) {
      options.format = next;
      index += 1;
    } else if (arg === "--help") {
      printHelp();
    } else {
      throw new Error(`Unknown or incomplete argument: ${arg}`);
    }
  }
  if (!queuePath) {
    printHelp();
  }
  return { queuePath: queuePath!, ...options };
}

function printHelp(): never {
  console.log(`Usage: bun run benchmark:capture -- --queue <transfers.json> [options]

Options:
  --out <path>       Write JSONL/CSV rows to a file instead of stdout
  --format <format>  jsonl (default) or csv
  --metadata <path>  JSON with device/build/network/relay measurements
  --markdown <path>  Write a median/range Markdown stage summary
`);
  process.exit(0);
}
