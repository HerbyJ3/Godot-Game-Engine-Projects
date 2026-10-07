/**
 * The client→server wire boundary.
 *
 * Every frame here arrives from a browser we do not control, so nothing about it
 * may be assumed: TypeScript types are erased at runtime, and a `JSON.parse`
 * result typed as a message is a lie until it has been checked. `parseClientMessage`
 * is the one place that turns an untrusted frame into a value the room may act on.
 *
 * Hand-written rather than a schema library (zod et al.) on purpose: this template
 * is deliberately dependency-free so that `bun install` is instant and a game's
 * build can't fail on a transitive dependency — and the accepted shape is three
 * tiny messages that are fully covered by the checks below. If you grow the
 * protocol into something with nested or conditional payloads, switch to zod
 * rather than extending this by hand.
 */

/** A frame larger than this is refused unread. */
const MAX_FRAME_BYTES = 16 * 1024;

/** Longest accepted playerId. Truncating rather than rejecting matches the
 *  previous engine, so existing clients keep working. */
const MAX_PLAYER_ID = 64;

/**
 * `action` payloads are deliberately opaque — the game's own
 * `logic.validateAction` is the authority on what a legal action looks like, and
 * this layer must not second-guess it. It is still bounded: an action is
 * persisted into room storage, so an unbounded one is a storage-growth vector
 * rather than a game bug.
 */
const MAX_ACTION_BYTES = 4 * 1024;

export type ClientMessage =
  | { type: "join"; playerId: string }
  | { type: "action"; action: unknown }
  | { type: "reset" };

export type ParseResult =
  | { ok: true; msg: ClientMessage }
  | { ok: false; error: string };

function isRecord(v: unknown): v is Record<string, unknown> {
  return typeof v === "object" && v !== null && !Array.isArray(v);
}

/**
 * Validate one raw frame. Binary frames are ignored (the protocol is JSON text);
 * every rejection carries a reason the client can act on, and never echoes the
 * offending input back.
 */
export function parseClientMessage(raw: string | ArrayBuffer): ParseResult {
  if (typeof raw !== "string") return { ok: false, error: "expected a text frame" };
  // Compare bytes, not UTF-16 units: a multi-byte payload is bigger than
  // `raw.length` suggests.
  if (new TextEncoder().encode(raw).byteLength > MAX_FRAME_BYTES) {
    return { ok: false, error: "message too large" };
  }

  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return { ok: false, error: "invalid json" };
  }
  if (!isRecord(parsed)) return { ok: false, error: "expected a json object" };

  switch (parsed.type) {
    case "join": {
      // Accept a string or a number (some existing clients send numeric ids);
      // anything else is a bug, not a stringifiable id.
      const rawId = parsed.playerId;
      if (typeof rawId !== "string" && typeof rawId !== "number") {
        return { ok: false, error: "playerId required" };
      }
      const playerId = String(rawId).slice(0, MAX_PLAYER_ID);
      if (!playerId) return { ok: false, error: "playerId required" };
      return { ok: true, msg: { type: "join", playerId } };
    }
    case "action": {
      if (!("action" in parsed)) return { ok: false, error: "action required" };
      // Bounded by its SERIALIZED size — that is what actually lands in storage.
      let size: number;
      try {
        size = new TextEncoder().encode(JSON.stringify(parsed.action) ?? "").byteLength;
      } catch {
        // Non-serializable (a cycle); it could never be persisted.
        return { ok: false, error: "action is not serializable" };
      }
      if (size > MAX_ACTION_BYTES) return { ok: false, error: "action too large" };
      return { ok: true, msg: { type: "action", action: parsed.action } };
    }
    case "reset":
      return { ok: true, msg: { type: "reset" } };
    default:
      return { ok: false, error: `unknown message type: ${String(parsed.type)}` };
  }
}
