# Second Shift — Her Morning

A time-management game in the Delicious / Diner Dash tradition, with the frame
turned on the housewife's morning. Three demand chains run at once — laundry
(basket → washer → detergent → dial → dryer), cooking (fridge → chop → stove,
with a burn window → plate → table), and baby-changing — while the phone rings
with family, the kids act up, and one bar drains quietly in the corner.

The couch is the only station that is hers. It is worth the fewest points in
the game. That deferral is the design, not a balance bug.

## Running it

Godot 4.4 or newer. Open the project and press F5, or:

```sh
godot --path .
```

Click a room and follow the glow. Wrong clicks never punish. ESC pauses.

## How it is built

`scripts/logic.gd` is the entire game: six pure functions over a
JSON-serializable state dictionary, with the world tables (walkway graph,
furniture footprints, task chains) beside it in `scripts/logic_data.gd`.
Nothing in it reads a clock or an RNG — time arrives as a `dtMs` from the
caller, and randomness is a seeded generator carried in the state. The same
player id therefore always plays the same morning.

Everything else is presentation. `Session` ticks the rules once per frame and
publishes a view; the renderer reads that view and nothing else.

This shape is inherited: the game began on an AI platform's multiplayer
template, where those six functions ran server-side in a Cloudflare Durable
Object. The game is single-player, so the port dropped the server and kept the
contract — it is what makes the rules testable, replayable, and diffable
against the original JavaScript, which is still in `../second-shift-js/`.

## Tests

```sh
godot --headless --path . --script res://tests/run_tests.gd
```

See `HANDOFF.md` for the JavaScript-parity trace and the full-playthrough smoke
test, and `CLAUDE.md` for the rules that keep the logic layer pure.
