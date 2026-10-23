import { describe, expect, test } from "bun:test";
import { ClipboardPause, withPause, type ClipboardPauseState } from "../src/relay/clipboard-pause";

describe("clipboard pause", () => {
  test("pauses until resumed and reports each change", () => {
    const changes: ClipboardPauseState[] = [];
    const pause = new ClipboardPause({ now: () => 1_000, onChange: (state) => changes.push(state) });

    expect(pause.state()).toEqual({ paused: false });
    pause.pause();
    expect(pause.state()).toEqual({ paused: true });
    pause.resume();
    pause.resume();

    expect(pause.paused).toBe(false);
    expect(changes).toEqual([{ paused: true }, { paused: false }]);
  });

  test("lifts a timed pause by itself", async () => {
    const changes: ClipboardPauseState[] = [];
    const pause = new ClipboardPause({ now: Date.now, onChange: (state) => changes.push(state) });

    pause.pause(10);
    expect(pause.state().until).toBeGreaterThan(Date.now());
    await Bun.sleep(30);

    expect(pause.paused).toBe(false);
    expect(changes.at(-1)).toEqual({ paused: false });
  });

  test("treats a deadline already passed as resumed, even before the timer fires", () => {
    let now = 1_000;
    const pause = new ClipboardPause({ now: () => now });

    pause.pause(60_000);
    now = 61_000;

    expect(pause.state()).toEqual({ paused: false });
    pause.stop();
  });

  test("pausing again replaces the deadline", () => {
    const pause = new ClipboardPause({ now: () => 1_000 });

    pause.pause(60_000);
    pause.pause();

    expect(pause.state()).toEqual({ paused: true });
  });

  test("folds the pause into clipboard health", () => {
    const pause = new ClipboardPause({ now: () => 1_000 });
    const health = { enabled: true, status: "healthy" as const };

    expect(withPause(health, pause)).toEqual(health);
    pause.pause(5_000);
    expect(withPause(health, pause)).toEqual({ ...health, paused: true, pausedUntil: 6_000 });
    pause.stop();
  });
});
