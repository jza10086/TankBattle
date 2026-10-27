extends Node2D

const BattleModel = preload("res://scripts/battle.gd")
const FONT = preload("res://assets/fonts/Interface.ttf")
const ORIGIN := Vector2(24, 48)
const INK := Color("131719")
const PAPER := Color("d6d5bc")
const MUTED := Color("777d79")
const GOLD := Color("f3c65c")
const WHITE := Color("f0eddb")
const TERRACOTTA := Color("ad563d")
var game = BattleModel.new()
var key_order: Array[int] = []
var title_time := 0.0
var sounds: Dictionary = {}
var voices: Array[AudioStreamPlayer] = []
var voice_index := 0
var main_button := Rect2(128, 294, 208, 36)
var restart_button := Rect2(128, 340, 208, 28)
var pause_button := Rect2(464, 404, 152, 25)
var mouse_pos := Vector2.ZERO

func _ready() -> void:
	get_window().min_size = Vector2i(640, 480)
	for action in ["move_up", "move_right", "move_down", "move_left", "fire"]:
		if not InputMap.has_action(action):
			InputMap.add_action(action)
	var bindings := {"move_up": [KEY_W, KEY_UP], "move_right": [KEY_D, KEY_RIGHT], "move_down": [KEY_S, KEY_DOWN], "move_left": [KEY_A, KEY_LEFT], "fire": [KEY_SPACE]}
	for action in bindings:
		for key in bindings[action]:
			var event := InputEventKey.new()
			event.physical_keycode = key
			InputMap.action_add_event(action, event)
	for i in range(8):
		var voice := AudioStreamPlayer.new()
		voice.volume_db = -19.0
		add_child(voice)
		voices.append(voice)
	for kind in ["fire", "brick", "armor", "kill", "death", "powerup", "win", "lose"]:
		sounds[kind] = synthesize(kind)
	queue_redraw()

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and not event.echo:
		var code: int = event.physical_keycode
		var direction := key_direction(code)
		if direction >= 0:
			if event.pressed:
				key_order.erase(direction)
				key_order.append(direction)
			else:
				# The other key bound to this direction may still be held.
				if not Input.is_action_pressed(["move_up", "move_right", "move_down", "move_left"][direction]):
					key_order.erase(direction)
		if event.pressed:
			if code == KEY_M:
				game.mute = not game.mute
			elif code in [KEY_ENTER, KEY_KP_ENTER] and game.state in ["title", "won", "lost"]:
				start_game()
			elif code == KEY_SPACE and game.state == "title":
				start_game()
			elif code in [KEY_P, KEY_ESCAPE]:
				game.toggle_pause()
			elif code == KEY_R and game.state != "title":
				start_game()
	if event is InputEventMouseMotion:
		mouse_pos = get_global_mouse_position()
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		var point := get_global_mouse_position()
		if game.state in ["title", "won", "lost"] and main_button.has_point(point):
			start_game()
		elif game.state == "paused":
			if main_button.has_point(point):
				game.toggle_pause()
			elif restart_button.has_point(point):
				start_game()
		elif game.state == "playing" and pause_button.has_point(point):
			game.toggle_pause()

func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT and game != null and game.state == "playing":
		game.toggle_pause()
		key_order.clear()

func key_direction(key: int) -> int:
	if key in [KEY_W, KEY_UP]: return 0
	if key in [KEY_D, KEY_RIGHT]: return 1
	if key in [KEY_S, KEY_DOWN]: return 2
	if key in [KEY_A, KEY_LEFT]: return 3
	return -1

func start_game() -> void:
	game.reset()
	key_order.clear()

func _physics_process(dt: float) -> void:
	var direction := -1
	for candidate in key_order:
		if Input.is_action_pressed(["move_up", "move_right", "move_down", "move_left"][candidate]):
			direction = candidate
	game.update(dt, direction, Input.is_action_pressed("fire"))
	for event in game.events:
		play_sound(event)
	game.events.clear()
	if game.state != "paused":
		title_time += dt
	queue_redraw()

