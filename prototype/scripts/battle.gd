class_name Battle
extends RefCounted

## Pure authoritative combat model. No AI, scene tree, input device or networking.
## Timers use exact 60 Hz ticks; the renderer receives seconds for UI only.
const TILE := 32
const WIDTH := 736
const HEIGHT := 416
const COLUMNS := WIDTH / TILE
const ROWS := HEIGHT / TILE
const TERRAIN_COLUMNS := WIDTH / 16
const TERRAIN_ROWS := HEIGHT / 16
const CENTER_OFFSET := 160
const HALF := 12.0
const TICK_RATE := 60
const STEP := 1.0 / TICK_RATE
const PLAYER_SPEED := 106.0
const BULLET_SPEED := 294.0
const FIRE_INTERVAL := 0.28
const FIRE_TICKS := ceili(FIRE_INTERVAL * TICK_RATE)
const MAX_BULLETS := 2
const RESPAWN_DELAY := 2.0
const RESPAWN_TICKS := ceili(RESPAWN_DELAY * TICK_RATE)
const RESPAWN_SHIELD := 2.0
const SHIELD_TICKS := ceili(RESPAWN_SHIELD * TICK_RATE)
const BASE_HP := 5
const BASE_INVULNERABILITY := 1.0
const BASE_SHIELD_TICKS := ceili(BASE_INVULNERABILITY * TICK_RATE)
const DIRS := [Vector2.UP, Vector2.RIGHT, Vector2.DOWN, Vector2.LEFT]
# Both horizontal and vertical mirrors: same cover, travel distance and spawn space.
# The original center is unchanged; five playable columns are added at each
# side. North/south and east/west mirrors give both teams identical wing routes.
const MAP := [
	"..........B.B..........",
	".BBB......BBB......BBB.",
	"...B..BB.B...B.BB..B...",
	".G....GG...S...GG....G.",
	".G.S..GG.B...B.GG..S.G.",
	"...W.....WW.WW.....W...",
	".B....BB..S.S..BB....B.",
	"...W.....WW.WW.....W...",
	".G.S..GG.B...B.GG..S.G.",
	".G....GG...S...GG....G.",
	"...B..BB.B...B.BB..B...",
	".BBB......BBB......BBB.",
	"..........B.B.........."
]

var state := "lobby"
var winner := -1 # 0 red, 1 blue, 2 simultaneous destruction / draw.
var elapsed := 0.0
var tick := 0
var terrain: Dictionary = {}
var tanks: Array[Dictionary] = []
var bullets: Array[Dictionary] = []
var effects: Array[Dictionary] = []
var events: Array[String] = []
var players: Dictionary = {}
var bases: Array[Dictionary] = []
var next_bullet_id := 1
var _accumulator := 0.0

func _init() -> void:
	_load_terrain()
	_reset_bases()

func _load_terrain() -> void:
	terrain.clear()
	for y in range(ROWS):
		assert(MAP[y].length() == COLUMNS)
		for x in range(COLUMNS):
			var kind: String = MAP[y].substr(x, 1)
			if kind in ["B", "S", "W", "G"]:
				for oy in range(2):
					for ox in range(2):
						terrain[Vector2i(x * 2 + ox, y * 2 + oy)] = kind

func _reset_bases() -> void:
	bases.clear()
	for team in range(2):
		bases.append({"team": team, "hp": BASE_HP, "shield": 0.0,
			"shield_until": 0, "pos": Vector2((WIDTH - TILE) / 2, 0 if team == 0 else HEIGHT - TILE)})

func reset(roster: Dictionary) -> void:
	state = "playing"
	winner = -1
	elapsed = 0.0
	tick = 0
	_accumulator = 0.0
	next_bullet_id = 1
	tanks.clear()
	bullets.clear()
	effects.clear()
	events.clear()
	players.clear()
	_load_terrain()
	_reset_bases()
	var ids := roster.keys()
	ids.sort()
	for id in ids:
		var entry: Dictionary = roster[id]
		if typeof(id) != TYPE_INT or id < 1 or not entry.get("team", -1) in [0, 1]:
			continue
		players[id] = {"id": id, "name": str(entry.get("name", "Player")), "team": int(entry.team),
			"kills": 0, "deaths": 0, "respawn": 0.0, "respawn_at": 0}
		try_respawn(id)

func tank_for(id: int) -> Dictionary:
	for tank in tanks:
		if tank.id == id:
			return tank
	return {}

func base_rect(team: int) -> Rect2:
	return Rect2(bases[team].pos, Vector2(32, 32))

func spawn_points(team: int) -> Array[Vector2]:
	var result: Array[Vector2] = []
	# Wide lanes avoid spawning teammates nose-to-tail. Secondary positions are safe fallbacks.
	for y in [16, 48]:
		for x in [48, 368, 112, 304, 16, 400, 80, 336]:
			result.append(Vector2(x + CENTER_OFFSET, y if team == 0 else HEIGHT - y))
	return result

