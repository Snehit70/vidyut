import { createAuthMessage } from "../shared/auth";
import type { PayloadFrame, RelayMessage } from "../shared/wire";

interface ConnectDeviceOptions {
  url: string;
  pairingSecret: string;
  deviceId: string;
}

export interface ConnectedDevice {
  publish(frame: PayloadFrame): Promise<void>;
  nextPayload(): Promise<PayloadFrame>;
  close(): void;
}

export async function connectDevice(options: ConnectDeviceOptions): Promise<ConnectedDevice> {
  const socket = new WebSocket(options.url);
  const payloads: PayloadFrame[] = [];
  const waiters: Array<(frame: PayloadFrame) => void> = [];
  const publishWaiters: Array<{
    resolve(ts: number): void;
    reject(error: Error): void;
  }> = [];

  let authSettled = false;
  let rejectAuth: (error: Error) => void = () => {};

  const authReady = new Promise<void>((resolve, reject) => {
    rejectAuth = reject;
    socket.addEventListener("open", () => undefined);
    socket.addEventListener("message", async (event) => {
      const message = JSON.parse(String(event.data)) as RelayMessage;
      if (message.kind === "hello") {
        socket.send(JSON.stringify(await createAuthMessage(options.pairingSecret, message.challenge, options.deviceId)));
        return;
      }
      if (message.kind === "auth_ok") {
        authSettled = true;
        resolve();
        return;
      }
      if (message.kind === "error" && !authSettled) {
        authSettled = true;
        reject(new Error(message.code));
        return;
      }
      if (message.kind === "error") {
        const waiter = publishWaiters.shift();
        if (waiter) waiter.reject(new Error(message.code));
        return;
      }
      if (message.kind === "payload") {
        const waiter = waiters.shift();
        if (waiter) waiter(message.frame);
        else payloads.push(message.frame);
      }
      if (message.kind === "ack") {
        const waiter = publishWaiters.shift();
        if (waiter) waiter.resolve(message.ts);
      }
    });
    socket.addEventListener("close", (event) => {
      if (!authSettled) {
        authSettled = true;
        reject(new Error(event.reason || "connection_closed"));
      }
      // A publish in flight never gets its ack once the socket is gone.
      for (const waiter of publishWaiters.splice(0)) {
        waiter.reject(new Error(`connection_closed (${event.code})`));
      }
    });
    socket.addEventListener("error", () => {
      if (!authSettled) {
        authSettled = true;
        reject(new Error("connection_error"));
      }
    });
  });

  await authReady;

  return {
    async publish(frame) {
      socket.send(JSON.stringify({ v: 1, kind: "publish", frame } satisfies RelayMessage));
      const ackTs = await new Promise<number>((resolve, reject) => publishWaiters.push({ resolve, reject }));
      if (ackTs !== frame.ts) {
        throw new Error(`Unexpected ack timestamp ${ackTs}`);
      }
    },
    nextPayload() {
      const payload = payloads.shift();
      if (payload) return Promise.resolve(payload);
      return new Promise<PayloadFrame>((resolve) => waiters.push(resolve));
    },
    close() {
      rejectAuth(new Error("closed"));
      socket.close();
    },
  };
}
