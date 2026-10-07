/**
 * Guard against the single most dangerous bug class in this file's history:
 * SHARED MUTABLE STATE between rooms.
 *
 * Durable Object instances of one class share an isolate in the real runtime, so
 * any module-level object a room mutates leaks into every other room. The first
 * version of `Room` spread a module-level constant (`{...DEFAULT_GAME}` — a
 * SHALLOW copy), which handed every room the same `seats` array: one room's join
 * appeared in the next room's game. It reproduced immediately under `wrangler
 * dev` with two rooms.
 *
 * It is asserted HERE, as a unit test, rather than through two live rooms
 * because the vitest pool appears to give each Durable Object its own module
 * instance — so an isolate-shared array is invisible to a room-vs-room test and
 * that test would give false confidence. This one holds regardless of runtime.
 */

import { describe, expect, it } from "vitest";

import { freshGame } from "../src/room";

describe("fresh room state", () => {
  it("is a new object every call", () => {
    expect(freshGame()).not.toBe(freshGame());
  });

  it("gives every room its OWN seats array", () => {
    const a = freshGame();
    const b = freshGame();
    // The exact failure mode: mutating one room's seats must not touch another's.
    a.seats.push("player-in-room-a");
    expect(b.seats).toEqual([]);
    expect(a.seats).not.toBe(b.seats);
  });

  it("starts empty and waiting", () => {
    const g = freshGame();
    expect(g).toEqual({ status: "waiting", seats: [], state: null, result: null });
  });
});
