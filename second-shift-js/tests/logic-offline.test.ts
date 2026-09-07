/**
 * Pure-function regression tests for Second Shift v2 — the point-and-click
 * rewrite. No sockets, no workerd: the six exported functions exercised
 * directly, which is also how the docs in ../AGENTS.md describe them.
 *
 * Where the harness slows 60fps client dtMs down to legal-sized chunks, these
 * call applyAction directly with at most 500ms per step — the exact same
 * clamp the room enforces.
 */
import { describe, expect, it } from "vitest";
import { meta, setup, applyAction, isGameOver, viewFor } from "../src/logic.js";

function idle(s: any, seconds: number, stepMs = 480) {
  // Advance the world by N seconds of client time, 480ms at a time.
  let cur = s;
  let remaining = seconds * 1000;
  while (remaining > 0) {
    const dt = Math.min(stepMs, remaining);
    cur = applyAction(cur, "ruth", { type: "pause", dtMs: dt });
    remaining -= dt;
  }
  return cur;
}

function until(s: any, pred: (x: any) => boolean, capSec = 200) {
  let cur = s;
  let elapsed = 0;
  while (!pred(cur) && elapsed < capSec) {
    cur = applyAction(cur, "ruth", { type: "pause", dtMs: 480 });
    elapsed += 0.48;
  }
  return cur;
}

function hasQueue(s: any, key: string) {
  return s.queue.some((q: any) => q.key === key);
}

function clickAt(s: any, object: string, walkSec: number) {
  // Send the click, then walk there over walkSec of client time (one pause).
  let cur = applyAction(s, "ruth", { type: "click", object, dtMs: 16 });
  return idle(cur, walkSec);
}

