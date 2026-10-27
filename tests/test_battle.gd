extends SceneTree

const Model = preload("res://scripts/battle.gd")
var checks := 0
var failed := 0

func _initialize() -> void:
	test_reset_and_pause()
	test_terrain_collision()
	test_bullets()
	test_damage_respawn()
	test_supplies()
	test_spawning_and_win()
	test_routes()
	test_motion_and_firing()
	test_enemy_progress()
	test_stress_invariants()
	check(checks >= 70, "suite executed all regression groups")
	print("TANK_BATTLE_TESTS: %d checks, %d failures" % [checks, failed])
	quit(1 if failed else 0)

func check(condition: bool, label: String) -> void:
	checks += 1
	if not condition:
		failed += 1
		push_error("FAIL: " + label)
	else:
		print("PASS: " + label)

func empty_model():
	var b = Model.new()
	b.reset()
	b.terrain.clear()
	b.tanks.clear()
	b.spawn_timer = 10000.0
	return b

func bullet(pos: Vector2, direction: int = 0, team: int = 0) -> Dictionary:
	return {"pos": pos, "dir": direction, "team": team, "owner": 999 + team, "speed": 294.0, "dead": false}

func wall(b, pos: Vector2i, kind: String) -> void:
	for y in range(2):
		for x in range(2):
			b.terrain[pos * 2 + Vector2i(x, y)] = kind

func advance(b, seconds: float, direction: int = -1, firing: bool = false, dt: float = 1.0 / 60.0) -> void:
	for i in range(ceili(seconds / dt)):
		b.update(dt, direction, firing)

func test_reset_and_pause() -> void:
	var b = Model.new()
	check(b.state == "title", "initial state is title")
	check(b.terrain.size() > 100 and b.player().size() > 0, "title preview has valid level and player")
	b.reset()
	var p: Dictionary = b.player()
	b.bullets.append(bullet(Vector2(16, 100)))
	b.effects.append({"pos": Vector2.ZERO, "life": 1.0, "max_life": 1.0, "radius": 3.0})
	b.powerups.append({"pos": Vector2.ZERO, "life": 10.0})
	b.respawn_timer = 0.7
	b.toggle_pause()
	var shield: float = p.shield
	var cooldown: float = p.cooldown
	var spawn: float = b.spawn_timer
	advance(b, 5.0, 0, true)
	check(b.state == "paused" and b.elapsed == 0, "pause freezes simulation time")
	check(p.shield == shield and p.cooldown == cooldown and b.spawn_timer == spawn and b.respawn_timer == 0.7, "pause freezes shield, reload, respawn and spawn timers")
	check(b.effects[0].life == 1.0 and b.powerups[0].life == 10.0 and b.bullets[0].pos == Vector2(16, 100), "pause freezes transient entities")
	b.toggle_pause()
	b.update(1.0 / 60.0)
	check(b.elapsed > 0 and b.state == "playing", "pause resumes")
	b.lives = 1
	b.score = 500
	b.spawned = 12
	b.base_alive = false
	b.reset()
	check(b.state == "playing" and b.lives == 3 and b.score == 0 and b.spawned == 0 and b.killed == 0 and b.base_alive, "restart restores all counters and base")
	check(b.bullets.is_empty() and b.effects.is_empty() and b.powerups.is_empty() and b.events.is_empty() and b.tanks.size() == 1, "restart removes transient state and extra tanks")

