extends SceneTree

const Model = preload("res://scripts/battle.gd")
var checks := 0
var failed := 0
var bullet_id := 1000
const ROSTER := {1: {"name": "Red", "team": 0}, 2: {"name": "Blue", "team": 1}}

func _initialize() -> void:
	test_reset_and_map()
	test_spawn_reachability()
	test_wide_world()
	test_terrain_collision()
	test_projectiles_and_teams()
	test_base_invulnerability()
	test_respawn_forever()
	test_spawn_occupancy()
	test_authoritative_inputs_and_cadence()
	test_winner_and_restart()
	test_snapshot_and_disconnect()
	test_determinism_and_stress()
	check(checks >= 85, "all multiplayer regression groups executed")
	print("TANK_BATTLE_TESTS: %d checks, %d failures" % [checks, failed])
	quit(1 if failed else 0)

func check(condition: bool, label: String) -> void:
	checks += 1
	if not condition:
		failed += 1
		push_error("FAIL: " + label)
	else:
		print("PASS: " + label)

func fresh(clear_arena: bool = false):
	var b = Model.new()
	b.reset(ROSTER)
	if clear_arena:
		b.terrain.clear()
		b.tanks.clear()
		for p in b.players.values():
			p.respawn_at = -1
	return b

func bullet(pos: Vector2, direction: int = 0, team: int = 0, owner: int = -1) -> Dictionary:
	bullet_id += 1
	return {"id": bullet_id, "pos": pos, "dir": direction, "team": team,
		"owner": owner, "speed": Model.BULLET_SPEED, "dead": false}

func wall(b, pos: Vector2i, kind: String) -> void:
	for y in range(2):
		for x in range(2):
			b.terrain[pos * 2 + Vector2i(x, y)] = kind

func advance(b, ticks: int, inputs: Dictionary = {}) -> void:
	for _i in range(ticks):
		b.update(Model.STEP, inputs)

func test_reset_and_map() -> void:
	var b = Model.new()
	check(b.state == "lobby" and b.players.is_empty() and b.tanks.is_empty(), "lobby has no autonomous tanks")
	check(b.bases.size() == 2 and b.bases[0].hp == 5 and b.bases[1].hp == 5, "both bases start at configured HP")
	b.reset(ROSTER)
	check(b.state == "playing" and b.players.size() == 2 and b.tanks.size() == 2, "reset spawns only roster humans")
	check(b.tank_for(1).team == 0 and b.tank_for(2).team == 1, "roster owns tank team")
	check(b.tank_for(1).pos.y == 16 and b.tank_for(2).pos.y == 400, "red top and blue bottom spawn")
	check(b.tank_for(1).shield == 2.0 and b.tank_for(2).shield == 2.0, "both initial players receive shield")
	var symmetric := true
	for y in range(Model.ROWS):
		for x in range(Model.COLUMNS):
			if Model.MAP[y][x] != Model.MAP[Model.ROWS-1-y][x] or Model.MAP[y][x] != Model.MAP[y][Model.COLUMNS-1-x]:
				symmetric = false
	check(symmetric, "arena has identical horizontal and vertical mirror geometry")
	for team in range(2):
		check(b.can_occupy(b.spawn_points(team)[1]), "team %d alternate spawn is open" % team)
	var idle_positions := [b.tank_for(1).pos, b.tank_for(2).pos]
	advance(b, 600)
	check(b.tanks.size() == 2 and b.bullets.is_empty(), "ten idle seconds never spawn AI or auto-fire")
	check(b.tank_for(1).pos == idle_positions[0] and b.tank_for(2).pos == idle_positions[1], "idle humans do not move")

func test_spawn_reachability() -> void:
	var b = fresh(true)
	# Brick is destructible, unlike steel and water. Check routes in the fully breached map.
	b._load_terrain()
	for cell in b.terrain.keys():
		if b.terrain[cell] == "B":
			b.terrain.erase(cell)
	for team in range(2):
		var goal := Vector2i(Model.COLUMNS / 2, Model.ROWS - 2 if team == 0 else 1)
		var queue: Array[Vector2i] = [goal]
		var seen := {goal: true}
		var index := 0
		while index < queue.size():
			var current: Vector2i = queue[index]
			index += 1
			for direction in Model.DIRS:
				var cell := current + Vector2i(direction)
				if seen.has(cell) or not b.can_occupy(Vector2(cell * 32) + Vector2(16, 16), -1, false):
					continue
				seen[cell] = true
				queue.append(cell)
		for i in range(b.spawn_points(team).size()):
			var point: Vector2 = b.spawn_points(team)[i]
			var spawn_cell := Vector2i(point / 32)
			check(seen.has(spawn_cell), "team %d spawn %d can reach enemy base attack lane after brick breach" % [team, i])

