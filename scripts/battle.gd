class_name Battle
extends RefCounted

## Deterministic, renderer-independent 60 Hz combat simulation. All positions are local to the arena.
const TILE := 32
const SIZE := 416
const HALF := 12.0
const MAX_ENEMIES := 20
const DIRS := [Vector2.UP, Vector2.RIGHT, Vector2.DOWN, Vector2.LEFT]
const ENEMY_TYPES := ["scout", "regular", "regular", "gunner", "armor", "regular", "scout", "gunner", "regular", "armor", "scout", "regular", "gunner", "armor", "scout", "regular", "gunner", "armor", "scout", "armor"]
const STATS := {
	"player": {"speed": 106.0, "hp": 1, "reload": 0.28, "bullet": 294.0, "points": 0},
	"regular": {"speed": 47.0, "hp": 1, "reload": 1.65, "bullet": 178.0, "points": 100},
	"scout": {"speed": 72.0, "hp": 1, "reload": 1.9, "bullet": 178.0, "points": 200},
	"gunner": {"speed": 44.0, "hp": 1, "reload": 1.05, "bullet": 235.0, "points": 300},
	"armor": {"speed": 36.0, "hp": 3, "reload": 1.65, "bullet": 184.0, "points": 400}
}
const MAP := [
	".............",
	".BB.B.B.B.BB.",
	".BB.B.B.B.BB.",
	".....S.S.....",
	".BB.B...B.BB.",
	"....WW.WW....",
	".BB.......BB.",
	"....B.S.B....",
	".GG.B...B.GG.",
	".GG...S...GG.",
	".BB.B...B.BB.",
	".....BBB.....",
	".....BHB....."
]
var terrain: Dictionary = {} # Vector2i 16 px cells: B brick, S steel, W water, G grass
var tanks: Array[Dictionary] = []
var bullets: Array[Dictionary] = []
var effects: Array[Dictionary] = []
var events: Array[String] = []
var powerups: Array[Dictionary] = []
var rng := RandomNumberGenerator.new()
var state := "title"
var lives := 3
var spawned := 0
var killed := 0
var score := 0
var base_alive := true
var elapsed := 0.0
var spawn_timer := 0.0
var respawn_timer := -1.0
var next_id := 1
var pause_previous := "playing"
var base_rect := Rect2(192, 384, 32, 32)
var player_spawn := Vector2(144, 400)
var flash_timer := 0.0
var mute := false

func _init(seed_value: int = 4276) -> void:
	rng.seed = seed_value
	reset(false)

func reset(start: bool = true) -> void:
	terrain.clear()
	tanks.clear()
	bullets.clear()
	effects.clear()
	events.clear()
	powerups.clear()
	lives = 3
	spawned = 0
	killed = 0
	score = 0
	base_alive = true
	elapsed = 0.0
	spawn_timer = 1.8
	respawn_timer = -1.0
	next_id = 1
	flash_timer = 0.0
	state = "playing" if start else "title"
	for y in range(13):
		assert(MAP[y].length() == 13)
		for x in range(13):
			var kind: String = MAP[y].substr(x, 1)
			if kind in ["B", "S", "W", "G"]:
				for oy in range(2):
					for ox in range(2):
						terrain[Vector2i(x * 2 + ox, y * 2 + oy)] = kind
	spawn_tank(player_spawn, "player", 0, 3.0)

func player() -> Dictionary:
	for tank in tanks:
		if tank.team == 0:
			return tank
	return {}

func spawn_tank(pos: Vector2, kind: String, team: int, shield: float = 0.0) -> Dictionary:
	var t := {"id": next_id, "pos": pos, "dir": 0 if team == 0 else 2, "kind": kind, "team": team, "hp": STATS[kind].hp, "cooldown": 0.25 if team == 0 else 0.9, "shield": shield, "ai_timer": 0.0, "waypoint": pos, "stuck": 0.0, "anim": 0.0, "hit": 0.0, "born": 0.45 if team == 1 else 0.0}
	next_id += 1
	tanks.append(t)
	return t

func toggle_pause() -> void:
	if state == "playing":
		state = "paused"
	elif state == "paused":
		state = "playing"

