import type { PayloadFrame } from "../shared/wire";

export type PoolListener = (frame: PayloadFrame, source: unknown) => void | Promise<void>;

export class PayloadPool {
  #current: PayloadFrame | undefined;
  #currentOrderTs = 0;
  #listeners = new Set<PoolListener>();

  get current(): PayloadFrame | undefined {
    return this.#current;
  }

  /**
   * Last writer wins, ordered by `orderTs`: the frame's ts mapped onto the
   * Relay's clock. A device whose clock runs ahead would otherwise win every
   * race and one running behind would lose to copies made before its own.
   * Defaults to `frame.ts` for frames stamped on this machine.
   */
  async publish(
    frame: PayloadFrame,
    source?: unknown,
    orderTs: number = frame.ts,
  ): Promise<boolean> {
    // A verbatim republish (a held screenshot re-sent on reconnect) is already
    // here. Its order stamp moves with the send time, so it must not be judged
    // stale against itself.
    if (this.#current?.nonce === frame.nonce) return true;
    if (this.#current && orderTs < this.#currentOrderTs) {
      return false;
    }

    this.#current = frame;
    this.#currentOrderTs = orderTs;
    await Promise.allSettled(
      Array.from(this.#listeners, (listener) => Promise.resolve().then(() => listener(frame, source))),
    );
    return true;
  }

  subscribe(listener: PoolListener): () => void {
    this.#listeners.add(listener);
    return () => {
      this.#listeners.delete(listener);
    };
  }
}
