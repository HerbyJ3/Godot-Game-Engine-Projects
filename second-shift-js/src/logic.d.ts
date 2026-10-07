/**
 * Types for the `logic.js` contract — the six exports the room calls.
 *
 * `logic.js` stays plain JavaScript on purpose: it is the file a game author (or
 * an agent) rewrites, it must contain no imports and no timers, and keeping it
 * dependency- and syntax-light means it can be swapped wholesale without a build
 * step in the loop. This declaration file is what gives it type-checking anyway.
 *
 * Every function must be PURE: same inputs → same outputs, no `Date.now()`, no
 * `Math.random()`, no I/O. The room persists whatever `setup`/`applyAction`
 * return, so state must be JSON-serializable.
 */

/** Static description of the game, read by the room and sent to clients. */
export const meta: {
  /** Display name. */
  game: string;
  /** Below this many seated players the room stays in "waiting". */
  minPlayers: number;
  /** Players beyond this join as spectators. */
  maxPlayers: number;
};

/** Build the initial state for these seated players (in join order). */
export function setup(players: string[]): unknown;

/**
 * May `playerId` play `action` against `state`? Called BEFORE any mutation, and
 * it is the only thing standing between an untrusted client and the state — be
 * strict here (whose turn it is, whether the move is in range, whether the cell
 * is free). Never mutate `state`.
 */
export function validateAction(
  state: unknown,
  playerId: string,
  action: unknown,
): { ok: true } | { ok: false; error?: string };

/**
 * Apply an already-validated action and return the NEW state. Treat `state` as
 * immutable — copy what you change.
 */
export function applyAction(state: unknown, playerId: string, action: unknown): unknown;

/** Has the game ended? Anything extra returned is echoed to clients as `result`. */
export function isGameOver(
  state: unknown,
): { over: false } | { over: true; winner?: string | null; [key: string]: unknown };

/**
 * What `playerId` is allowed to see. Anything omitted here is invisible to that
 * client, which is how hidden information (hands, fog of war) is enforced — the
 * full state is never sent to anyone.
 */
export function viewFor(state: unknown, playerId: string): unknown;