func test_terrain_collision() -> void:
	var b = empty_model()
	for kind in ["B", "S", "W", "G"]:
		b.terrain.clear()
		wall(b, Vector2i(2, 2), kind)
		check(b.can_occupy(Vector2(80, 80)) == (kind == "G"), "%s tank collision rule" % kind)
	b.terrain.clear()
	check(not b.can_occupy(Vector2(5, 40)) and not b.can_occupy(Vector2(412, 40)), "arena boundaries contain tanks")
	check(not b.can_occupy(Vector2(208, 400)), "base has tank collision")
	var t: Dictionary = b.spawn_tank(Vector2(80, 80), "player", 0)
	check(not b.can_occupy(Vector2(80, 80)) and b.can_occupy(Vector2(80, 80), t.id), "tank occupancy respects self ignore")
	b.tanks.clear()
	wall(b, Vector2i(2, 2), "B")
	var shot := bullet(Vector2(80, 65), 2)
	check(b.hit_terrain(shot) and shot.dead and b.terrain.size() == 2, "brick hit removes only a half course")
	check(not b.can_occupy(Vector2(80, 80)), "remaining half brick blocks tanks")
	shot = bullet(Vector2(80, 81), 2)
	b.hit_terrain(shot)
	check(b.terrain.is_empty() and b.can_occupy(Vector2(80, 80)), "second brick hit clears passage")
	wall(b, Vector2i(2, 2), "S")
	shot = bullet(Vector2(80, 65), 2)
	check(b.hit_terrain(shot) and shot.dead and b.terrain.size() == 4, "steel stops bullets without destruction")
	for kind in ["W", "G"]:
		b.terrain.clear()
		wall(b, Vector2i(2, 2), kind)
		shot = bullet(Vector2(80, 80), 2)
		check(not b.hit_terrain(shot) and not shot.dead and b.terrain.size() == 4, "%s passes bullets intact" % kind)

func test_bullets() -> void:
	var b = empty_model()
	b.bullets.append(bullet(Vector2(100, 100), 1, 0))
	b.bullets.append(bullet(Vector2(110, 100), 3, 1))
	b.update_bullets(0.05)
	check(b.bullets.is_empty(), "opposing bullets mutually cancel under microsteps")
	b.bullets.append(bullet(Vector2(100, 100), 1, 0))
	b.bullets.append(bullet(Vector2(110, 100), 3, 0))
	b.update_bullets(0.05)
	check(b.bullets.size() == 2, "same team bullets do not cancel")
	b.bullets.clear()
	var p: Dictionary = b.spawn_tank(Vector2(80, 80), "player", 0)
	b.bullets.append(bullet(Vector2(80, 100), 0, 0))
	b.update_bullets(0.05)
	check(b.tanks.has(p) and p.hp == 1, "player bullets cannot damage player")
	b.bullets.clear()
	b.bullets.append(bullet(Vector2(80, 100), 0, 1))
	b.update_bullets(0.05)
	check(b.player().is_empty() and b.lives == 2, "enemy bullets damage unshielded player")
	b.bullets.clear()
	b.bullets.append(bullet(Vector2(208, 380), 2, 0))
	b.update_bullets(0.05)
	check(b.base_alive and b.state == "playing" and b.bullets.is_empty(), "player shot is safely absorbed by base")
	b.bullets.append(bullet(Vector2(208, 380), 2, 1))
	b.update_bullets(0.05)
	check(not b.base_alive and b.state == "lost", "enemy shot destroys base and ends battle")
	b = empty_model()
	wall(b, Vector2i(2, 2), "S")
	b.bullets.append(bullet(Vector2(80, 50), 2, 0))
	b.update_bullets(0.2)
	check(b.bullets.is_empty() and b.terrain.size() == 4, "fast bullets cannot tunnel through steel")
	b = empty_model()
	var armor: Dictionary = b.spawn_tank(Vector2(80, 80), "armor", 1)
	armor.born = 0.0
	for hit in range(2):
		b.bullets.append(bullet(Vector2(80, 100), 0, 0))
		b.update_bullets(0.05)
	check(armor.hp == 1 and b.enemy_count() == 1, "armor survives first two hits")
	b.bullets.append(bullet(Vector2(80, 100), 0, 0))
	b.update_bullets(0.05)
	check(b.enemy_count() == 0 and b.killed == 1 and b.score == 400, "armor third hit awards one kill and correct score")

