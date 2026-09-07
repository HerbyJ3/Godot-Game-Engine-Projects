/**
 * `Room` — one multiplayer room, as a Durable Object.
 *
 * A room owns its players' WebSockets and all game state. One DO instance per
 * room id (`env.ROOMS.idFromName(room)`), so two rooms never share state and an
 * idle room costs nothing (see HIBERNATION below).
 *
 * This file is the TRUSTED half of the game: it speaks the wire protocol, owns
 * the sockets, and persists state. It calls `./logic.js` — the game-specific
 * half, six pure functions — for every game decision. Editing a game means
 * editing `logic.js`; you should rarely need to touch this file.
 *
 * ── WIRE PROTOCOL (unchanged from the previous games engine) ─────────────
 *   in:  {type:"join", playerId} | {type:"action", action} | {type:"reset"}
 *   out: {type:"state", status, seats, you, connected, view, result, meta}
 *        {type:"error", error}
 *
 * ── logic.js CONTRACT (pure functions over JSON state) ───────────────────
 *   meta {game, minPlayers, maxPlayers}
 *   setup(players) · validateAction(state, playerId, action)
 *   applyAction(state, playerId, action) · isGameOver(state)
 *   viewFor(state, playerId)
 *
 * ── HIBERNATION ─────────────────────────────────────────────────────────
 * Sockets are accepted with `ctx.acceptWebSocket`, so a room with no traffic is
 * evicted from memory while its connections STAY OPEN, and is revived on the
 * next message. An idle room therefore bills no duration. Two consequences:
 *   * never keep game state in instance fields — it will not survive eviction.
 *     Everything lives in `ctx.storage` (SQLite-backed, per room).
 *   * a connection's identity rides on the socket itself
 *     (`serializeAttachment`), because an in-memory map does not survive.
 */

import { DurableObject } from "cloudflare:workers";

import type { Env } from "./env";
import * as logic from "./logic.js";
import { parseClientMessage } from "./protocol";

/** Server-authoritative room state. Persisted; `view` is derived per player. */
interface Game {
  /** waiting = not enough players yet · playing · over */
  status: "waiting" | "playing" | "over";
  /** playerIds in join order; the first `maxPlayers` get seats, the rest spectate. */
  seats: string[];
  /** Whatever `logic.setup()` returned, advanced by `logic.applyAction()`. */
  state: unknown;
  /** Whatever `logic.isGameOver()` returned once it ended. */
  result: unknown;
}

/** connId -> playerId. Persisted: the sockets outlive this object's memory. */
type Conns = Record<string, string>;

/** One outbound message. `to` is a connId, a list of them, or "*" for everyone. */
interface Out {
  to: string | string[];
  data: unknown;
}

/** What a handler may return: messages, or messages plus an alarm request. */
type Dispatchable = Out[] | { out?: Out[]; wakeIn?: number | null } | void;

/**
 * A brand-new room state.
 *
 * This MUST be a factory, never a shared constant: Durable Object instances of
 * the same class share one isolate, so a module-level `{...DEFAULT}` spread would
 * hand every room the SAME `seats` array (a spread is shallow) and one room's
 * `seats.push()` would leak into every other room that had not saved yet.
 */
export function freshGame(): Game {
  return { status: "waiting", seats: [], state: null, result: null };
}

/**
 * The meta the room can actually rely on.
 *
 * Seating consults `minPlayers`/`maxPlayers` on every join, and `undefined`
 * there fails silently in the worst way: `seats.length < undefined` is false, so
 * NOBODY is ever seated and the room waits forever. That makes trusting the
 * declared shape a bad bet.
 *
 * Games carried over from the previous engine were written against a looser
 * contract — many name the game with `name` (or `title`) rather than `game`, and
 * a few carry `players: [min, max]` instead of the two fields. They ran fine
 * there, so normalise once here rather than refusing to run them.
 */
export function resolveMeta(
  raw: unknown,
): { game: string; minPlayers: number; maxPlayers: number } {
  const meta = (raw ?? {}) as Record<string, unknown>;
  const players = Array.isArray(meta.players) ? (meta.players as unknown[]) : [];
  const seats = (value: unknown, fallback: number): number =>
    Number.isInteger(value) && (value as number) >= 1 ? (value as number) : fallback;

  const minPlayers = seats(meta.minPlayers, seats(players[0], 1));
  const maxPlayers = seats(meta.maxPlayers, seats(players[1], minPlayers));
  const named = [meta.game, meta.name, meta.title].find(
    (value): value is string => typeof value === "string" && value.trim().length > 0,
  );
  return {
    game: named ?? "Game",
    minPlayers,
    // A declared max below the min would wedge the room the same way.
    maxPlayers: Math.max(minPlayers, maxPlayers),
  };
}

