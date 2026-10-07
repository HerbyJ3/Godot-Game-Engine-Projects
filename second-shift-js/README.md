# Second Shift — game source export

A marriage-themed time-management game (Delicious / Diner Dash style).
Level 1: "Her Morning" — laundry, cooking, and baby-changing chains.

## Layout

```
src/
  logic.js      # ALL game rules — pure functions, deterministic, seeded RNG
  logic.d.ts    # types for the logic contract
  room.ts       # Durable Object: one room per player, WebSocket fan-out
  worker.ts     # Cloudflare Worker entry (serves /ws/<room>)
  protocol.ts   # wire protocol shared by room + tests
  env.ts        # bindings
public/
  index.html    # page shell (canvas + palette)
  client.js     # the whole renderer: painted art, sprites, HUD, input, audio
  art/          # generated painted background + Ruth sprite frames
  audio/        # generated SFX (ambience, serve, chain, fail, alert, tick, buffer)
scripts/
  build.mjs     # bundles worker -> dist/worker, copies public -> dist/client
  check-logic.mjs # enforces the six-export pure contract on logic.js
tests/
  logic-offline.test.ts # pure-function chain/timer/collision tests
  secondshift.test.ts   # wire tests over real WebSockets (workerd)
  room.test.ts          # protocol / persistence / isolation
  boot.test.ts          # client boot flow
```

## Key concepts

- `src/logic.js` exports exactly six functions: `meta, setup, validateAction,
  applyAction, isGameOver, viewFor`. No imports, no Date.now(), no
  Math.random() — randomness is a seeded RNG carried in state, and time only
  advances via the client-reported `dtMs` on each action (clamped to 500ms).
- Tasks are data: the `TASKS` table defines every chain (steps, wait timers,
  patience, points). Adding a task = new TASKS entry + art. `OBJECTS`,
  `NODES`/`EDGES` (orthogonal walkway graph), `FOOTPRINTS` (collision), and
  `OBJECT_NODE`/`OBJECT_FACING` (anchors) drive movement and interaction.
- `public/client.js` is dependency-free canvas rendering: it draws the painted
  background, depth-sorted foreground cutouts, the sprite character with an
  animation state machine (idle/walk/work/finish), thought-bubble HUD, and
  sends `{type:"action", action:{..., dtMs}}` over the socket.

## Run locally

Requires [bun](https://bun.sh) (or use npm/npx equivalents) and wrangler.

```sh
bun install
bun run build        # check:logic + tsc + bundle to dist/
npx wrangler dev     # local dev server on workerd (uses wrangler.jsonc)
npx vitest run tests # full suite through real workerd
```

Open the printed localhost URL. The game connects to `ws://…/ws/solo-<id>`.

## Deploying back

This export is a snapshot. The live deployment (second-shift-game.higgsfield.app)
builds from the platform-managed repo — to ship changes, send the edited files
back through the Higgsfield chat and they'll be committed + deployed there.
