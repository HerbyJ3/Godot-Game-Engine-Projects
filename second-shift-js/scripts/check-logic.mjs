/**
 * Guard the `logic.js` contract at build time, so a broken game fails HERE with a
 * clear message instead of at runtime in front of players.
 *
 * Checks, in order of how often they actually bite:
 *   1. all six exports present;
 *   2. `meta` sane (minPlayers <= maxPlayers, both >= 1);
 *   3. no imports — logic.js is pure rules, and an import would not resolve in the
 *      room's module graph the way an author expects;
 *   4. no timers — the room drives time through `wakeIn`/alarms; a setTimeout
 *      inside pure logic silently does nothing useful;
 *   5. no nondeterminism (`Date.now`, `Math.random`) — the room persists and
 *      re-derives these results, so a nondeterministic game desyncs its players.
 */

import { existsSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const app = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const logicPath = resolve(app, "src/logic.js");

// Not every game has rules in this form. A game that brings its own server
// (its room owns the sockets directly) or is client-only has no `logic.js` at
// all, and that is not an error — there is simply nothing for this check to
// say. A game that DOES use the kernel but lost its logic.js still fails, just
// one step later: `src/room.ts` imports "./logic.js", so `tsc` catches it.
if (!existsSync(logicPath)) {
  console.log("no src/logic.js — not a rules game, nothing to check");
  process.exit(0);
}

const REQUIRED = ["meta", "setup", "validateAction", "applyAction", "isGameOver", "viewFor"];

/**
 * Things that BREAK the game. `require` is not defined in the module the bundler
 * produces, and a bare import cannot resolve, so either one fails at runtime.
 */
const FATAL = [
  [/\brequire\s*\(/, "logic.js must not require() anything — it is pure game rules"],
  [/^\s*import\s+[^.\n]/m, "logic.js must not import packages — it is pure game rules"],
];

/**
 * Things that are BAD PRACTICE but do run.
 *
 * These are advice, not correctness: a game using `Date.now()` or
 * `Math.random()` in its rules risks players seeing different state, because
 * the room persists and re-derives results. For a NEW game that is worth
 * stopping the build over — get it right at the start.
 *
 * For a MIGRATED game it is not. The previous engine documented the same rule
 * but never enforced it, and roughly 8% of the games coming over use one of
 * these and have been running in production for months. Refusing to build them
 * would take working games offline to enforce a rule they were never held to,
 * so for those they are reported and the build continues (see MIGRATED below).
 */
const ADVISORY = [
  [/\bset(Timeout|Interval)\s*\(/, "use the room's wakeIn/alarm instead of timers"],
  [/\bDate\s*\.\s*now\s*\(/, "logic should be deterministic — derive time from state"],
  [/\bnew\s+Date\s*\(/, "logic should be deterministic — derive time from state"],
  [/\bMath\s*\.\s*random\s*\(/, "logic should be deterministic — seed randomness in setup()"],
  [/\bfetch\s*\(/, "logic.js has no network access; this call cannot succeed"],
];

// Written by the games migration. Its presence means "this code predates these
// rules" — advisories are then reported without failing the build.
const MIGRATED = existsSync(resolve(app, ".migrated-game"));

const source = await readFile(logicPath, "utf8");

// Strip comments so a rule mentioned in prose (like the ones in the shipped
// logic.js) is not mistaken for real code.
const code = source
  .replace(/\/\*[\s\S]*?\*\//g, "")
  .replace(/(^|[^:])\/\/.*$/gm, "$1");

const problems = [];

for (const [pattern, why] of FATAL) {
  if (pattern.test(code)) problems.push(`${why} (matched ${pattern})`);
}

const advisories = [];
for (const [pattern, why] of ADVISORY) {
  if (pattern.test(code)) (MIGRATED ? advisories : problems).push(`${why} (matched ${pattern})`);
}

const logic = await import(logicPath);
for (const name of REQUIRED) {
  if (!(name in logic)) problems.push(`missing export: ${name}`);
}
for (const name of REQUIRED.slice(1)) {
  if (name in logic && typeof logic[name] !== "function") {
    problems.push(`${name} must be a function`);
  }
}

/**
 * `meta` shape.
 *
 * For a NEW game these are errors: get the contract right at the start.
 *
 * For a MIGRATED one they are not, for the same reason the advisories above are
 * not — the previous engine accepted a looser shape and roughly 7% of the rules
 * games coming over use it, mostly `name` where this contract says `game`, and
 * occasionally `players: [min, max]` instead of the two fields. `src/room.ts`
 * normalises all of that through `resolveMeta()` before anything reads it, so
 * these games run correctly; failing the build would take working games offline
 * over a spelling difference.
 */
const meta = logic.meta;
const metaProblems = [];
if (meta && typeof meta === "object") {
  const { minPlayers, maxPlayers } = meta;
  if (!Number.isInteger(minPlayers) || minPlayers < 1) {
    metaProblems.push("meta.minPlayers must be an integer >= 1");
  }
  if (!Number.isInteger(maxPlayers) || maxPlayers < 1) {
    metaProblems.push("meta.maxPlayers must be an integer >= 1");
  }
  if (Number.isInteger(minPlayers) && Number.isInteger(maxPlayers) && minPlayers > maxPlayers) {
    metaProblems.push("meta.minPlayers must be <= meta.maxPlayers");
  }
  if (typeof meta.game !== "string" || !meta.game.trim()) {
    metaProblems.push("meta.game must be a non-empty display name");
  }
} else if ("meta" in logic) {
  metaProblems.push("meta must be an object");
}
for (const problem of metaProblems) (MIGRATED ? advisories : problems).push(problem);

if (problems.length) {
  console.error("src/logic.js does not satisfy the game contract:\n");
  for (const p of problems) console.error(`  • ${p}`);
  console.error("\nSee AGENTS.md → “The game contract”.");
  process.exit(1);
}

if (advisories.length) {
  console.warn(
    `src/logic.js has ${advisories.length} issue(s) carried over from the games engine:`,
  );
  for (const a of advisories) console.warn(`  ! ${a}`);
  console.warn("  (reported, not fatal: this game predates these rules and already runs)");
}

// Mirrors room.ts's resolveMeta so the summary reads the same as what actually
// runs — a migrated game reaching here may have none of these fields.
const shown = {
  game: [meta?.game, meta?.name, meta?.title].find((v) => typeof v === "string" && v.trim()),
  minPlayers: Number.isInteger(meta?.minPlayers) ? meta.minPlayers : (meta?.players?.[0] ?? 1),
  maxPlayers: Number.isInteger(meta?.maxPlayers) ? meta.maxPlayers : (meta?.players?.[1] ?? 1),
};
console.log(
  `logic.js OK — ${shown.game ?? "Game"} (${shown.minPlayers}-${shown.maxPlayers} players)`,
);