func test_wide_world() -> void:
	var b = fresh(true)
	check(Model.WIDTH == 736 and Model.HEIGHT == 416, "all peers share fixed 736 by 416 world dimensions")
	check(b.bases[0].pos.x == 352 and b.bases[1].pos.x == 352, "both bases remain centered in widened arena")
	check(b.spawn_points(0)[0] == Vector2(208, 16) and b.spawn_points(1)[0] == Vector2(208, 400), "original spawn geometry shifts equally by 160 pixels")
	check(not b.can_occupy(Vector2(40, 5)) and not b.can_occupy(Vector2(40, Model.HEIGHT - 4)), "height remains independent from widened horizontal bounds")
	check(b.can_occupy(Vector2(500, 200)) and b.can_occupy(Vector2(720, 200)), "right wing is authoritative playable space, not decorative fill")
	var tank: Dictionary = b.spawn_tank(1, Vector2(410, 200), 0, 0)
	check(b.move_tank(tank, Vector2(20, 0)) and tank.pos.x == 430, "tank crosses old square width without invisible wall")
	check(not b.move_tank(tank, Vector2(400, 0)), "tank cannot cross new right world edge")
	b.bullets.append(bullet(Vector2(410, 150), 1))
	b.update_bullets(0.05)
	check(b.bullets.size() == 1 and b.bullets[0].pos.x > 416, "projectile crosses old square width")
	b.bullets.clear()
	b.bullets.append(bullet(Vector2(Model.WIDTH - 2, 150), 1))
	b.update_bullets(0.05)
	check(b.bullets.is_empty(), "projectile expires at rectangular right edge")
	b.tanks.clear()
	b._load_terrain()
	var outer_terrain := 0
	for cell in b.terrain:
		if cell.x < 10 or cell.x >= 36:
			outer_terrain += 1
	check(outer_terrain > 80, "both new playable wings contain authoritative cover")
	# Without destroying anything, the two outer lanes connect to the center on
	# both ends and can reach one another through the middle crossing.
	var start := Vector2i(0, 0)
	var queue: Array[Vector2i] = [start]
	var seen := {start: true}
	var index := 0
	while index < queue.size():
		var current: Vector2i = queue[index]
		index += 1
		for direction in Model.DIRS:
			var cell := current + Vector2i(direction)
			if seen.has(cell) or not b.can_occupy(Vector2(cell * 32) + Vector2(16, 16), -1, false):
				continue
			seen[cell] = true
			queue.append(cell)
	for cell in [Vector2i(0, 12), Vector2i(22, 0), Vector2i(22, 12), Vector2i(11, 6), Vector2i(5, 0), Vector2i(17, 12)]:
		check(seen.has(cell), "wide-world open route reaches %s without destroying cover" % cell)
	# Explicit sentinels at both extreme columns detect a stale square stride.
	b.terrain[Vector2i(0, 25)] = "W"
	b.terrain[Vector2i(45, 25)] = "B"
	var snap: Dictionary = b.snapshot()
	var client = Model.new()
	client.apply_snapshot(snap)
	check(client.terrain == b.terrain and client.terrain[Vector2i(45, 25)] == "B", "full terrain round trip preserves far wing cells and row stride")