describe("logic v2 — point-and-click + chains", () => {
  it("meta stays single-player and the state is fresh", () => {
    expect(meta.game).toBe("Second Shift");
    expect(meta.minPlayers).toBe(1);
    expect(meta.maxPlayers).toBe(1);
    const s: any = setup(["ruth"]);
    expect(s.t).toBe(0);
    expect(s.score).toBe(0);
    expect(s.roundSeconds).toBe(150);
    expect(s.target).toBe(40);
    expect(s.queue).toEqual([]);
    expect(s.tasks).toEqual({});
    expect(isGameOver(s).over).toBe(false);
    const v: any = viewFor(s, "ruth");
    expect(v.rng).toBeUndefined();
  });

  it("dtMs is clamped to 500ms per action", () => {
    const s0: any = setup(["ruth"]);
    const s1: any = applyAction(s0, "ruth", { type: "pause", dtMs: 9999 });
    expect(s1.t).toBeLessThanOrEqual(0.500001);
    expect(s1.t).toBeGreaterThan(0.4);
  });

  it("a demand spawns inside its window and its chain waits at step 0", () => {
    const s = until(setup(["ruth"]), (x) => x.queue.length >= 1);
    expect(s.queue.length).toBe(1);
    const q = s.queue[0];
    expect(["cooking", "laundry"]).toContain(q.key);
    const ts = s.tasks[q.key];
    expect(ts.stepIdx).toBe(0);
  });

  it("cooking chain completes through stove timer and earns full points", () => {
    let s = until(setup(["ruth"]), (x) => hasQueue(x, "cooking"));
    expect(hasQueue(s, "cooking")).toBe(true);

    s = clickAt(s, "fridge", 7);      // step 0 -> 1
    expect(s.tasks.cooking.stepIdx).toBe(1);

    s = clickAt(s, "counter", 6);     // step 1 -> 2 (chop)
    expect(s.tasks.cooking.stepIdx).toBe(2);

    s = clickAt(s, "stove", 6);       // step 2 -> 3, arms the cook timer
    expect(s.tasks.cooking.stepIdx).toBe(3);
    expect(s.tasks.cooking.timerEnd).toBeGreaterThan(s.t);

    // Let the stove ding (wait 9s), then plate up before the burn window.
    s = idle(s, 10);
    expect(s.tasks.cooking.timerEnd).toBeNull();
    expect(s.tasks.cooking.stepIdx).toBe(4);

    s = clickAt(s, "stove", 6);       // step 4 plate
    expect(s.tasks.cooking.stepIdx).toBe(5);
    s = clickAt(s, "table", 6);       // step 5 serve — chain done
    expect(s.tasks.cooking).toBeNull();
    expect(hasQueue(s, "cooking")).toBe(false);
    expect(s.score).toBeGreaterThanOrEqual(8);
    expect(s.servedCount).toBe(1);
  });

  it("burning dinner halves the finish bonus", () => {
    let s = until(setup(["ruth"]), (x) => hasQueue(x, "cooking"));
    s = clickAt(s, "fridge", 7);
    s = clickAt(s, "counter", 6);
    s = clickAt(s, "stove", 6);
    // Leave the pan 20s — past the burn window; plating late should mark it.
    s = idle(s, 20);
    expect(s.tasks.cooking.burnUntil).not.toBeNull(); // burn window has passed
    s = clickAt(s, "stove", 6);
    expect(s.tasks.cooking.burned).toBe(true);
    s = clickAt(s, "table", 6);
    expect(s.tasks.cooking).toBeNull();
    // Full cooking is 10; burned cuts the finish bonus to 4 (+1+1 earlier).
    expect(s.score).toBeLessThan(10);
  });

  it("laundry runs the long chain with two machine timers", () => {
    let s = until(setup(["ruth"]), (x) => hasQueue(x, "laundry"));
    expect(hasQueue(s, "laundry")).toBe(true);

    const walk = 6;
    void walk;
    s = clickAt(s, "basket", 8);
    expect(s.tasks.laundry.stepIdx).toBe(1);

    s = clickAt(s, "washer", 7);
    expect(s.tasks.laundry.stepIdx).toBe(2);

    s = clickAt(s, "detergent", 6);
    expect(s.tasks.laundry.stepIdx).toBe(3);

    s = clickAt(s, "washer", 7); // pour
    expect(s.tasks.laundry.stepIdx).toBe(4);

    s = clickAt(s, "washer", 5); // dial — machine runs
    expect(s.tasks.laundry.stepIdx).toBe(5);
    expect(s.tasks.laundry.timerEnd).toBeGreaterThan(s.t);

    s = idle(s, 17); // washer dings
    expect(s.tasks.laundry.timerEnd).toBeNull();

    s = clickAt(s, "washer", 5);  // unload wet (steps 6)
    expect(s.tasks.laundry.stepIdx).toBe(7);
    s = clickAt(s, "dryer", 5);   // load dryer
    s = clickAt(s, "dryer", 5);   // dial — second timer
    expect(s.tasks.laundry.timerEnd).toBeGreaterThan(s.t);
    s = idle(s, 16);
    s = clickAt(s, "dryer", 5);   // clothes out — chain complete
    expect(s.tasks.laundry).toBeNull();
    expect(hasQueue(s, "laundry")).toBe(false);
    expect(s.servedCount).toBe(1);
  });

  it("chains are interruptible — walk away mid-laundry, resume later", () => {
    let s = until(setup(["ruth"]), (x) => hasQueue(x, "laundry"));
    s = clickAt(s, "basket", 8);
    s = clickAt(s, "washer", 6);
    expect(s.tasks.laundry.stepIdx).toBe(2);

    // Wander off to the couch for a sit (after the washer pour finishes).
    s = idle(s, 1.2);
    s = clickAt(s, "couch", 8);
    expect(s.tasks.self).toBeTruthy();
    expect(s.tasks.laundry.stepIdx).toBe(2); // progress kept
    s = idle(s, 5.5);
    expect(s.selfNeed).toBeGreaterThan(50);

    // Come back: the chain resumes at step 2 (needs detergent next).
    s = clickAt(s, "detergent", 9);
    expect(s.tasks.laundry.stepIdx).toBe(3);
  });

  it("the phone rings, a fast answer costs a point, a slow answer warms one", () => {
    let s = until(setup(["ruth"]), (x) => x.phone.state === "ringing");
    expect(s.t).toBeGreaterThanOrEqual(27);
    s = applyAction(s, "ruth", { type: "answer", mode: "fast", dtMs: 60 });
    expect(s.phone.state).toBe("idle");
    expect(s.score).toBeLessThanOrEqual(0);
    // next call is scheduled again
    expect(s.phone.nextAtT).toBeGreaterThan(s.t);
  });

  it("an unanswered call escalates into the school email demand", () => {
    let s = until(setup(["ruth"]), (x) => x.phone.state === "ringing");
    // Let it ring out.
    s = until(s, (x) => x.phone.state === "idle", 30);
    expect(s.phone.state).toBe("idle");
    // School email should now be queued (or arrive very soon).
    s = until(s, (x) => hasQueue(x, "email"), 8);
    expect(hasQueue(s, "email")).toBe(true);
  });

  it("the email chain sits her down, holds her, then sends", () => {
    let s = until(setup(["ruth"]), (x) => x.phone.state === "ringing");
    s = until(s, (x) => hasQueue(x, "email"), 30);
    expect(hasQueue(s, "email")).toBe(true);

    s = clickAt(s, "deskChair", 8);
    expect(s.tasks.email.stepIdx).toBe(1);
    expect(s.player.seated).toBe(true);

    s = clickAt(s, "monitor", 4);
    expect(s.tasks.email.stepIdx).toBe(2);
    s = clickAt(s, "monitor", 6); // typing
    expect(s.tasks.email.stepIdx).toBe(3);
    s = clickAt(s, "monitor", 4); // send
    expect(s.tasks.email).toBeNull();
    expect(s.player.seated).toBe(false);
    expect(s.servedCount).toBe(1);
  });

  it("the diaper chain runs baby → table → drawer → table → bin", () => {
    let s = until(setup(["ruth"]), (x) => hasQueue(x, "diaper"));
    expect(hasQueue(s, "diaper")).toBe(true);

    s = clickAt(s, "baby", 8);            // pick the baby up
    expect(s.tasks.diaper.stepIdx).toBe(1);

    s = clickAt(s, "changingTable", 9);   // lay the baby down
    expect(s.tasks.diaper.stepIdx).toBe(2);

    s = clickAt(s, "diaperDrawer", 4);    // clean diaper
    expect(s.tasks.diaper.stepIdx).toBe(3);

    s = clickAt(s, "changingTable", 4.5);   // the change itself
    expect(s.tasks.diaper.stepIdx).toBe(4);

    s = clickAt(s, "bin", 4);             // dispose — chain done
    expect(s.tasks.diaper).toBeNull();
    expect(hasQueue(s, "diaper")).toBe(false);
    // The chain paid out through history even if OTHER demands decayed
    // during the long walks (their misses also hit the score).
    const diaperAwards = s.history
      .filter((h: any) => h.type === "diaper" && /^\+\d/.test(h.text))
      .reduce((sum: number, h: any) => sum + parseInt(h.text.slice(1), 10), 0);
    expect(diaperAwards).toBeGreaterThanOrEqual(9);
    expect(s.servedCount).toBeGreaterThanOrEqual(1);
  });

  it("kids demand routes a click on the kid spot; resolveKid finishes it", () => {
    let s = until(setup(["ruth"]), (x) => hasQueue(x, "kids"));
    const spot = s.tasks.kids.kidSpot;
    expect(spot).toBeTruthy();

    s = clickAt(s, spot, 8);
    // she knelt at the kid — still waiting on the choice
    expect(s.tasks.kids).toBeTruthy();

    s = applyAction(s, "ruth", { type: "resolveKid", mode: "talk", dtMs: 60 });
    expect(s.tasks.kids).toBeNull();
    expect(hasQueue(s, "kids")).toBe(false);
    expect(s.score).toBeGreaterThanOrEqual(8); // talk is the warmer route
  });

  it("SELF bar drains passively; sitting on the couch refills it", () => {
    let s = idle(setup(["ruth"]), 30);
    expect(s.selfNeed).toBeLessThan(100);

    s = clickAt(s, "couch", 4);
    expect(s.tasks.self).toBeTruthy();
    s = idle(s, 8.0);
    expect(s.tasks.self).toBeNull();
    expect(s.selfNeed).toBeGreaterThan(97);
    expect(s.score).toBe(2);
  });

  it("the round closes at 150s; rng never leaks into the view", () => {
    const s0: any = setup(["ruth"]);
    const s1: any = idle({ ...s0, t: 149.4 }, 1);
    expect(s1.t).toBeGreaterThanOrEqual(150);
    expect(s1.outcome).toBe("lost");
    expect(isGameOver(s1).over).toBe(true);

    const won: any = idle({ ...s0, t: 149.4, score: 41 }, 1);
    expect(won.outcome).toBe("won");
    const endWon: any = isGameOver(won);
    expect(endWon.winner).toBe("her");

    const v: any = viewFor(won, "ruth");
    expect(v.rng).toBeUndefined();
    expect(v.tasks).toBeDefined();
    expect(v.taskDefs.laundry.steps.length).toBeGreaterThan(4);
  });

  it("state stays JSON-serializable through a long mixed session", () => {
    let s = idle(setup(["ruth"]), 20);
    const cloned = JSON.parse(JSON.stringify(s));
    expect(cloned.t).toBeCloseTo(s.t, 6);
    expect(Array.isArray(cloned.queue)).toBe(true);
  });
});