func update(dt: float, direction: int = -1, firing: bool = false) -> void:
	if state != "playing":
		return
	dt = clampf(dt, 0.0, 0.05)
	elapsed += dt
	flash_timer = maxf(0, flash_timer - dt)
	for e in effects:
		e.life -= dt
	effects = effects.filter(func(e): return e.life > 0)
	for item in powerups:
		item.life -= dt
	powerups = powerups.filter(func(item): return item.life > 0)
	if respawn_timer >= 0:
		respawn_timer -= dt
		if respawn_timer <= 0:
			try_respawn()
	spawn_timer -= dt
	if spawned < MAX_ENEMIES and enemy_count() < 4 and spawn_timer <= 0:
		try_spawn_enemy()
	for t in tanks.duplicate():
		if not tanks.has(t):
			continue
		t.cooldown = maxf(0, t.cooldown - dt)
		t.shield = maxf(0, t.shield - dt)
		t.hit = maxf(0, t.hit - dt)
		t.born = maxf(0, t.born - dt)
		if t.born > 0:
			continue
		if t.team == 0:
			if direction >= 0:
				t.dir = direction
				move_tank(t, DIRS[direction] * STATS.player.speed * dt, true)
			if firing:
				fire(t)
			collect_powerup(t)
		else:
			update_enemy(t, dt)
	update_bullets(dt)
	if state == "playing" and spawned == MAX_ENEMIES and enemy_count() == 0:
		state = "won"
		events.append("win")

func tank_rect(pos: Vector2) -> Rect2:
	return Rect2(pos - Vector2(HALF, HALF), Vector2(HALF * 2, HALF * 2))

func can_occupy(pos: Vector2, ignore_id: int = -1, include_tanks: bool = true) -> bool:
	var rect := tank_rect(pos)
	if rect.position.x < 0 or rect.position.y < 0 or rect.end.x > SIZE or rect.end.y > SIZE:
		return false
	if base_alive and rect.intersects(base_rect):
		return false
	var lo := Vector2i(floor(rect.position.x / 16), floor(rect.position.y / 16))
	var hi := Vector2i(floor((rect.end.x - 0.01) / 16), floor((rect.end.y - 0.01) / 16))
	for y in range(lo.y, hi.y + 1):
		for x in range(lo.x, hi.x + 1):
			if terrain.get(Vector2i(x, y), "") in ["B", "S", "W"]:
				return false
	if include_tanks:
		for other in tanks:
			if other.id != ignore_id and rect.intersects(tank_rect(other.pos)):
				return false
	return true

func move_tank(t: Dictionary, delta: Vector2, assisted: bool = false) -> bool:
	if delta.length_squared() == 0:
		return false
	var old: Vector2 = t.pos
	var candidate: Vector2 = old + delta
	if can_occupy(candidate, t.id):
		t.pos = candidate
		t.anim += delta.length()
		return true
	# Small lane alignment prevents 24 px tanks catching on 32 px corners.
	if assisted:
		var aligned := old
		if delta.x != 0:
			aligned.y = roundf((old.y - 16) / 32) * 32 + 16
		else:
			aligned.x = roundf((old.x - 16) / 32) * 32 + 16
		if aligned.distance_to(old) <= 5.0 and can_occupy(aligned, t.id) and can_occupy(aligned + delta, t.id):
			t.pos = aligned + delta
			t.anim += delta.length()
			return true
	return false

func enemy_count() -> int:
	var total := 0
	for t in tanks:
		if t.team == 1:
			total += 1
	return total

func try_spawn_enemy() -> bool:
	var lanes := [Vector2(16, 16), Vector2(208, 16), Vector2(400, 16)]
	var offset := spawned % 3
	for i in range(3):
		var pos: Vector2 = lanes[(offset + i) % 3]
		if can_occupy(pos):
			spawn_tank(pos, ENEMY_TYPES[spawned], 1, 1.0)
			spawned += 1
			spawn_timer = 3.6 if spawned < 4 else 2.5
			return true
	spawn_timer = 0.3
	return false

