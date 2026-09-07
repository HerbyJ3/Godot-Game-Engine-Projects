/**
 * `resolveMeta` — the shim that lets games from the previous engine run here.
 *
 * These are not hypothetical shapes. Every case below was measured in the
 * production catalog before the migration: ~7% of rules games declare `name`
 * where this contract says `game`, and a few carry `players: [min, max]`
 * instead of the two fields.
 *
 * The stake is specific: seating reads `maxPlayers` on every join, and
 * `seats.length < undefined` is false, so a missing field seats NOBODY and the
 * room waits forever. A game that "loads fine" can still be unplayable.
 */

import { describe, expect, it } from "vitest";

import { resolveMeta } from "../src/room";

describe("resolveMeta", () => {
  it("passes a well-formed meta through untouched", () => {
    expect(resolveMeta({ game: "Tic-Tac-Toe", minPlayers: 2, maxPlayers: 2 })).toEqual({
      game: "Tic-Tac-Toe",
      minPlayers: 2,
      maxPlayers: 2,
    });
  });

  it("takes the display name from `name` when `game` is absent", () => {
    // The single most common shape in the migrated corpus.
    expect(resolveMeta({ name: "DEPTHS", minPlayers: 1, maxPlayers: 1 }).game).toBe("DEPTHS");
  });

  it("falls back to `title` when neither `game` nor `name` is present", () => {
    expect(resolveMeta({ title: "Escape from Tau Ceti" }).game).toBe("Escape from Tau Ceti");
  });

  it("reads seat counts from a `players: [min, max]` pair", () => {
    expect(resolveMeta({ name: "Ad Fighters", players: [1, 2] })).toEqual({
      game: "Ad Fighters",
      minPlayers: 1,
      maxPlayers: 2,
    });
  });

  it("defaults a game with no seat information to single player", () => {
    // Not zero: a room whose maxPlayers is 0 can never seat anyone.
    expect(resolveMeta({ game: "Solo" })).toEqual({
      game: "Solo",
      minPlayers: 1,
      maxPlayers: 1,
    });
  });

  it("survives meta being missing entirely", () => {
    expect(resolveMeta(undefined)).toEqual({ game: "Game", minPlayers: 1, maxPlayers: 1 });
    expect(resolveMeta(null).maxPlayers).toBe(1);
  });

  it("rejects nonsense seat counts rather than trusting them", () => {
    // Each of these would otherwise reach the seating comparison and wedge it.
    expect(resolveMeta({ game: "X", minPlayers: 0, maxPlayers: 0 }).minPlayers).toBe(1);
    expect(resolveMeta({ game: "X", maxPlayers: "2" }).maxPlayers).toBe(1);
    expect(resolveMeta({ game: "X", minPlayers: 1.5 }).minPlayers).toBe(1);
  });

  it("never returns a max below the min", () => {
    // A room declaring 4-2 would accept nobody past the second seat while
    // refusing to start below the fourth.
    expect(resolveMeta({ game: "X", minPlayers: 4, maxPlayers: 2 })).toEqual({
      game: "X",
      minPlayers: 4,
      maxPlayers: 4,
    });
  });

  it("ignores a blank display name", () => {
    expect(resolveMeta({ game: "   ", name: "Real Name" }).game).toBe("Real Name");
    expect(resolveMeta({ game: "" }).game).toBe("Game");
  });
});
