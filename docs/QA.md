# Full-field multiplayer verification

Verified **2026-10-28** on the dot cloud computer with native **Godot 4.7.2 stable**. Local tests are not GitHub CI.

## Deterministic production model: 160 checks, 0 failures

```sh
GODOT_BIN=/path/to/godot tests/run_tests.sh
```

- Only 2–8 roster humans; no autonomous tanks, AI or automatic firing.
- Unlimited respawns including ten successive deaths; exact 120-tick delay and 120-tick player protection; occupied spawns retry without overlap.
- Base 5 HP, independent exact 60-tick protection, same-tick repeated-hit rejection, friendly-fire protection, simultaneous base destruction draw.
- Symmetric **736×416** authoritative arena; original central geometry shifted equally by 160 pixels, mirrored playable wings with brick/steel/water/grass cover. Every spawn reaches the enemy attack lane after brick breach; outer corridors and central crossing connect without destruction.
- Tanks and projectiles cross the old x416 boundary; new width/height independently constrain motion. Far-wing terrain survives the complete **46×26 / 1,196-byte** packed-terrain snapshot round trip.
- Half-brick damage, steel, water, grass, occupancy, projectile microsteps/cancellation, input validation, fire cadence, two-projectile limit.
- Rematch cleanup, snapshot deep copies, disconnect cleanup, 30/60 Hz caller equivalence and eight-player scripted-input stress.

## Genuine ENet integration: 2/2 cases passed

```sh
GODOT_BIN=/path/to/godot python3 tests/run_network_tests.py --players 2 8
```

Final wide-world run: **152 peer assertions**, **1,709 identical full-state host/client snapshots**, zero mismatches/errors; maximum compressed state **817 bytes**. Protocol is now **2** so old square-world clients are rejected rather than interpreting an incompatible terrain stride.

Real separate Godot processes use UDP/ENet, not hotseat or fake transport. Tests cover balanced rooms, ready/host-only start, four-player team cap, ninth-player/full-room rejection, mid-match join rejection, spoofed/stale/malformed input, firing/terrain damage, base HP/protection, death/respawn, far-wing movement/firing replication, rematch and host/client disconnects.

**Fixture boundary:** Host-only test setup places the firing human in clear lanes, invokes a death and finishes the first match. Actual movement/fire still traverse client RPCs. The visible firing segment extends into the far-right corridor to avoid missing short-lived bullets on a slow-starting peer. This is replication evidence, not an eight-person balance playtest.

## Native desktop rendering/input: real host + separate client

`tests/native_capture.gd` runs on the existing supported dot desktop (`DISPLAY=:0`), with a separate real ENet client from `tests/native_peer.gd`. No new display server, display security, firewall or port-forwarding settings are changed.

- Actual viewport PNGs at **1280×720**, **800×800** and **640×900**; no sidebar, decorative arena frame, tank selection frame or shield rectangles.
- Native canvas equals physical window; camera uniformly fits the entire shared rectangle, retaining both bases and all playable lanes. Width/aspect changes never alter server coordinates or collision bounds. Non-wide windows show continuous, visibly impassable forest outside the arena rather than black padding or deceptively playable empty ground.
- Small translucent red/blue base-HP overlays and a corner menu stay inside every viewport. Lobby and modal content remain centered and readable.
- Player invulnerability dims the **whole tank sprite** from 100% to 28% opacity at approximately **3 Hz**, gated only by authoritative protection state. The local-player identifier is one tiny dot, not a frame.
- Bright/dim tank captures use the live initial protection timer. A clearly marked host-only base-damage fixture invokes the real damage function; base-symbol bright/dim captures retain its 4/5 HP display. Neither visual effect grants protection.
- Native keyboard events move/fire the host tank; both real peers participate. Mouse motion/down/up hits the resized HUD button at each aspect ratio. Menu opening suppresses even held Space fire input; repeated Escape returns correctly.
- Simulation continues behind local menu. Leave confirmation/Cancel preserves the match. Confirmed return-to-room keeps peers connected; client readies again and clean rematch resets bases/scores. Client exits after host closes.

Harness input is explicitly flushed before GUI assertions: physics catch-up frames alone are not evidence that buffered mouse/key events have been delivered. Final run: **56 native assertions passed**. Completion marker: `NATIVE_MULTIPLAYER_QA: PASS`.

## Limits

- Loopback integration does not establish public-internet/NAT reachability, high-latency behavior, packet-loss tolerance or cross-machine connectivity.
- No real eight-person balance/usability session, host migration, authentication, encryption, anti-DDoS or latency-compensation claim.
- Native OpenGL compatibility uses Mesa llvmpipe / Dummy audio. Sound synthesis constructs; speaker playback was not auditioned. Existing driver warns that V-Sync mode cannot be changed; rendering continues.
- Prior version also tested 3-player IPv4 and 2-player IPv6; those extra cases are not claimed as rerun for this layout change.
- Remote commit and exact-SHA Actions/check status are verified separately at publication. No checks means **no CI configured/reported**, not a pass.
- No binary build, export package or source ZIP is created.
