# Verification

## Automated simulation regression

Verified locally on 2026-10-27 with Godot 4.7.2 stable:
**93 checks, 0 failures**, with no engine/script error output.

The suite caught and verified fixes for a supply spawning inside brick terrain
and a near-waypoint floating-point oscillation that could strand a center-lane
armored enemy.

Run from the project directory with Godot 4.x:

```sh
GODOT_BIN=/path/to/godot tests/run_tests.sh
```

The runner creates isolated temporary XDG data/cache/config directories, executes
`tests/test_battle.gd` headlessly, and fails on engine/script errors as well as
assertion failures. Checking only Godot's exit status is insufficient: script
exceptions can otherwise finish with exit code zero.

The regression suite exercises the actual `scripts/battle.gd` simulation, not a
separate implementation of its rules. Isolated collisions use controlled setups;
route/breach and stress cases advance the normal simulation tick.

### Covered behavior

- Title initialization; pause/resume; simulation, shield, reload, respawn,
  spawn, effect, bullet, and supply timer freezing.
- Full restart cleanup: counters, base, terrain, actors, effects, bullets,
  supplies, and pending events.
- Tank boundaries and tank/tank, base, brick, steel, water, and grass collision.
- Brick half-course destruction and passage opening; indestructible steel;
  bullets passing over water and through grass.
- Opposing bullet cancellation, same-team bullet coexistence, player friendly-fire
  protection, protected headquarters, hostile base destruction, and microstep
  protection against fast bullet tunneling.
- Enemy armor damage/score, player three-life exhaustion, delayed respawn,
  spawn invulnerability, alternate respawn placement, and occupied-lane retries.
- Reachable shield supplies and one-time pickup score/protection.
- Occupied enemy spawn postponement, four-enemy active cap, exactly twenty
  finite-wave enemies, and victory only after the final live enemy is gone.
- A* routes from all three spawn lanes, rejecting water/steel and pricing bricks.
- 30/60 Hz movement equivalence; reload and per-tank active bullet limits.
- Unopposed headquarters breach for all four enemy roles from all three lanes.
- Regression for near-waypoint floating-point corner oscillation.
- Five simulated minutes of deterministic rapid random turns, firing, loss and
  repeated restarts; no arena/wall/tank overlap or invalid life/wave counts.

## Scope limits

These are local headless simulation tests, not CI status and not native rendering,
keyboard event, window resizing, audio-listening, accessibility, or gameplay
balance certification. Native game review and repository publication checks are
tracked separately by the implementation task. No multiplayer, campaign, or
platform export coverage is claimed.

## Native desktop verification (main task)

- Existing supported dot cloud desktop, inherited `DISPLAY=:0`; no new X server or display-security changes.
- Godot 4.7.2, OpenGL compatibility / Mesa llvmpipe.
- `tests/native_capture.gd` loads the real main scene and injects actual Godot input events: Enter, held Up + Space, P, R.
- Verified live movement/fire, pause freezing elapsed simulation time for 60 physics frames, reset to 3 lives/0 kills/0 spawned, and resize from 1180×812 to 900×600 with preserved arena aspect ratio.
- Inspected actual viewport PNGs for title, gameplay, paused and resized states; no clipped Chinese UI or overlapping controls found.
- Victory and defeat **layout fixtures** were inspected separately; these screenshots are not evidence of a human-played full clear. The 20-enemy clear conditions are covered by the model regression suite.
- Captures were rendered with the Dummy audio driver; synthesis construction was exercised but speaker playback/listening was not verified.
- Desktop driver reports unsupported V-Sync mode; rendering continues normally. No script errors in final native capture log.

To reproduce native capture on an already available desktop:

```sh
TANK_CAPTURE_DIR=/absolute/writable/output godot --path . --script res://tests/native_capture.gd
```

The output directory contains screenshots only and is not included in the source repository. No exported binaries or ZIP deliverable is required.