func try_respawn() -> void:
	for pos in [player_spawn, Vector2(272, 400), Vector2(112, 400), Vector2(304, 400)]:
		if can_occupy(pos):
			spawn_tank(pos, "player", 0, 3.0)
			respawn_timer = -1.0
			return
	respawn_timer = 0.25

func tile_cost(cell: Vector2i) -> float:
	if cell.x < 0 or cell.y < 0 or cell.x >= 13 or cell.y >= 13:
		return INF
	var brick := false
	for oy in range(2):
		for ox in range(2):
			var kind: String = terrain.get(cell * 2 + Vector2i(ox, oy), "")
			if kind in ["S", "W"]:
				return INF
			if kind == "B":
				brick = true
	return 3.4 if brick else 1.0

func next_step(start: Vector2i, goal: Vector2i, variant: int = 0) -> Vector2i:
	if start == goal:
		return goal
	var frontier: Array[Vector2i] = [start]
	var costs := {start: 0.0}
	var previous: Dictionary = {}
	while not frontier.is_empty():
		var best_index := 0
		var best_score := INF
		for i in range(frontier.size()):
			var c := frontier[i]
			var distance := absi(goal.x - c.x) + absi(goal.y - c.y)
			var priority: float = costs[c] + distance
			if priority < best_score:
				best_score = priority
				best_index = i
		var current := frontier[best_index]
		frontier.remove_at(best_index)
		if current == goal:
			var step := goal
			while previous.has(step) and previous[step] != start:
				step = previous[step]
			return step
		for n in range(4):
			var d: Vector2 = DIRS[(n + variant) % 4]
			var neighbor := current + Vector2i(d)
			var cost: float = costs[current] + tile_cost(neighbor)
			if cost < costs.get(neighbor, INF):
				costs[neighbor] = cost
				previous[neighbor] = current
				if not frontier.has(neighbor):
					frontier.append(neighbor)
	return start

func update_enemy(t: Dictionary, dt: float) -> void:
	t.ai_timer -= dt
	var pos: Vector2 = t.pos
	var target: Vector2 = t.waypoint
	if pos.distance_to(target) < 0.2 or t.stuck > 1.2:
		var cell := Vector2i(roundi((pos.x - 16) / 32), roundi((pos.y - 16) / 32))
		var goal := Vector2i(6, 12)
		var p := player()
		# Scouts hunt nearby players; other types keep pressure on the headquarters.
		if t.kind == "scout" and not p.is_empty() and pos.distance_to(p.pos) < 190:
			goal = Vector2i(p.pos / 32)
		var step := next_step(cell, goal, int(t.id) % 4)
		t.waypoint = Vector2(step * 32) + Vector2(16, 16)
		t.stuck = 0.0
		target = t.waypoint
	var difference: Vector2 = target - pos
	if difference.length() > 0.1:
		var axis := Vector2.ZERO
		if absf(difference.x) > 0.1:
			axis.x = signf(difference.x)
			t.dir = 1 if axis.x > 0 else 3
		else:
			axis.y = signf(difference.y)
			t.dir = 2 if axis.y > 0 else 0
		var remaining := absf(difference.x) if axis.x != 0 else absf(difference.y)
		var amount := minf(STATS[t.kind].speed * dt, remaining)
		if move_tank(t, axis * amount):
			t.stuck = 0.0
		else:
			t.stuck += dt
	# Shoot in travel direction; aim at a nearby aligned player between route segments.
	var p := player()
	if not p.is_empty() and t.ai_timer <= 0:
		var diff: Vector2 = p.pos - t.pos
		if diff.length() < 220 and (absf(diff.x) < 11 or absf(diff.y) < 11):
			t.dir = (2 if diff.y > 0 else 0) if absf(diff.x) < 11 else (1 if diff.x > 0 else 3)
		t.ai_timer = 0.5
	fire(t)

func fire(t: Dictionary) -> bool:
	if t.cooldown > 0 or t.born > 0:
		return false
	var active := 0
	for b in bullets:
		if b.owner == t.id:
			active += 1
	if active >= (2 if t.team == 0 else 1):
		return false
	var direction: Vector2 = DIRS[t.dir]
	bullets.append({"pos": t.pos + direction * 15, "dir": t.dir, "team": t.team, "owner": t.id, "speed": STATS[t.kind].bullet, "dead": false})
	t.cooldown = STATS[t.kind].reload
	if t.team == 0:
		events.append("fire")
	return true