func try_respawn(id: int) -> bool:
	if not players.has(id) or not tank_for(id).is_empty():
		return false
	var p: Dictionary = players[id]
	for pos in spawn_points(p.team):
		if can_occupy(pos):
			spawn_tank(id, pos, p.team)
			p.respawn_at = -1
			p.respawn = -1.0
			return true
	# Occupied lanes never overlap or kill an occupant. Retry on the next simulation tick.
	p.respawn_at = tick + 1
	p.respawn = STEP
	return false

func spawn_tank(id: int, pos: Vector2, team: int, shield: float = RESPAWN_SHIELD) -> Dictionary:
	var tank := {"id": id, "pos": pos, "dir": 2 if team == 0 else 0, "team": team,
		"anim": 0.0, "shield": shield, "shield_until": tick + ceili(shield * TICK_RATE),
		"hit": 0.0, "cooldown": 0.0, "fire_at": tick}
	tanks.append(tank)
	return tank

func remove_player(id: int) -> void:
	players.erase(id)
	tanks = tanks.filter(func(t): return t.id != id)
	bullets = bullets.filter(func(b): return b.owner != id)

func update(dt: float, inputs: Dictionary = {}) -> void:
	if state != "playing" or not is_finite(dt) or dt <= 0:
		return
	# One outer call cannot manufacture a huge amount of simulation time.
	_accumulator += minf(dt, 0.25)
	while _accumulator + 0.0000001 >= STEP and state == "playing":
		_accumulator = maxf(0.0, _accumulator - STEP)
		_step(inputs)

func _step(inputs: Dictionary) -> void:
	# Headless hosts may have no sound consumer; retain only a bounded recent event tail.
	if events.size() > 128:
		events = events.slice(events.size() - 128)
	tick += 1
	elapsed = tick * STEP
	for e in effects:
		e.life = maxf(0.0, e.life - STEP)
	effects = effects.filter(func(e): return e.life > 0)
	for base in bases:
		base.shield = maxf(0.0, (base.shield_until - tick) * STEP)
	var ids := players.keys()
	ids.sort()
	for id in ids:
		var p: Dictionary = players[id]
		if p.respawn_at >= 0:
			p.respawn = maxf(0.0, (p.respawn_at - tick) * STEP)
			if tick >= p.respawn_at:
				try_respawn(id)
	for tank in tanks:
		tank.shield = maxf(0.0, (tank.shield_until - tick) * STEP)
		tank.cooldown = maxf(0.0, (tank.fire_at - tick) * STEP)
		tank.hit = maxf(0.0, tank.hit - STEP)
		var command = inputs.get(tank.id, {})
		if not command is Dictionary:
			continue
		var direction = command.get("dir", -1)
		if typeof(direction) == TYPE_INT and direction >= 0 and direction < 4:
			tank.dir = direction
			move_tank(tank, DIRS[direction] * PLAYER_SPEED * STEP, true)
		var firing = command.get("fire", false)
		if typeof(firing) == TYPE_BOOL and firing:
			fire(tank)
	update_bullets(STEP)
	_check_winner()

func tank_rect(pos: Vector2) -> Rect2:
	return Rect2(pos - Vector2(HALF, HALF), Vector2(HALF * 2, HALF * 2))

func can_occupy(pos: Vector2, ignore_id: int = -1, include_tanks: bool = true) -> bool:
	var rect := tank_rect(pos)
	if rect.position.x < 0 or rect.position.y < 0 or rect.end.x > WIDTH or rect.end.y > HEIGHT:
		return false
	for team in range(2):
		if rect.intersects(base_rect(team)):
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

func move_tank(tank: Dictionary, delta: Vector2, assisted: bool = false) -> bool:
	if delta.length_squared() == 0:
		return false
	var old: Vector2 = tank.pos
	var candidate: Vector2 = old + delta
	if can_occupy(candidate, tank.id):
		tank.pos = candidate
		tank.anim += delta.length()
		return true
	# Preserve classic grid-corner alignment without ever crossing solid terrain.
	if assisted:
		var aligned := old
		if delta.x != 0:
			aligned.y = roundf((old.y - 16) / 32) * 32 + 16
		else:
			aligned.x = roundf((old.x - 16) / 32) * 32 + 16
		if aligned.distance_to(old) <= 5.0 and can_occupy(aligned, tank.id) and can_occupy(aligned + delta, tank.id):
			tank.pos = aligned + delta
			tank.anim += delta.length()
			return true
	return false

func fire(tank: Dictionary) -> bool:
	if tick < tank.fire_at:
		return false
	var active := 0
	for b in bullets:
		if b.owner == tank.id and not b.dead:
			active += 1
	if active >= MAX_BULLETS:
		return false
	bullets.append({"id": next_bullet_id, "pos": tank.pos + DIRS[tank.dir] * 15,
		"dir": tank.dir, "team": tank.team, "owner": tank.id, "speed": BULLET_SPEED, "dead": false})
	next_bullet_id += 1
	tank.fire_at = tick + FIRE_TICKS
	tank.cooldown = FIRE_TICKS * STEP
	events.append("fire")
	return true