func test_terrain_collision() -> void:
	var b = fresh(true)
	for kind in ["B", "S", "W", "G"]:
		b.terrain.clear()
		wall(b, Vector2i(2, 2), kind)
		check(b.can_occupy(Vector2(80, 80)) == (kind == "G"), "%s tank collision" % kind)
	b.terrain.clear()
	check(not b.can_occupy(Vector2(5, 40)) and not b.can_occupy(Vector2(Model.WIDTH - 4, 40)), "arena boundaries contain tanks")
	check(not b.can_occupy(Vector2(Model.WIDTH / 2, 16)) and not b.can_occupy(Vector2(Model.WIDTH / 2, Model.HEIGHT - 16)), "both bases block tanks")
	var t: Dictionary = b.spawn_tank(1, Vector2(80, 80), 0)
	check(not b.can_occupy(t.pos) and b.can_occupy(t.pos, 1), "tank occupancy respects own ID")
	b.tanks.clear()
	wall(b, Vector2i(2, 2), "B")
	var shot := bullet(Vector2(80, 65), 2)
	check(b.hit_terrain(shot) and shot.dead and b.terrain.size() == 2, "brick hit removes half-depth course")
	check(not b.can_occupy(Vector2(80, 80)), "half brick retains collision")
	b.hit_terrain(bullet(Vector2(80, 81), 2))
	check(b.terrain.is_empty(), "second hit clears brick tile")
	wall(b, Vector2i(2, 2), "S")
	shot = bullet(Vector2(80, 65), 2)
	check(b.hit_terrain(shot) and b.terrain.size() == 4, "steel remains indestructible")
	for kind in ["W", "G"]:
		b.terrain.clear()
		wall(b, Vector2i(2, 2), kind)
		shot = bullet(Vector2(80, 80), 2)
		check(not b.hit_terrain(shot) and not shot.dead, "%s passes projectiles" % kind)
	b.terrain.clear()
	wall(b, Vector2i(2, 2), "S")
	b.bullets.append(bullet(Vector2(80, 50), 2))
	b.update_bullets(0.2)
	check(b.bullets.is_empty() and b.terrain.size() == 4, "microsteps prevent fast projectile tunnelling")

func test_projectiles_and_teams() -> void:
	var b = fresh(true)
	b.bullets.append(bullet(Vector2(100, 100), 1, 0))
	b.bullets.append(bullet(Vector2(110, 100), 3, 1))
	b.update_bullets(0.05)
	check(b.bullets.is_empty(), "opposing projectiles mutually cancel")
	b.bullets.append(bullet(Vector2(100, 100), 1, 0))
	b.bullets.append(bullet(Vector2(110, 100), 3, 0))
	b.update_bullets(0.05)
	check(b.bullets.size() == 2, "friendly projectiles do not cancel")
	b.bullets.clear()
	var t: Dictionary = b.spawn_tank(1, Vector2(80, 80), 0, 0)
	b.bullets.append(bullet(Vector2(80, 100), 0, 0, 1))
	b.update_bullets(0.05)
	check(not b.tank_for(1).is_empty() and b.players[1].deaths == 0, "friendly projectile cannot hurt tank")
	b.bullets.clear()
	b.bullets.append(bullet(Vector2(80, 100), 0, 1, 2))
	b.update_bullets(0.05)
	check(b.tank_for(1).is_empty() and b.players[1].deaths == 1, "enemy projectile kills unshielded tank")
	check(b.players[2].kills == 1 and b.players[1].respawn == 2.0, "kill and death counters replicate without finite lives")
	check(not b.damage_tank(t, 2) and b.players[2].kills == 1, "dead tank cannot award duplicate kill")
	for team in range(2):
		var center: Vector2 = b.base_rect(team).get_center()
		b.bullets.append(bullet(center, 0, team, 1 if team == 0 else 2))
		b.update_bullets(Model.STEP)
		check(b.bases[team].hp == 5 and b.bullets.is_empty(), "team %d base absorbs friendly fire without damage" % team)

func test_base_invulnerability() -> void:
	var b = fresh(true)
	check(b.damage_base(0) and b.bases[0].hp == 4 and b.bases[0].shield == 1.0, "first base hit grants one-second shield")
	check(not b.damage_base(0) and b.bases[0].hp == 4, "same-tick hit is rejected")
	advance(b, 59)
	check(not b.damage_base(0) and b.bases[0].shield > 0.0, "base invulnerable through tick 59")
	advance(b, 1)
	check(b.bases[0].shield == 0.0 and b.damage_base(0) and b.bases[0].hp == 3, "base vulnerable exactly on tick 60")
	check(b.bases[1].hp == 5 and b.bases[1].shield == 0.0, "base invulnerability is independent per team")
	for hit in range(3):
		advance(b, 60)
		check(b.damage_base(0), "spaced base hit %d applies" % (hit + 3))
	b.update(Model.STEP)
	check(b.state == "ended" and b.winner == 1 and b.bases[0].hp == 0, "five accepted hits destroy base and blue wins")
	check(not b.damage_base(0) and b.bases[0].hp == 0, "destroyed base HP never underflows")

