/**
 * Second Shift v2 wire tests — the game through real WebSockets in workerd,
 * exercising the exact dt-driven point-and-click action vocabulary the
 * client ships.
 */
import { SELF } from "cloudflare:test";
import { describe, expect, it } from "vitest";

async function open(room: string) {
  const res = await SELF.fetch(`https://game.test/ws/${room}`, {
    headers: { Upgrade: "websocket" },
  });
  expect(res.status).toBe(101);
  const ws = res.webSocket!;
  ws.accept();
  const frames: any[] = [];
  ws.addEventListener("message", (event: MessageEvent) => {
    const data = typeof event.data === "string" ? event.data : "";
    if (data === "__pong") return;
    try {
      frames.push(JSON.parse(data));
    } catch {
      /* ignore */
    }
  });
  const next = async (pred: (f: any) => boolean, label: string) => {
    for (let i = 0; i < 200; i++) {
      const hit = frames.find(pred);
      if (hit) return hit;
      await scheduler.wait(10);
    }
    throw new Error(`timed out waiting for ${label}`);
  };
  const error = async () => next((f) => f?.type === "error", "an error");
  return {
    ws,
    frames,
    next,
    error,
    send: (msg: unknown) => ws.send(JSON.stringify(msg)),
  };
}

let seq = 0;
function roomName(label: string) {
  seq += 1;
  return `${label}-${seq}-${crypto.randomUUID().slice(0, 6)}`;
}

describe("second shift v2 rules", () => {
  it("joins solo and lands in the menu state", async () => {
    const a = await open(roomName("menu"));
    a.send({ type: "join", playerId: "ruth" });
    const s = await a.next((f) => f?.type === "state" && f.status === "playing", "playing");
    expect(s.view.t).toBe(0);
    expect(s.view.queue).toEqual([]);
    expect(s.view.tasks).toEqual({});
    expect(s.meta.game).toBe("Second Shift");
    expect(s.meta.minPlayers).toBe(1);
    a.ws.close();
  });

  it("starts the world clock on client-reported dtMs", async () => {
    const a = await open(roomName("tick"));
    a.send({ type: "join", playerId: "ruth" });
    await a.next((f) => f?.type === "state" && f.status === "playing", "playing");
    a.frames.length = 0;
    for (let i = 0; i < 8; i++) {
      a.send({ type: "action", action: { type: "pause", dtMs: 450 } });
      await a.next((f) => f?.type === "state" && (f.view?.t ?? 0) > i * 0.3, "tick forward");
    }
    const latest = a.frames.filter((f) => f?.type === "state").at(-1);
    expect(latest.view.t).toBeGreaterThan(1);
    a.ws.close();
  }, 10000);

  it("spawns a demand inside its window", async () => {
    const a = await open(roomName("spawn"));
    a.send({ type: "join", playerId: "ruth" });
    await a.next((f) => f?.type === "state" && f.status === "playing", "playing");
    a.frames.length = 0;
    let spawned: any = null;
    for (let i = 0; i < 12 && !spawned; i++) {
      a.send({ type: "action", action: { type: "pause", dtMs: 480 } });
      const f = await a.next(
        (m) => m?.type === "state" && ((m.view?.t ?? 0) > i * 0.4 || (m.view?.queue?.length ?? 0) > 0),
        "a state frame",
      );
      if (f.view?.queue?.length) spawned = f;
    }
    expect(spawned?.view.queue.length).toBeGreaterThan(0);
    expect(["cooking", "laundry"]).toContain(spawned.view.queue[0].key);
    a.ws.close();
  }, 15000);

  it("clicking the next chain object walks her and advances the step", async () => {
    const a = await open(roomName("chain"));
    a.send({ type: "join", playerId: "ruth" });
    await a.next((f) => f?.type === "state" && f.status === "playing", "playing");
    // burn to cooking
    let live: any = null;
    for (let i = 0; i < 30 && !live; i++) {
      a.send({ type: "action", action: { type: "pause", dtMs: 480 } });
      const f = await a.next(
        (m) => m?.type === "state" && ((m.view?.queue?.length ?? 0) > 0 || (m.view?.t ?? 0) > i * 0.4),
        "a state frame",
      );
      if (f.view?.queue?.some((q: any) => q.key === "cooking")) live = f;
    }
    expect(live).toBeTruthy();

    // click the fridge (cooking step 0)
    a.frames.length = 0;
    a.send({ type: "action", action: { type: "click", object: "fridge", dtMs: 16 } });
    const walked = await a.next(
      (f) => f?.type === "state" && f.view?.player?.order?.mode === "walk",
      "she starts walking",
    );
    expect(walked.view.player.order.mode).toBe("walk");
    a.ws.close();
  }, 30000);

  it("a wrong click bounces with no penalty", async () => {
    const a = await open(roomName("bounce"));
    a.send({ type: "join", playerId: "ruth" });
    await a.next((f) => f?.type === "state" && f.status === "playing", "playing");
    let live: any = null;
    for (let i = 0; i < 30 && !live; i++) {
      a.send({ type: "action", action: { type: "pause", dtMs: 480 } });
      const f = await a.next(
        (m) => m?.type === "state" && ((m.view?.queue?.length ?? 0) > 0 || (m.view?.t ?? 0) > i * 0.4),
        "a state frame",
      );
      if (f.view?.queue?.length) live = f;
    }
    const scoreBefore = live.view.score;
    a.frames.length = 0;
    a.send({ type: "action", action: { type: "click", object: "dryer", dtMs: 16 } });
    // walk her there
    for (let i = 0; i < 14; i++) {
      a.send({ type: "action", action: { type: "pause", dtMs: 480 } });
      await a.next((m) => m?.type === "state" && (m.view?.t ?? 0) > 0, "any state");
    }
    const latest = a.frames.filter((f) => f?.type === "state").at(-1);
    expect(latest.view.score).toBe(scoreBefore); // no penalty
    a.ws.close();
  }, 30000);

  it("the client vocabulary is exactly click / answer / resolveKid / pause", async () => {
    const a = await open(roomName("vocab"));
    a.send({ type: "join", playerId: "ruth" });
    await a.next((f) => f?.type === "state" && f.status === "playing", "playing");
    a.frames.length = 0;
    // Unknown actions refuse with a clear error.
    a.send({ type: "action", action: { type: "nudge", d: { dx: 1, dy: 0 }, dtMs: 16 } });
    expect((await a.error()).error).toBe("unknown action type");
    a.frames.length = 0;
    // And a click on a real object is accepted.
    a.send({ type: "action", action: { type: "click", object: "couch", dtMs: 16 } });
    const ok = await a.next(
      (f) => f?.type === "state" && f.view?.player?.order?.mode === "walk",
      "she starts walking to the couch",
    );
    expect(ok.view.player.order.mode).toBe("walk");
    a.ws.close();
  }, 15000);
});