func update_bullets(dt: float) -> void:
	# Global <=3px microsteps stop fast bullets tunnelling through tanks, walls or each other.
	var steps := maxi(1, ceili(dt * BULLET_SPEED / 3.0))
	for _substep in range(steps):
		for b in bullets:
			if b.dead:
				continue
			b.pos += DIRS[b.dir] * b.speed * dt / steps
			var p: Vector2 = b.pos
			if p.x < 0 or p.y < 0 or p.x >= WIDTH or p.y >= HEIGHT:
				b.dead = true
				continue
			var rect := Rect2(p - Vector2(2, 2), Vector2(4, 4))
			for base in bases:
				if rect.intersects(base_rect(base.team)):
					b.dead = true
					if b.team != base.team:
						damage_base(base.team)
					break
			if b.dead or hit_terrain(b):
				continue
			for other in bullets:
				if other.id == b.id or other.dead or other.team == b.team:
					continue
				if p.distance_squared_to(other.pos) < 49:
					b.dead = true
					other.dead = true
					add_explosion(p, 5)
					break
			if b.dead:
				continue
			for tank in tanks.duplicate():
				if tank.team == b.team:
					continue
				if rect.intersects(tank_rect(tank.pos)):
					b.dead = true
					if tick >= tank.shield_until:
						damage_tank(tank, b.owner)
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
	# Steel always absorbs a mixed-edge hit before adjacent brick can be damaged.
	for cell in cells:
		if terrain.get(cell, "") == "S":
			b.dead = true
			add_explosion(p, 4)
			return true
	for cell in cells:
		if terrain.get(cell, "") == "B":
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

func damage_tank(tank: Dictionary, attacker: int = -1) -> bool:
	if not tanks.has(tank) or tick < tank.shield_until:
		return false
	if players.has(attacker) and players[attacker].team == tank.team:
		return false
	add_explosion(tank.pos, 20)
	tanks.erase(tank)
	if players.has(tank.id):
		var victim: Dictionary = players[tank.id]
		victim.deaths += 1
		victim.respawn_at = tick + RESPAWN_TICKS
		victim.respawn = RESPAWN_DELAY
	if players.has(attacker):
		players[attacker].kills += 1
	events.append("death")
	return true

func damage_base(team: int) -> bool:
	var base: Dictionary = bases[team]
	if base.hp <= 0 or tick < base.shield_until:
		return false
	base.hp -= 1
	base.shield_until = tick + BASE_SHIELD_TICKS
	base.shield = BASE_INVULNERABILITY
	add_explosion(base_rect(team).get_center(), 28 if base.hp == 0 else 15)
	events.append("armor" if base.hp > 0 else "kill")
	return true

func _check_winner() -> void:
	# Evaluate after every bullet in the fixed tick, not after the first base hit.
	if bases[0].hp <= 0 and bases[1].hp <= 0:
		winner = 2
	elif bases[0].hp <= 0:
		winner = 1
	elif bases[1].hp <= 0:
		winner = 0
	if winner != -1:
		state = "ended"
		events.append("win")

func add_explosion(pos: Vector2, radius: float) -> void:
	effects.append({"pos": pos, "radius": radius, "size": radius, "life": 0.35, "max_life": 0.35})

func _pack_terrain() -> PackedByteArray:
	var packed := PackedByteArray()
	packed.resize(TERRAIN_COLUMNS * TERRAIN_ROWS)
	for cell in terrain:
		packed[cell.y * TERRAIN_COLUMNS + cell.x] = ["", "B", "S", "W", "G"].find(terrain[cell])
	return packed

func _unpack_terrain(packed: PackedByteArray) -> void:
	terrain.clear()
	for i in range(mini(packed.size(), TERRAIN_COLUMNS * TERRAIN_ROWS)):
		if packed[i] > 0 and packed[i] <= 4:
			terrain[Vector2i(i % TERRAIN_COLUMNS, i / TERRAIN_COLUMNS)] = ["", "B", "S", "W", "G"][packed[i]]

func snapshot() -> Dictionary:
	return {"state": state, "winner": winner, "elapsed": elapsed, "tick": tick,
		"terrain": _pack_terrain(), "tanks": tanks.duplicate(true), "bullets": bullets.duplicate(true),
		"effects": effects.duplicate(true), "players": players.duplicate(true), "bases": bases.duplicate(true),
		"next_bullet_id": next_bullet_id}

func apply_snapshot(data: Dictionary) -> void:
	# Called only for an already validated authority RPC; clients never simulate this copy.
	state = data.state
	winner = data.winner
	elapsed = data.elapsed
	tick = data.tick
	_unpack_terrain(data.terrain)
	tanks.assign(data.tanks.duplicate(true))
	bullets.assign(data.bullets.duplicate(true))
	effects.assign(data.effects.duplicate(true))
	players = data.players.duplicate(true)
	bases.assign(data.bases.duplicate(true))
	next_bullet_id = data.next_bullet_id
	_accumulator = 0.0
	events.clear()