func test_respawn_forever() -> void:
	var b = fresh()
	check(not b.damage_tank(b.tank_for(1), 2), "spawn shield blocks direct damage")
	advance(b, 119)
	check(b.tank_for(1).shield > 0 and not b.damage_tank(b.tank_for(1), 2), "spawn shield lasts through tick 119")
	advance(b, 1)
	check(b.tank_for(1).shield == 0.0, "player shield expires exactly at tick 120")
	for death in range(10):
		check(b.damage_tank(b.tank_for(1), 2), "death %d remains possible" % (death + 1))
		advance(b, 119)
		check(b.tank_for(1).is_empty() and b.state == "playing", "death %d does not end match or respawn early" % (death + 1))
		advance(b, 1)
		check(not b.tank_for(1).is_empty() and b.tank_for(1).shield == 2.0, "death %d respawns at 2s with full shield" % (death + 1))
		advance(b, 120)
	check(b.players[1].deaths == 10 and b.players[2].kills == 10 and b.state == "playing", "ten deaths never exhaust lives")

func test_spawn_occupancy() -> void:
	var b = fresh(true)
	var points: Array[Vector2] = b.spawn_points(0)
	b.spawn_tank(99, points[0], 1)
	check(b.try_respawn(1) and b.tank_for(1).pos != points[0], "occupied preferred spawn uses alternate point")
	b.tanks.clear()
	for i in range(points.size()):
		b.spawn_tank(100 + i, points[i], 1)
	check(not b.try_respawn(1) and b.tank_for(1).is_empty(), "all occupied spawns postpone without overlap")
	check(b.players[1].respawn_at == b.tick + 1, "blocked spawn retries next tick")
	b.tanks.clear()
	advance(b, 1)
	check(not b.tank_for(1).is_empty(), "cleared spawn immediately resumes pending respawn")
	var roster := {}
	for id in range(1, 9):
		roster[id] = {"name": "P%d" % id, "team": (id - 1) % 2}
	b.reset(roster)
	var safe: bool = b.tanks.size() == 8
	for tank in b.tanks:
		safe = safe and b.can_occupy(tank.pos, tank.id)
	check(safe, "eight human tanks spawn without overlap or solid terrain")

func test_authoritative_inputs_and_cadence() -> void:
	var b = fresh(true)
	var p: Dictionary = b.spawn_tank(1, Vector2(40, 80), 0, 0)
	b.spawn_tank(2, Vector2(300, 300), 1, 0)
	advance(b, 60, {1: {"dir": 1, "fire": false}})
	check(absf(p.pos.x - 146.0) < 0.01, "movement uses authoritative speed, not client position")
	check(b.tank_for(2).pos == Vector2(300, 300), "input dictionary cannot move unrelated tank")
	var before: Vector2 = p.pos
	advance(b, 1, {1: {"dir": 99, "fire": 1, "pos": Vector2.ZERO, "team": 1}, 999: {"dir": 1, "fire": true}})
	check(p.pos == before and p.team == 0 and b.bullets.is_empty(), "malformed direction/fire and spoofed attributes are ignored")
	advance(b, 1, {1: "invalid"})
	check(p.pos == before, "non-dictionary command safely ignored")
	check(b.fire(p) and not b.fire(p), "same-tick fire spam rejected")
	advance(b, 16)
	check(not b.fire(p), "reload still active on tick 16")
	advance(b, 1)
	check(b.fire(p), "reload opens exactly on tick 17")
	advance(b, 17)
	check(not b.fire(p) and b.bullets.size() == 2, "third concurrent bullet is rejected")
	b.bullets.clear()
	check(b.fire(p), "bullet slot returns after projectile removed")
	var prior_tick: int = b.tick
	b.update(INF)
	b.update(NAN)
	b.update(-1)
	check(b.tick == prior_tick, "invalid timesteps do not advance simulation")
	b.update(100)
	check(b.tick == prior_tick + 15, "large timestep capped to bounded work")

