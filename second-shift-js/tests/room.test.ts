/**
 * Room behaviour, exercised through real WebSockets in workerd.
 *
 * This is the safety net for the migration kernel (`src/room.ts`,
 * `src/protocol.ts`): routing, seats, per-player views, persistence, and input
 * hygiene, asserted against the game's OWN rules (Second Shift) rather than a
 * toy. Game-specific rules live in ./secondshift.test.ts and
 * ./logic-offline.test.ts.
 */
import { SELF } from "cloudflare:test";
import { describe, expect, it } from "vitest";

/** Open a socket to a room and collect frames as they arrive. */
async function open(room = "main") {
  const res = await SELF.fetch(`https://game.test/ws/${room}`, {
    headers: { Upgrade: "websocket" },
  });
  expect(res.status).toBe(101);
  const ws = res.webSocket!;
  ws.accept();

  const frames: unknown[] = [];
  ws.addEventListener("message", (event: MessageEvent) => {
    const data = typeof event.data === "string" ? event.data : "";
    if (data === "__pong") return;
    try {
      frames.push(JSON.parse(data));
    } catch {
      frames.push(data);
    }
  });

  const next = async (pred: (f: any) => boolean, label: string) => {
    for (let i = 0; i < 100; i++) {
      const hit = frames.find(pred);
      if (hit) return hit as any;
      await scheduler.wait(10);
    }
    throw new Error(`timed out waiting for ${label}; got ${JSON.stringify(frames)}`);
  };

  return {
    ws,
    frames,
    next,
    send: (msg: unknown) => ws.send(JSON.stringify(msg)),
    state: () => next((f) => f?.type === "state", "a state frame"),
    error: () => next((f) => f?.type === "error", "an error frame"),
  };
}

/** A fresh room name per call — Durable Object state persists across tests. */
let seq = 0;
function uniq(label: string): string {
  seq += 1;
  return `${label}-${seq}-${crypto.randomUUID().slice(0, 6)}`;
}

describe("routing", () => {
  it("rejects a non-upgrade request to /ws instead of waking a room", async () => {
    const res = await SELF.fetch("https://game.test/ws");
    expect(res.status).toBe(426);
  });

  it("rejects a room name that isn't a short safe label", async () => {
    const res = await SELF.fetch("https://game.test/ws/../../etc/passwd", {
      headers: { Upgrade: "websocket" },
    });
    expect(res.status).not.toBe(101);
  });

  it("404s a non-asset, non-ws path for a non-HTML request", async () => {
    const res = await SELF.fetch("https://game.test/api/nope");
    expect(res.status).toBe(404);
  });
});

describe("joining", () => {
  it("a single player is enough — minPlayers is 1 and the game starts at join", async () => {
    const a = await open(uniq("solo"));
    a.send({ type: "join", playerId: "ruth" });
    const s = await a.next((f) => f?.type === "state" && f.status === "playing", "playing");
    expect(s.you).toBe("ruth");
    expect(s.seats).toEqual(["ruth"]);
    expect(s.meta.game).toBe("Second Shift");
    expect(s.view.player.x).toBe(480);
    expect(s.view.t).toBe(0);
    a.ws.close();
  });

  it("a second joiner is seated as a spectator (maxPlayers 1)", async () => {
    const room = uniq("spectate");
    const a = await open(room);
    const b = await open(room);
    a.send({ type: "join", playerId: "ruth" });
    await a.next((f) => f?.type === "state" && f.status === "playing", "playing");
    b.send({ type: "join", playerId: "onlooker" });
    const s = await b.next((f) => f?.type === "state" && f.connected === 2, "both connected");
    expect(s.seats).toEqual(["ruth"]);
    expect(s.you).toBe("onlooker");
    a.ws.close();
    b.ws.close();
  });

  it("refuses to act before joining", async () => {
    const a = await open(uniq("no-join"));
    a.send({ type: "action", action: { type: "click", object: "fridge" } });
    expect((await a.error()).error).toBe("join first");
    a.ws.close();
  });
});