const META = resolveMeta(logic.meta);

/**
 * Keepalive. Idle WebSockets get dropped by intermediaries after a few minutes;
 * the runtime answers these ping frames WITHOUT waking the room, so a quiet room
 * stays connected and still costs nothing. (The previous engine lacked this,
 * which is why long-idle games silently lost their sockets.)
 */
const PING = "__ping";
const PONG = "__pong";

export class Room extends DurableObject<Env> {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    // Registered on every construction (cheap, idempotent) rather than on first
    // connect, so a room revived from hibernation keeps answering pings.
    ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair(PING, PONG));
  }

  /**
   * In-memory cache, replay-safe. A Durable Object processes its messages one
   * at a time on a single thread, so after the first `get` everything reads
   * this snapshot instead of hitting storage — realtime games depend on it
   * (an `await storage.get` per 60ms frame starves the loop). Writes are
   * WRITE-BEHIND: `put` is kicked off without awaiting, and the runtime's
   * `outputGate` (waitUntil on the request context) still flushes it before
   * the actor goes idle, so hibernation never loses a committed state.
   */
  private mem: { game: Game; conns: Conns } | null = null;

  private async load(): Promise<{ game: Game; conns: Conns }> {
    if (this.mem) return this.mem;
    const [game, conns] = await Promise.all([
      this.ctx.storage.get<Game>("game"),
      this.ctx.storage.get<Conns>("conns"),
    ]);
    this.mem = { game: game ?? freshGame(), conns: conns ?? {} };
    return this.mem;
  }

  private save(game: Game, conns: Conns): void {
    this.mem = { game, conns };
    // Fire-and-forget: later puts overwrite the tail of the same key, and the
    // runtime guarantees writes-in-flight land before the object is evicted.
    // Awaiting here would halve the achievable action rate for no durability
    // benefit (the snapshot in `this.mem` is already authoritative).
    void this.ctx.storage.put({ game, conns });
  }

  // ── persistence ────────────────────────────────────────────────────────
  //
  // Implemented above, next to the constructor, because the in-memory cache +
  // write-behind strategy is part of why the realtime loop keeps up — see that
  // comment block for the reasoning.

  // ── protocol helpers ───────────────────────────────────────────────────

  /** Everyone's view of the room. Each player sees only `viewFor(state, them)`. */
  private broadcast(game: Game, conns: Conns): Out[] {
    const connected = Object.keys(conns).length;
    return Object.entries(conns).map(([connId, playerId]) => ({
      to: connId,
      data: {
        type: "state",
        status: game.status,
        seats: game.seats,
        you: playerId,
        connected,
        view: game.state ? logic.viewFor(game.state, playerId) : null,
        result: game.result,
        meta: META,
      },
    }));
  }

  private error(connId: string, error: string): Out[] {
    return [{ to: connId, data: { type: "error", error } }];
  }

  // ── connection lifecycle ───────────────────────────────────────────────

  /**
   * The only entry point: a WebSocket upgrade routed here by the Worker
   * (`/ws/<room>`). Anything else is a routing bug in the Worker, not a client
   * error, so it fails loudly rather than quietly serving something.
   */
  override async fetch(request: Request): Promise<Response> {
    if (request.headers.get("Upgrade") !== "websocket") {
      return new Response("expected a websocket upgrade", { status: 426 });
    }
    const pair = new WebSocketPair();
    const server = pair[1]!;
    // Hibernatable accept (NOT server.accept()): the room may be evicted while
    // this socket stays open.
    this.ctx.acceptWebSocket(server);
    const connId = crypto.randomUUID().slice(0, 8);
    // The connId must survive eviction — the socket carries it.
    server.serializeAttachment({ connId });
    return new Response(null, { status: 101, webSocket: pair[0] });
  }

  private connIdOf(ws: WebSocket): string | undefined {
    const att = ws.deserializeAttachment() as { connId?: string } | null;
    return att?.connId;
  }

  override async webSocketMessage(ws: WebSocket, raw: string | ArrayBuffer): Promise<void> {
    const connId = this.connIdOf(ws);
    if (!connId) return;
    try {
      await this.dispatch(await this.onMessage(connId, raw));
    } catch (err) {
      // A throw here is almost always a bug in logic.js. Tell that one client
      // instead of killing the room for everybody. The reason stays server-side:
      // it can carry internals, and the client can't act on it anyway.
      console.error("room message failed:", err instanceof Error ? err.stack : String(err));
      try {
        ws.send(JSON.stringify({ type: "error", error: "server error" }));
      } catch {
        /* socket already gone */
      }
    }
  }

  override async webSocketClose(ws: WebSocket): Promise<void> {
    const connId = this.connIdOf(ws);
    if (!connId) return;
    const { game, conns } = await this.load();
    if (conns[connId] === undefined) return;
    delete conns[connId];
    this.save(game, conns);
    // Tell the remaining players the room got smaller.
    await this.dispatch(this.broadcast(game, conns));
  }

  override async webSocketError(ws: WebSocket): Promise<void> {
    await this.webSocketClose(ws);
  }

  /**
   * Timer tick, requested by a handler returning `wakeIn`. The turn-based kernel
   * never schedules one; real-time games (countdowns, tick loops) do.
   */
  override async alarm(): Promise<void> {
    try {
      await this.dispatch(await this.onWake());
    } catch (err) {
      console.error("room alarm failed:", err instanceof Error ? err.stack : String(err));
    }
  }

  // ── game semantics (the previous engine's kernel, behaviour preserved) ──

  private async onMessage(connId: string, raw: string | ArrayBuffer): Promise<Dispatchable> {
    // Untrusted frame: validated before anything reads it (see ./protocol).
    const parsed = parseClientMessage(raw);
    if (!parsed.ok) return this.error(connId, parsed.error);
    const msg = parsed.msg;

    const { game, conns } = await this.load();

    // A client introduces itself before it may act. Re-joining with the same
    // playerId reclaims that seat (a reconnect after a dropped socket).
    if (msg.type === "join") {
      conns[connId] = msg.playerId;
      if (!game.seats.includes(msg.playerId) && game.seats.length < META.maxPlayers) {
        game.seats.push(msg.playerId);
      }
      if (game.status === "waiting" && game.seats.length >= META.minPlayers) {
        game.state = logic.setup(game.seats);
        game.status = "playing";
      }
      this.save(game, conns);
      return this.broadcast(game, conns);
    }

    const playerId = conns[connId];
    if (!playerId) return this.error(connId, "join first");

    if (msg.type === "action") {
      if (game.status !== "playing") return this.error(connId, "game is not in progress");
      if (!game.seats.includes(playerId)) return this.error(connId, "spectators cannot act");
      // logic.js is the authority on whether an action is legal, and it is
      // consulted BEFORE any state is written.
      const verdict = logic.validateAction(game.state, playerId, msg.action);
      if (!verdict.ok) return this.error(connId, verdict.error ?? "invalid action");
      game.state = logic.applyAction(game.state, playerId, msg.action);
      const end = logic.isGameOver(game.state);
      if (end.over) {
        game.status = "over";
        game.result = end;
      }
      this.save(game, conns);
      return this.broadcast(game, conns);
    }

    // msg.type === "reset"
    if (!game.seats.includes(playerId)) return this.error(connId, "spectators cannot reset");
    const enough = game.seats.length >= META.minPlayers;
    game.state = enough ? logic.setup(game.seats) : null;
    game.status = enough ? "playing" : "waiting";
    game.result = null;
    this.save(game, conns);
    return this.broadcast(game, conns);
  }

  /** Turn-based games schedule no timers; override for real-time loops. */
  private async onWake(): Promise<Dispatchable> {
    return [];
  }

  // ── fan-out ────────────────────────────────────────────────────────────

  /**
   * Send a handler's messages to their target sockets and apply any `wakeIn`.
   * Sockets are matched by the connId on their attachment, because after
   * hibernation `ctx.getWebSockets()` is the only handle we have on them.
   */
  private async dispatch(res: Dispatchable): Promise<void> {
    if (!res) return;
    const msgs = Array.isArray(res) ? res : (res.out ?? []);
    const wakeIn = Array.isArray(res) ? undefined : res.wakeIn;

    if (msgs.length) {
      const sockets = this.ctx.getWebSockets();
      const byId = new Map<string, WebSocket>();
      for (const s of sockets) {
        const id = this.connIdOf(s);
        if (id) byId.set(id, s);
      }
      for (const m of msgs) {
        if (!m) continue;
        const data = typeof m.data === "string" ? m.data : JSON.stringify(m.data);
        const targets =
          m.to === "*"
            ? sockets
            : Array.isArray(m.to)
              ? m.to.map((id) => byId.get(id)).filter((s): s is WebSocket => Boolean(s))
              : [byId.get(m.to)].filter((s): s is WebSocket => Boolean(s));
        for (const t of targets) {
          try {
            t.send(data);
          } catch {
            /* socket closed mid-fan-out; its close handler will clean up */
          }
        }
      }
    }

    // null cancels a pending tick; a number (re)schedules one.
    if (wakeIn === null) await this.ctx.storage.deleteAlarm();
    else if (typeof wakeIn === "number") await this.ctx.storage.setAlarm(Date.now() + wakeIn);
  }
}