func text_at(value: String, pos: Vector2, size: int = 14, color: Color = WHITE) -> void:
	draw_string(FONT, pos, value, HORIZONTAL_ALIGNMENT_LEFT, -1, size, color)

func centered(value: String, y: float, size: int = 16, color: Color = WHITE, x: float = 232.0) -> void:
	var width := FONT.get_string_size(value, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	text_at(value, Vector2(x - width / 2, y), size, color)

func _draw() -> void:
	draw_rect(Rect2(0, 0, 640, 480), INK)
	# The battlefield is the UI: no oversized modern panels.
	text_at("铁鹰防线", Vector2(24, 30), 22, GOLD)
	text_at("T A N K   B A T T L E", Vector2(166, 28), 11, MUTED)
	text_at("1 PLAYER", Vector2(544, 28), 11, PAPER)
	draw_rect(Rect2(ORIGIN - Vector2(3, 3), Vector2(422, 422)), Color("62665d"))
	draw_rect(Rect2(ORIGIN - Vector2.ONE, Vector2(418, 418)), Color("242a27"))
	draw_rect(Rect2(ORIGIN, Vector2(416, 416)), Color("090d0e"))
	draw_set_transform(ORIGIN)
	for cell in game.terrain:
		var kind: String = game.terrain[cell]
		if kind != "G":
			draw_terrain(cell, kind)
	# Quiet grit gives the black playfield a physical cartridge-era texture.
	for y in range(13):
		for x in range(13):
			var point := Vector2(x * 32 + 8, y * 32 + 24)
			if not game.terrain.has(Vector2i(point / 16)):
				draw_rect(Rect2(point, Vector2(1, 1)), Color("1c2424"))
	draw_base()
	for item in game.powerups:
		if item.life > 4 or int(item.life * 8) % 2 == 0:
			draw_supply(item.pos)
	for t in game.tanks:
		if t.born > 0:
			draw_spawn(t.pos, t.born)
		else:
			draw_tank(t.pos, t.dir, t.kind, t.anim, t.hp, t.hit > 0)
			if t.shield > 0 and int(t.shield * 12) % 2 == 0:
				draw_rect(Rect2(t.pos - Vector2(16, 16), Vector2(32, 32)), Color("eceaba"), false, 1)
				draw_rect(Rect2(t.pos - Vector2(18, 18), Vector2(36, 36)), Color("6d9795"), false, 1)
	for b in game.bullets:
		var horizontal: bool = b.dir % 2 == 1
		var bullet_size := Vector2(6, 3) if horizontal else Vector2(3, 6)
		draw_rect(Rect2(b.pos - bullet_size / 2, bullet_size), Color("fff1be") if b.team == 0 else Color("ffb18b"))
	for cell in game.terrain:
		if game.terrain[cell] == "G":
			draw_terrain(cell, "G")
	for effect in game.effects:
		draw_explosion(effect)
	if game.flash_timer > 0:
		draw_rect(Rect2(0, 0, 416, 416), Color(0.75, 0.25, 0.1, game.flash_timer * 0.3))
	draw_set_transform(Vector2.ZERO)
	draw_hud()
	if game.state != "playing":
		draw_overlay()

func draw_terrain(cell: Vector2i, kind: String) -> void:
	var p := Vector2(cell * 16)
	if kind == "B":
		draw_rect(Rect2(p, Vector2(16, 16)), Color("502e26"))
		for row in range(2):
			var yy := p.y + row * 8
			var shift := 4 if row == 1 else 0
			for xx in range(-1, 3):
				var start := maxi(0, xx * 8 + shift)
				var end := mini(16, xx * 8 + shift + 7)
				if end > start:
					draw_rect(Rect2(p.x + start, yy, end - start, 7), TERRACOTTA)
					draw_rect(Rect2(p.x + start, yy, end - start, 1), Color("cf7952"))
	elif kind == "S":
		draw_rect(Rect2(p, Vector2(16, 16)), Color("535e61"))
		draw_rect(Rect2(p + Vector2.ONE, Vector2(13, 13)), Color("a6b4b0"))
		draw_rect(Rect2(p + Vector2(2, 2), Vector2(11, 2)), Color("dde0c7"))
		draw_rect(Rect2(p + Vector2(2, 4), Vector2(2, 8)), Color("c5cdbf"))
		draw_rect(Rect2(p + Vector2(6, 7), Vector2(6, 5)), Color("879694"))
	elif kind == "W":
		draw_rect(Rect2(p, Vector2(16, 16)), Color("173d55"))
		var phase := int(game.elapsed * 3) % 2
		for i in range(3):
			var offset := 2 if (i + phase) % 2 == 0 else 6
			draw_rect(Rect2(p + Vector2(offset, 3 + i * 5), Vector2(8, 1)), Color("447991"))
	elif kind == "G":
		# Fully opaque leaves conceal hulls; small gaps reveal tracks in motion.
		for y in range(4):
			for x in range(4):
				var seed_value := (cell.x * 7 + cell.y * 3 + x * 5 + y * 11) % 5
				var color: Color = [Color("294b2a"), Color("426b32"), Color("638540"), Color("345b2d"), Color("234526")][seed_value]
				draw_rect(Rect2(p + Vector2(x * 4, y * 4), Vector2(4, 3 if seed_value == 0 else 4)), color)

func draw_tank(pos: Vector2, direction: int, kind: String, anim: float = 0, hp: int = 1, hit: bool = false, scale_value: float = 1.0) -> void:
	var body := GOLD
	var light := Color("fff0a2")
	var dark := Color("a37d32")
	if kind == "regular":
		body = Color("b9c4b9"); light = Color("e2e6ce"); dark = Color("697c76")
	elif kind == "scout":
		body = Color("df7954"); light = Color("ffb284"); dark = Color("8b4536")
	elif kind == "gunner":
		body = Color("6cabc0"); light = Color("b7d9d3"); dark = Color("376475")
	elif kind == "armor":
		body = Color("9dba77"); light = Color("e0dfa1"); dark = Color("576e47")
	if hit:
		body = WHITE; light = WHITE; dark = Color("b3b69c")
	draw_set_transform(ORIGIN + pos, direction * PI / 2.0, Vector2.ONE * scale_value)
	draw_rect(Rect2(-13, -12, 7, 25), dark)
	draw_rect(Rect2(6, -12, 7, 25), dark)
	for y in range(-11, 13, 5):
		var track_y := y + (int(anim / 3) % 2)
		draw_rect(Rect2(-13, track_y, 7, 2), Color("242c2b"))
		draw_rect(Rect2(6, track_y, 7, 2), Color("242c2b"))
		draw_rect(Rect2(-12, track_y + 2, 2, 2), light)
		draw_rect(Rect2(10, track_y + 2, 2, 2), light)
	draw_rect(Rect2(-7, -10, 14, 21), body)
	draw_rect(Rect2(-5, -10, 10, 2), light)
	draw_rect(Rect2(-5, 8, 10, 3), dark)
	draw_rect(Rect2(-5, -6, 10, 11), dark)
	draw_rect(Rect2(-4, -7, 8, 10), body)
	draw_rect(Rect2(-3, -7, 6, 2), light)
	draw_rect(Rect2(-2, -18 if kind == "gunner" else -16, 4, 15 if kind == "gunner" else 13), dark)
	draw_rect(Rect2(-1, -18 if kind == "gunner" else -16, 2, 15 if kind == "gunner" else 13), light)
	if kind == "armor":
		for i in range(hp):
			draw_rect(Rect2(-5 + i * 4, 6, 2, 3), light)
	draw_set_transform(ORIGIN)

func draw_base() -> void:
	var p := Vector2(192, 384)
	draw_rect(Rect2(p, Vector2(32, 32)), Color("282a25"))
	if not game.base_alive:
		draw_rect(Rect2(p + Vector2(4, 24), Vector2(24, 5)), Color("685443"))
		draw_line(p + Vector2(6, 6), p + Vector2(26, 26), Color("8b4e3c"), 4)
		draw_line(p + Vector2(26, 6), p + Vector2(6, 26), Color("8b4e3c"), 4)
		return
	# An original geometric eagle insignia, not a traced cartridge sprite.
	var color := Color("d1c69b")
	for rect in [Rect2(14, 7, 5, 16), Rect2(5, 11, 22, 4), Rect2(3, 8, 5, 12), Rect2(24, 8, 5, 12), Rect2(8, 14, 4, 9), Rect2(20, 14, 4, 9), Rect2(12, 21, 9, 5), Rect2(18, 8, 4, 3)]:
		draw_rect(Rect2(p + rect.position, rect.size), color)
	draw_rect(Rect2(p + Vector2(15, 7), Vector2(2, 2)), Color("493d2d"))
	draw_rect(Rect2(p + Vector2(4, 28), Vector2(24, 2)), Color("756c4d"))

func draw_spawn(pos: Vector2, time_left: float) -> void:
	var radius := 8 + int(time_left * 22) % 12
	draw_rect(Rect2(pos - Vector2(radius, radius), Vector2.ONE * radius * 2), GOLD, false, 2)
	draw_line(pos - Vector2(11, 0), pos + Vector2(11, 0), WHITE, 2)
	draw_line(pos - Vector2(0, 11), pos + Vector2(0, 11), WHITE, 2)

func draw_supply(pos: Vector2) -> void:
	draw_rect(Rect2(pos - Vector2(12, 12), Vector2(24, 24)), Color("142b30"))
	draw_rect(Rect2(pos - Vector2(12, 12), Vector2(24, 24)), Color("8dbfc0"), false, 2)
	draw_rect(Rect2(pos - Vector2(6, 7), Vector2(12, 11)), Color("b5d6c1"), false, 2)
	draw_line(pos + Vector2(-6, 4), pos + Vector2(0, 9), Color("b5d6c1"), 2)
	draw_line(pos + Vector2(6, 4), pos + Vector2(0, 9), Color("b5d6c1"), 2)

func draw_explosion(e: Dictionary) -> void:
	var progress: float = 1.0 - e.life / e.max_life
	var radius: float = e.radius * (0.35 + progress)
	var pos: Vector2 = e.pos
	var color := GOLD if progress < 0.45 else TERRACOTTA
	for i in range(8):
		var angle := i * PI / 4
		var point := pos + Vector2(cos(angle), sin(angle)) * radius * progress
		var sz := maxf(2, radius * (1.0 - progress) * 0.6)
		draw_rect(Rect2(point.round() - Vector2.ONE * sz / 2, Vector2.ONE * sz), color)
	if progress < 0.5:
		draw_rect(Rect2(pos - Vector2(3, 3), Vector2(6, 6)), WHITE)

func draw_hud() -> void:
	text_at("STAGE", Vector2(464, 67), 11, MUTED)
	text_at("01", Vector2(464, 101), 34, PAPER)
	text_at("铁鹰据点", Vector2(522, 97), 14, PAPER)
	draw_rect(Rect2(464, 113, 152, 1), Color("3e4743"))
	text_at("敌军", Vector2(464, 137), 14, PAPER)
	text_at("%02d / 20" % (20 - game.killed), Vector2(548, 137), 13, GOLD)
	for i in range(20):
		var pos := Vector2(472 + (i % 5) * 29, 156 + (i / 5) * 23)
		var color := Color("9da698") if i < 20 - game.killed else Color("343c37")
		draw_rect(Rect2(pos + Vector2(-7, -4), Vector2(3, 12)), color)
		draw_rect(Rect2(pos + Vector2(5, -4), Vector2(3, 12)), color)
		draw_rect(Rect2(pos + Vector2(-3, -3), Vector2(7, 10)), color)
		draw_rect(Rect2(pos + Vector2(-1, -8), Vector2(3, 8)), color)
	text_at("击破  %02d" % game.killed, Vector2(464, 255), 12, MUTED)
	text_at("得分", Vector2(464, 282), 12, MUTED)
	text_at("%06d" % game.score, Vector2(464, 307), 25, PAPER)
	draw_rect(Rect2(464, 321, 152, 1), Color("3e4743"))
	text_at("生命", Vector2(464, 345), 13, MUTED)
	for i in range(3):
		var x := 528 + i * 29
		var color := GOLD if i < game.lives else Color("343c37")
		draw_rect(Rect2(x, 332, 4, 16), color)
		draw_rect(Rect2(x + 12, 332, 4, 16), color)
		draw_rect(Rect2(x + 5, 334, 6, 12), color)
		draw_rect(Rect2(x + 7, 328, 2, 10), color)
	text_at("基地", Vector2(464, 379), 13, MUTED)
	text_at("安全" if game.base_alive else "失守", Vector2(580, 379), 13, Color("9dba77") if game.base_alive else TERRACOTTA)
	draw_rect(pause_button, Color("242c29"))
	centered("继续  P" if game.state == "paused" else "暂停  P / Esc", 422, 12, PAPER, 540)
	text_at("WASD / 方向键  移动", Vector2(464, 449), 10, MUTED)
	text_at("空格 开火  ·  R 重开", Vector2(464, 466), 10, MUTED)
	# Small, legible bottom edge hints, rather than another panel.
	if game.state == "playing":
		var p := game.player()
		if not p.is_empty() and p.shield > 3.1:
			centered("护盾补给  %d 秒" % ceili(p.shield), 39, 11, Color("b5d6c1"))
		elif game.respawn_timer >= 0:
			centered("准备重新出击…", 39, 11, GOLD)

func button(rect: Rect2, label: String, primary: bool = true) -> void:
	var hover := rect.has_point(mouse_pos)
	var fill := GOLD if primary else Color("353e38")
	if hover:
		fill = fill.lightened(0.15)
	draw_rect(rect, fill)
	draw_rect(Rect2(rect.position + Vector2(2, 2), Vector2(rect.size.x - 4, 1)), Color("fff1bb") if primary else MUTED)
	centered(label, rect.position.y + rect.size.y / 2 + 6, 15 if primary else 12, INK if primary else PAPER, rect.get_center().x)

func draw_overlay() -> void:
	draw_rect(Rect2(ORIGIN, Vector2(416, 416)), Color(0.02, 0.04, 0.04, 0.88))
	var panel := Rect2(66, 106, 332, 294)
	draw_rect(panel, Color("121916"))
	draw_rect(panel, Color("8d855c"), false, 2)
	draw_rect(Rect2(panel.position + Vector2(5, 5), panel.size - Vector2(10, 10)), Color("343c2c"), false, 1)
	if game.state == "title":
		centered("一  单人守卫战  一", 136, 12, MUTED)
		pixel_text("TANK BATTLE", Vector2(102, 157), 4, GOLD)
		centered("铁 鹰 防 线", 220, 27, WHITE)
		centered("守住基地，击退 20 辆敌军。", 251, 14, PAPER)
		centered("砖墙可破坏  ·  钢墙不可穿透", 273, 11, MUTED)
		button(main_button, "开始作战   ENTER")
		centered("WASD / 方向键 移动    空格 射击", 353, 12, PAPER)
		centered("P 暂停   ·   R 重开   ·   M 音效", 375, 11, MUTED)
	elif game.state == "paused":
		centered("—  PAUSED  —", 151, 13, GOLD)
		centered("战斗暂停", 205, 32, WHITE)
		centered("防线正在等待你的归来。", 245, 14, PAPER)
		button(main_button, "继续作战   P / Esc")
		button(restart_button, "重新开始   R", false)
		centered("失去窗口焦点时会自动暂停", 387, 10, MUTED)
	else:
		var won: bool = game.state == "won"
		centered("—  MISSION CLEAR  —" if won else "—  GAME OVER  —", 149, 13, GOLD if won else TERRACOTTA)
		centered("防线守住了" if won else ("基地失守" if not game.base_alive else "战车耗尽"), 202, 30, WHITE)
		centered("击破 %02d / 20     得分 %06d" % [game.killed, game.score], 242, 14, PAPER)
		centered("任务用时  %02d:%02d" % [int(game.elapsed) / 60, int(game.elapsed) % 60], 268, 12, MUTED)
		button(main_button, "再次出击   ENTER")
		centered("每一次出击，都是新的防线。", 361, 12, MUTED)

func pixel_text(value: String, pos: Vector2, scale_value: int, color: Color) -> void:
	var alphabet := {
		"T": [31, 4, 4, 4, 4, 4, 4], "A": [14, 17, 17, 31, 17, 17, 17],
		"N": [17, 25, 25, 21, 19, 19, 17], "K": [17, 18, 20, 24, 20, 18, 17],
		"B": [30, 17, 17, 30, 17, 17, 30], "L": [16, 16, 16, 16, 16, 16, 31],
		"E": [31, 16, 16, 30, 16, 16, 31], " ": [0, 0, 0, 0, 0, 0, 0]
	}
	var offset := 0
	for letter in value:
		var rows: Array = alphabet.get(letter, alphabet[" "])
		for y in range(7):
			for x in range(5):
				if rows[y] & (1 << (4 - x)):
					draw_rect(Rect2(pos + Vector2(offset + x * scale_value, y * scale_value), Vector2.ONE * scale_value), color)
		offset += 6 * scale_value

func synthesize(kind: String) -> AudioStreamWAV:
	var seconds := 0.08
	var frequency := 440.0
	if kind == "fire": frequency = 680; seconds = 0.055
	elif kind == "brick": frequency = 160; seconds = 0.07
	elif kind == "armor": frequency = 930; seconds = 0.065
	elif kind == "kill": frequency = 150; seconds = 0.20
	elif kind == "death": frequency = 90; seconds = 0.35
	elif kind == "powerup": frequency = 520; seconds = 0.25
	elif kind == "win": frequency = 440; seconds = 0.6
	elif kind == "lose": frequency = 240; seconds = 0.5
	var data := PackedByteArray()
	var sample_rate := 22050
	var random := RandomNumberGenerator.new()
	random.seed = 32
	var phase := 0.0
	for i in range(int(seconds * sample_rate)):
		var progress := float(i) / (seconds * sample_rate)
		var pitch := frequency * (1.0 - progress * 0.65)
		if kind in ["powerup", "win"]:
			pitch = frequency * pow(1.26, floor(progress * 4))
		phase += pitch / sample_rate
		var wave := 0.65 if fmod(phase, 1) < 0.45 else -0.65
		if kind in ["brick", "kill", "death"]:
			wave = wave * 0.35 + random.randf_range(-0.65, 0.65)
		var sample_value := int(wave * (1.0 - progress) * 14000)
		data.append(sample_value & 255)
		data.append((sample_value >> 8) & 255)
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = sample_rate
	stream.data = data
	return stream

func play_sound(kind: String) -> void:
	if game.mute or not sounds.has(kind):
		return
	voices[voice_index].stream = sounds[kind]
	voices[voice_index].play()
	voice_index = (voice_index + 1) % voices.size()