describe("playing", () => {
  it("a legal click order walks her and both seated and watching clients see it", async () => {
    const room = uniq("walk");
    const a = await open(room);
    const watcher = await open(room);
    a.send({ type: "join", playerId: "ruth" });
    await a.next((f) => f?.type === "state" && f.status === "playing", "playing");
    watcher.send({ type: "join", playerId: "watcher" });
    await watcher.next((f) => f?.type === "state" && f.connected === 2, "joined as watcher");

    a.send({ type: "action", action: { type: "click", object: "fridge", dtMs: 60 } });
    const seen = await a.next(
      (f) => f?.type === "state" && f.view?.player?.order?.mode === "walk",
      "ruth walking",
    );
    expect(seen.view.player.pendingResolve).toBe("fridge");
    a.ws.close();
    watcher.ws.close();
  });

  it("refuses unknown objects before they are written", async () => {
    const a = await open(uniq("oob"));
    a.send({ type: "join", playerId: "ruth" });
    await a.next((f) => f?.type === "state" && f.status === "playing", "playing");
    a.frames.length = 0;
    a.send({ type: "action", action: { type: "click", object: "nothere", dtMs: 16 } });
    expect((await a.error()).error).toBe("unknown object");
    a.ws.close();
  });

  it("closes the round at the buzzer and refuses actions after", async () => {
    const a = await open(uniq("frozen"));
    a.send({ type: "join", playerId: "ruth" });
    await a.next((f) => f?.type === "state" && f.status === "playing", "playing");
    // v2's round runs 150s — 300 client 500ms pauses drive it to the buzzer.
    let sawOver = false;
    for (let i = 0; i < 310 && !sawOver; i++) {
      const before = a.frames.length;
      a.send({ type: "action", action: { type: "pause", dtMs: 500 } });
      // Wait for any state frame that arrived IN RESPONSE to this send.
      for (let w = 0; w < 100; w++) {
        const fresh = a.frames.slice(before).find((m: any) => m?.type === "state") as any;
        if (fresh) {
          if (fresh.status === "over") sawOver = true;
          break;
        }
        await scheduler.wait(10);
      }
    }
    expect(sawOver).toBe(true);

    a.send({ type: "action", action: { type: "click", object: "fridge", dtMs: 16 } });
    expect((await a.error()).error).toBe("game is not in progress");
    a.ws.close();
  }, 90000);

  it("a reset starts a fresh round from t=0", async () => {
    const a = await open(uniq("reset"));
    a.send({ type: "join", playerId: "ruth" });
    await a.next((f) => f?.type === "state" && f.status === "playing", "playing");
    for (let i = 0; i < 8; i++) {
      a.send({ type: "action", action: { type: "pause", dtMs: 450 } });
      await scheduler.wait(25);
    }
    a.frames.length = 0;
    a.send({ type: "reset" });
    const fresh = await a.next(
      (f) => f?.type === "state" && f.view?.t === 0,
      "a fresh board",
    );
    expect(fresh.status).toBe("playing");
    expect(fresh.view.score).toBe(0);
    a.ws.close();
  });
});