func test_damage_respawn() -> void:
	var b = empty_model()
	var p: Dictionary = b.spawn_tank(b.player_spawn, "player", 0, 3.0)
	b.bullets.append(bullet(Vector2(144, 380), 2, 1))
	b.update_bullets(0.05)
	check(p.hp == 1 and b.lives == 3 and b.bullets.is_empty(), "spawn shield absorbs enemy bullets")
	p.shield = 0.0
	b.damage_tank(p)
	check(b.player().is_empty() and b.lives == 2 and b.respawn_timer > 0 and b.state == "playing", "player death schedules respawn while lives remain")
	advance(b, 1.4)
	check(not b.player().is_empty() and b.player().shield > 2.5, "player respawns with brief shield")
	for death in range(2):
		b.damage_tank(b.player())
		if death == 0:
			advance(b, 1.4)
	check(b.lives == 0 and b.state == "lost" and b.player().is_empty(), "third player death exhausts lives and loses")
	b = empty_model()
	b.spawn_tank(b.player_spawn, "regular", 1)
	b.try_respawn()
	check(not b.player().is_empty() and b.player().pos != b.player_spawn, "respawn selects unoccupied alternate lane")
	b = empty_model()
	for pos in [b.player_spawn, Vector2(272, 400), Vector2(112, 400), Vector2(304, 400)]:
		b.spawn_tank(pos, "regular", 1)
	b.try_respawn()
	check(b.player().is_empty() and b.respawn_timer > 0, "fully occupied respawn retries without overlap")

func test_supplies() -> void:
	var b = Model.new()
	b.reset()
	b.killed = 4
	var enemy: Dictionary = b.spawn_tank(Vector2(16, 16), "regular", 1)
	b.damage_tank(enemy)
	check(b.powerups.size() == 1, "fifth enemy grants one shield supply")
	if not b.powerups.is_empty():
		check(b.can_occupy(b.powerups[0].pos, -1, false), "shield supply spawns on passable ground")
		var p: Dictionary = b.player()
		p.pos = b.powerups[0].pos
		p.shield = 0.0
		var score_before: int = b.score
		b.collect_powerup(p)
		check(b.powerups.is_empty() and p.shield == 8.0 and b.score == score_before + 250, "shield pickup grants temporary protection and score exactly once")

func test_spawning_and_win() -> void:
	var b = empty_model()
	for pos in [Vector2(16, 16), Vector2(208, 16), Vector2(400, 16)]:
		b.spawn_tank(pos, "regular", 1)
	check(not b.try_spawn_enemy() and b.spawned == 0, "occupied enemy spawn lanes postpone spawn without consuming wave")
	b.tanks.clear()
	b.spawn_timer = 0.0
	advance(b, 16.0)
	check(b.enemy_count() <= 4 and b.spawned <= 4, "maximum four simultaneous enemies")
	b = empty_model()
	var observed := 0
	for i in range(20):
		b.spawn_timer = 0.0
		b.update(1.0 / 60.0)
		observed += b.enemy_count()
		for t in b.tanks.duplicate():
			if t.team == 1:
				while t.hp > 0:
					b.damage_tank(t)
		if i < 19:
			check(b.state == "playing", "no premature win after enemy %d" % (i + 1))
	check(b.spawned == 20 and observed == 20 and b.killed == 20, "finite wave spawns and destroys exactly twenty enemies")
	b.update(1.0 / 60.0)
	check(b.state == "won" and b.enemy_count() == 0, "victory requires all twenty spawned and no living enemies")
	advance(b, 5.0)
	check(b.spawned == 20, "terminal victory never spawns enemy twenty one")
	b = empty_model()
	b.spawned = 20
	b.spawn_tank(Vector2(16, 16), "armor", 1)
	b.update(1.0 / 60.0)
	check(b.state == "playing", "twentieth spawn alone does not win while an enemy lives")