func update_bullets(dt: float) -> void:
	# Global microsteps preserve opposing bullet collision and prevent tunnelling at low frame rates.
	var steps := maxi(1, ceili(dt * 300.0 / 3.0))
	for _substep in range(steps):
		for b in bullets:
			if b.dead:
				continue
			b.pos += DIRS[b.dir] * b.speed * dt / steps
			var p: Vector2 = b.pos
			if p.x < 0 or p.y < 0 or p.x >= SIZE or p.y >= SIZE:
				b.dead = true
				continue
			var r := Rect2(p - Vector2(2, 2), Vector2(4, 4))
			if base_alive and r.intersects(base_rect):
				b.dead = true
				# Player fire cannot destroy the headquarters: friendly-fire protection.
				if b.team == 1:
					base_alive = false
					add_explosion(base_rect.get_center(), 28)
					state = "lost"
					events.append("lose")
				continue
			if hit_terrain(b):
				continue
			for other in bullets:
				if other == b or other.dead or other.team == b.team:
					continue
				if p.distance_squared_to(other.pos) < 49:
					b.dead = true
					other.dead = true
					add_explosion(p, 5)
					break
			if b.dead:
				continue
			for t in tanks.duplicate():
				if t.team == b.team or t.born > 0:
					continue
				if r.intersects(tank_rect(t.pos)):
					b.dead = true
					if t.shield <= 0:
						damage_tank(t)
					else:
						add_explosion(p, 5)
					break
	bullets = bullets.filter(func(b): return not b.dead)

func hit_terrain(b: Dictionary) -> bool:
	var p: Vector2 = b.pos
	var cells: Array[Vector2i] = []
	for offset in [Vector2(-2, -2), Vector2(2, -2), Vector2(-2, 2), Vector2(2, 2)]:
		var cell := Vector2i(floor((p.x + offset.x) / 16), floor((p.y + offset.y) / 16))
		if not cells.has(cell):
			cells.append(cell)
	for cell in cells:
		var kind: String = terrain.get(cell, "")
		if kind == "S":
			b.dead = true
			add_explosion(p, 4)
			return true
		if kind == "B":
			# Shatter one 16 px-deep course across a 32 px masonry tile, leaving visible half-wall rubble.
			var origin := Vector2i(floori(cell.x / 2.0) * 2, floori(cell.y / 2.0) * 2)
			for i in range(2):
				var victim := Vector2i(origin.x + i, cell.y) if b.dir % 2 == 0 else Vector2i(cell.x, origin.y + i)
				if terrain.get(victim, "") == "B":
					terrain.erase(victim)
			b.dead = true
			add_explosion(p, 7)
			events.append("brick")
			return true
	return false

func damage_tank(t: Dictionary) -> void:
	t.hp -= 1
	t.hit = 0.15
	if t.hp > 0:
		events.append("armor")
		return
	var pos: Vector2 = t.pos
	add_explosion(pos, 20)
	tanks.erase(t)
	if t.team == 0:
		lives -= 1
		flash_timer = 0.3
		events.append("death")
		if lives <= 0:
			state = "lost"
			events.append("lose")
		else:
			respawn_timer = 1.3
	else:
		killed += 1
		score += STATS[t.kind].points
		events.append("kill")
		if killed in [5, 10, 15]:
			# A shield supply appears in a guaranteed reachable home-side lane.
			powerups.append({"pos": Vector2(144 if killed != 10 else 272, 368), "life": 16.0})

func collect_powerup(t: Dictionary) -> void:
	for item in powerups.duplicate():
		if t.pos.distance_to(item.pos) < 23:
			t.shield = 8.0
			powerups.erase(item)
			score += 250
			events.append("powerup")

func add_explosion(pos: Vector2, radius: float) -> void:
	effects.append({"pos": pos, "radius": radius, "life": 0.35, "max_life": 0.35})