describe("isolation and persistence", () => {
  it("keeps two rooms completely separate", async () => {
    const a = await open(uniq("one"));
    const b = await open(uniq("two"));
    a.send({ type: "join", playerId: "ruth" });
    b.send({ type: "join", playerId: "onlooker" });
    const s1 = await a.next((f) => f?.type === "state" && f.status === "playing", "a state");
    const s2 = await b.next((f) => f?.type === "state", "b state");
    expect(s1.seats).toEqual(["ruth"]);
    expect(s1.connected).toBe(1);
    expect(s2.connected).toBe(1);
    expect(s2.seats).toEqual(["onlooker"]); // separate room — Ruth is not here
    a.ws.close();
    b.ws.close();
  });

  it("survives a reconnect: state persists and the seat is reclaimed", async () => {
    const room = uniq("persist");
    const first = await open(room);
    first.send({ type: "join", playerId: "ruth" });
    await first.next((f) => f?.type === "state" && f.status === "playing", "playing");
    first.send({ type: "action", action: { type: "click", object: "fridge", dtMs: 60 } });
    await first.next(
      (f) => f?.type === "state" && f.view?.player?.order?.mode === "walk",
      "walking",
    );
    first.frames.length = 0;
    first.ws.close();

    const again = await open(room);
    again.send({ type: "join", playerId: "ruth" });
    const restored = await again.next(
      (f) => f?.type === "state" && f.you === "ruth" && f.view?.player?.order?.mode === "walk",
      "restored seat",
    );
    expect(restored.seats).toEqual(["ruth"]);
    // Pathfinding means the first leg is a waypoint, not the fridge itself.
    expect(restored.view.player.pendingResolve).toBe("fridge");
    expect(restored.view.player.order.mode).toBe("walk");
    again.ws.close();
  });

  it("drops a departed player from the connected count (the seat is kept)", async () => {
    const room = uniq("leave");
    const a = await open(room);
    const b = await open(room);
    a.send({ type: "join", playerId: "ruth" });
    b.send({ type: "join", playerId: "onlooker" });
    await a.next((f) => f?.type === "state" && f.connected === 2, "both connected");

    a.frames.length = 0;
    b.ws.close();
    const afterLeave = await a.next((f) => f?.type === "state" && f.connected === 1, "the drop");
    expect(afterLeave.seats).toEqual(["ruth"]);
    a.ws.close();
  });
});

describe("untrusted input", () => {
  it("rejects a non-JSON frame", async () => {
    const a = await open(uniq("bad-json"));
    a.ws.send("not json at all");
    expect((await a.error()).error).toBe("invalid json");
    a.ws.close();
  });

  it("rejects a JSON array (not an object)", async () => {
    const a = await open(uniq("bad-shape"));
    a.ws.send(JSON.stringify([1, 2, 3]));
    expect((await a.error()).error).toBe("expected a json object");
    a.ws.close();
  });

  it("rejects an unknown message type", async () => {
    const a = await open(uniq("bad-type"));
    a.send({ type: "definitely-not-a-thing" });
    expect((await a.error()).error).toMatch(/unknown message type/);
    a.ws.close();
  });

  it("requires a playerId on join", async () => {
    const a = await open(uniq("no-id"));
    a.send({ type: "join" });
    expect((await a.error()).error).toBe("playerId required");
    a.frames.length = 0;
    a.send({ type: "join", playerId: "   " });
    await a.next((f) => f?.type === "state" || f?.type === "error", "any protocol frame");
    a.ws.close();
  });

  it("refuses an oversized frame instead of persisting it", async () => {
    const a = await open(uniq("too-big"));
    a.send({ type: "join", playerId: "ruth" });
    await a.state();
    a.frames.length = 0;
    a.send({ type: "action", action: { blob: "x".repeat(20_000) } });
    expect((await a.error()).error).toBe("message too large");
    a.ws.close();
  });

  it("refuses an oversized action payload", async () => {
    const a = await open(uniq("big-action"));
    a.send({ type: "join", playerId: "ruth" });
    await a.state();
    a.frames.length = 0;
    a.send({ type: "action", action: { blob: "x".repeat(6_000) } });
    expect((await a.error()).error).toBe("action too large");
    a.ws.close();
  });

  it("a spectator cannot act and cannot reset", async () => {
    const room = uniq("spectator");
    const a = await open(room);
    const s = await open(room);
    a.send({ type: "join", playerId: "ruth" });
    await a.next((f) => f?.type === "state" && f.status === "playing", "playing");

    s.send({ type: "join", playerId: "watcher" });
    const asWatcher = await s.next((f) => f?.type === "state" && f.connected === 2, "watcher joined");
    expect(asWatcher.seats).toEqual(["ruth"]);

    s.frames.length = 0;
    s.send({ type: "action", action: { type: "pause", dtMs: 60 } });
    expect((await s.error()).error).toBe("spectators cannot act");

    s.frames.length = 0;
    s.send({ type: "reset" });
    expect((await s.error()).error).toBe("spectators cannot reset");

    a.ws.close();
    s.ws.close();
  });
});