func test_routes() -> void:
	var b = Model.new()
	for lane in [0, 6, 12]:
		var cell := Vector2i(lane, 0)
		var reached := false
		var seen: Dictionary = {}
		for i in range(169):
			if cell == Vector2i(6, 12):
				reached = true
				break
			if seen.has(cell):
				break
			seen[cell] = true
			var next: Vector2i = b.next_step(cell, Vector2i(6, 12), lane % 4)
			if not is_finite(b.tile_cost(next)):
				break
			cell = next
		check(reached, "enemy spawn lane %d has a finite route to headquarters" % lane)
	check(not is_finite(b.tile_cost(Vector2i(4, 5))), "pathfinding rejects water")
	check(not is_finite(b.tile_cost(Vector2i(5, 3))), "pathfinding rejects steel")
	check(b.tile_cost(Vector2i(1, 1)) > 1 and is_finite(b.tile_cost(Vector2i(1, 1))), "pathfinding prices destructible bricks")

func test_motion_and_firing() -> void:
	var a = empty_model()
	var b = empty_model()
	var pa: Dictionary = a.spawn_tank(Vector2(40, 40), "player", 0)
	var pb: Dictionary = b.spawn_tank(Vector2(40, 40), "player", 0)
	advance(a, 1.0, 1, false, 1.0 / 60.0)
	advance(b, 1.0, 1, false, 1.0 / 30.0)
	check(pa.pos.distance_to(pb.pos) < 0.01 and absf(pa.pos.x - 146.0) < 0.01, "movement distance is independent of 30/60 Hz time step")
	pa.cooldown = 0.0
	check(a.fire(pa) and not a.fire(pa), "rapid repeated fire respects reload")
	pa.cooldown = 0.0
	check(a.fire(pa), "player may have two active bullets")
	pa.cooldown = 0.0
	check(not a.fire(pa), "third concurrent player bullet is rejected")
	var enemy: Dictionary = a.spawn_tank(Vector2(300, 300), "regular", 1)
	enemy.born = 0.0
	enemy.cooldown = 0.0
	check(a.fire(enemy), "enemy fires first shot")
	enemy.cooldown = 0.0
	check(not a.fire(enemy), "enemy concurrent bullet cap is one")

func test_enemy_progress() -> void:
	for kind in ["regular", "scout", "gunner", "armor"]:
		for lane in [0, 6, 12]:
			var b = Model.new()
			b.reset()
			b.tanks.clear()
			b.spawn_timer = 10000.0
			b.spawn_tank(Vector2(lane * 32 + 16, 16), kind, 1)
			advance(b, 90.0)
			check(not b.base_alive and b.state == "lost", "unopposed %s lane %d can eventually breach the base" % [kind, lane])
	var corner = empty_model()
	var turning: Dictionary = corner.spawn_tank(Vector2(112.1999, 16), "armor", 1)
	turning.born = 0.0
	turning.waypoint = Vector2(112, 48)
	advance(corner, 0.5)
	check(turning.pos.y > 20 and absf(turning.pos.x - 112) <= 0.1, "enemy small off-axis corner error cannot cause endless oscillation")

func test_stress_invariants() -> void:
	var random := RandomNumberGenerator.new()
	random.seed = 927461
	var b = Model.new()
	b.reset()
	var direction := 0
	var safe_geometry := true
	var safe_counts := true
	var completed_runs := 0
	for step in range(18000):
		if step % 19 == 0:
			direction = random.randi_range(-1, 3)
		b.update(1.0 / 60.0, direction, true)
		if b.enemy_count() > 4 or b.spawned > 20 or b.lives < 0:
			safe_counts = false
		for t in b.tanks:
			if not b.can_occupy(t.pos, t.id):
				safe_geometry = false
		if b.state in ["won", "lost"]:
			completed_runs += 1
			b.reset()
	check(safe_geometry, "five simulated minutes of rapid random turns preserve arena, terrain and tank collision")
	check(safe_counts, "stress play preserves life and wave count bounds")
	check(completed_runs > 0, "stress play traverses terminal and repeated restart flows")