func test_winner_and_restart() -> void:
	var b = fresh(true)
	b.bases[0].hp = 1
	b.bases[1].hp = 1
	b.bullets.append(bullet(Vector2(Model.WIDTH / 2, 33), 0, 1, 2))
	b.bullets.append(bullet(Vector2(Model.WIDTH / 2, Model.HEIGHT - 33), 2, 0, 1))
	advance(b, 1)
	check(b.state == "ended" and b.winner == 2, "same-tick mutual base destruction is deterministic draw")
	var end_tick: int = b.tick
	advance(b, 100, {1: {"dir": 1, "fire": true}})
	check(b.tick == end_tick, "terminal state freezes combat without auto-restart")
	b.reset(ROSTER)
	check(b.state == "playing" and b.winner == -1 and b.tick == 0 and b.elapsed == 0, "rematch resets clock and winner")
	check(b.bullets.is_empty() and b.effects.is_empty() and b.events.is_empty(), "rematch clears every transient entity")
	check(b.bases[0].hp == 5 and b.bases[1].hp == 5 and b.terrain.size() > 100, "rematch restores bases and destructible terrain")
	check(b.players[1].kills == 0 and b.players[1].deaths == 0 and b.players[1].respawn == -1, "rematch resets scores and respawn schedules")

func test_snapshot_and_disconnect() -> void:
	var b = fresh()
	advance(b, 20, {1: {"dir": 1, "fire": true}})
	b.damage_base(1)
	var snap: Dictionary = b.snapshot()
	check(snap.terrain is PackedByteArray and snap.terrain.size() == Model.TERRAIN_COLUMNS * Model.TERRAIN_ROWS, "snapshot packs complete 46 by 26 rectangular terrain")
	var client = Model.new()
	client.apply_snapshot(snap)
	check(client.snapshot() == snap, "snapshot round trip preserves full authoritative state")
	check(client.terrain == b.terrain and client.players == b.players, "terrain and scores are replicated")
	var host_hp: int = b.bases[1].hp
	client.bases[1].hp = 1
	client.terrain.clear()
	check(b.bases[1].hp == host_hp and not b.terrain.is_empty(), "snapshot copies cannot mutate host simulation")
	b.remove_player(1)
	check(not b.players.has(1) and b.tank_for(1).is_empty(), "disconnect removes tank and roster entry")
	var owner_bullets := false
	for shot in b.bullets:
		owner_bullets = owner_bullets or shot.owner == 1
	check(not owner_bullets, "disconnect removes departing player's projectiles")
	advance(b, 180)
	check(b.tank_for(1).is_empty(), "disconnected human never respawns")

func test_determinism_and_stress() -> void:
	var a = fresh(true)
	var b = fresh(true)
	for model in [a, b]:
		model.spawn_tank(1, Vector2(40, 80), 0, 0)
		model.spawn_tank(2, Vector2(350, 300), 1, 0)
	for _i in range(30):
		a.update(1.0 / 30.0, {1: {"dir": 1, "fire": false}})
	for _i in range(60):
		b.update(1.0 / 60.0, {1: {"dir": 1, "fire": false}})
	check(a.snapshot() == b.snapshot(), "30/60Hz caller cadence yields identical fixed-tick simulation")
	var roster := {}
	for id in range(1, 9):
		roster[id] = {"name": "Human input fixture %d" % id, "team": (id - 1) % 2}
	a.reset(roster)
	b.reset(roster)
	var rng := RandomNumberGenerator.new()
	rng.seed = 73429
	var safe := true
	var deterministic := true
	var commands := {}
	for step in range(3600):
		if step % 19 == 0:
			for id in roster:
				commands[id] = {"dir": rng.randi_range(-1, 3), "fire": true}
		a.update(Model.STEP, commands)
		b.update(Model.STEP, commands)
		for tank in a.tanks:
			safe = safe and a.can_occupy(tank.pos, tank.id)
		if step % 120 == 0:
			deterministic = deterministic and a.snapshot() == b.snapshot()
		if a.state == "ended":
			a.reset(roster)
			b.reset(roster)
	check(safe, "eight-player scripted input stress preserves all collision geometry")
	check(deterministic, "identical human-input fixtures produce deterministic snapshots")
	check(a.tanks.size() <= 8 and a.bullets.size() <= 16, "stress stays within player and per-owner bullet caps")
