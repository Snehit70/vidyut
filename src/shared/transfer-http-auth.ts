import { timingSafeEqual } from "node:crypto";

const encoder = new TextEncoder();
const authWindowMs = 5 * 60 * 1000;

export interface TransferHttpAuthHeaders {
  date: string;
  authorization: string;
}

export async function createTransferHttpAuth({
  pairingSecret,
  method,
  pathAndQuery,
  date = Date.now(),
}: {
  pairingSecret: string;
  method: string;
  pathAndQuery: string;
  date?: number;
}): Promise<TransferHttpAuthHeaders> {
  const dateValue = String(date);
  const signature = await sign(
    pairingSecret,
    canonicalRequest(method, pathAndQuery, dateValue),
  );
  return {
    date: dateValue,
    authorization: `Vidyut ${signature}`,
  };
}

export async function verifyTransferHttpAuth({
  request,
  pairingSecret,
  now = Date.now(),
}: {
  request: Request;
  pairingSecret: string;
  now?: number;
}): Promise<boolean> {
  const rawDate = request.headers.get("x-vidyut-date");
  const authorization = request.headers.get("authorization");
  if (!rawDate || !authorization?.startsWith("Vidyut ")) return false;

  const date = Number(rawDate);
  if (!Number.isSafeInteger(date) || Math.abs(now - date) > authWindowMs) {
    return false;
  }

  const url = new URL(request.url);
  const expected = await sign(
    pairingSecret,
    canonicalRequest(
      request.method,
      `${url.pathname}${url.search}`,
      rawDate,
    ),
  );
  return safeEqual(expected, authorization.slice("Vidyut ".length));
}

function canonicalRequest(
  method: string,
  pathAndQuery: string,
  date: string,
): string {
  return `${method.toUpperCase()}\n${pathAndQuery}\n${date}`;
}

async function sign(pairingSecret: string, value: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(pairingSecret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign(
    "HMAC",
    key,
    encoder.encode(value),
  );
  return Buffer.from(signature).toString("base64url");
}

function safeEqual(left: string, right: string): boolean {
  const leftBytes = Buffer.from(left);
  const rightBytes = Buffer.from(right);
  return (
    leftBytes.byteLength === rightBytes.byteLength &&
    timingSafeEqual(leftBytes, rightBytes)
  );
}

