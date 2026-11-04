extends Node2D

## The UI never advances combat and never pauses the server. All gameplay input
## passes through BattleNetwork; only the host owns the simulation.
const NetworkModel = preload("res://scripts/network.gd")
const FONT = preload("res://assets/fonts/Interface.ttf")
# Combat stays in one shared 736 × 416 server coordinate system. The camera is
# presentation-only: uniform fit, with continuous countryside beyond the arena.
const DESIGN_SIZE := Vector2(640, 480)
const FIELD_COLOR := Color("131c18")
const BLINK_HZ := 3.0
const INK := Color("131719")
const PAPER := Color("d6d5bc")
const MUTED := Color("8d9690")
const GOLD := Color("f3c65c")
const WHITE := Color("f0eddb")
const TERRACOTTA := Color("ad563d")
const RED := Color("e47f64")
const BLUE := Color("70b6ce")
var net = NetworkModel.new()
var game:
	get:
		return net.game
var key_order: Array[int] = []
var muted := false
var local_menu := false
var last_mode := ""
var title_time := 0.0
var message := ""
var sounds: Dictionary = {}
var voices: Array[AudioStreamPlayer] = []
var voice_index := 0
@onready var ui: Control = %Ui
@onready var entry_panel: Control = %EntryPanel
@onready var room_panel: Control = %RoomPanel
@onready var connecting_panel: Control = %ConnectingPanel
@onready var menu_panel: Control = %MenuPanel
@onready var result_panel: Control = %ResultPanel
@onready var name_field: LineEdit = %NameField
@onready var address_field: LineEdit = %AddressField
@onready var port_field: SpinBox = %PortField
@onready var team_field: OptionButton = %TeamField
@onready var ready_button: Button = %ReadyButton
@onready var start_button: Button = %StartButton
@onready var menu_button: Button = %MenuButton
@onready var status_label: Label = %StatusLabel
@onready var room_status: Label = %RoomStatus
@onready var result_label: Label = %ResultLabel
@onready var rematch_button: Button = %RematchButton
@onready var room_button: Button = %RoomButton
@onready var confirm_dialog: ConfirmationDialog = %ConfirmDialog
var pending_action := ""
var viewport_size := DESIGN_SIZE
var ui_origin := Vector2.ZERO
var ui_scale := 1.0
var field_origin := Vector2.ZERO
var field_scale := 1.0
@onready var hud_layer: Control = %HudLayer
@onready var menu_backdrop: ColorRect = %MenuBackdrop

func _ready() -> void:
	get_window().min_size = Vector2i(640, 480)
	get_tree().auto_accept_quit = false
	%BattlefieldLayout.hide()
	net.battlefield_layout = %BattlefieldLayout
	net.name = "Network"
	net.changed.connect(_refresh)
	net.notice.connect(_on_notice)
	net.snapshot_received.connect(_on_snapshot)
	add_child(net)
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
	for kind in ["fire", "brick", "armor", "kill", "death", "win", "lose"]:
		sounds[kind] = synthesize(kind)
	get_viewport().size_changed.connect(_layout_viewport)
	_layout_viewport()
	_refresh()

func _layout_viewport() -> void:
	viewport_size = get_viewport_rect().size
	ui_scale = minf(viewport_size.x / DESIGN_SIZE.x, viewport_size.y / DESIGN_SIZE.y)
	ui_origin = ((viewport_size - DESIGN_SIZE * ui_scale) / 2.0).round()
	ui.position = ui_origin
	ui.scale = Vector2.ONE * ui_scale
	field_scale = minf(viewport_size.x / game.WIDTH, viewport_size.y / game.HEIGHT)
	field_origin = ((viewport_size - Vector2(game.WIDTH, game.HEIGHT) * field_scale) / 2.0).round()
	%BattleReadouts.size = viewport_size / ui_scale
	%BattleReadouts.scale = Vector2.ONE * ui_scale
	hud_layer.size = viewport_size
	# Overlay sizing follows the UI, not the world: compact on every aspect ratio.
	menu_button.scale = Vector2.ONE * ui_scale
	menu_button.position = viewport_size - Vector2(124, 46) * ui_scale
	menu_backdrop.size = viewport_size
	queue_redraw()

func _world_transform() -> void:
	draw_set_transform(field_origin, 0, Vector2.ONE * field_scale)

# Authoritative protection gates the effect. Hit flashes and UI time never grant
# immunity. Use snapshot elapsed time so every peer sees the same ~3 Hz phase.
func invulnerability_alpha(shield: float, elapsed: float) -> float:
	return 0.28 if shield > 0.0 and fmod(elapsed * BLINK_HZ, 1.0) >= 0.5 else 1.0

func _on_snapshot() -> void:
	# The reliable room-state update can arrive before its final combat snapshot.
	# Refresh winner text after the authoritative snapshot, not just on mode change.
	if net.mode == "ended":
		_refresh()

func _on_notice(value: String) -> void:
	message = value
	_refresh()

func _host() -> void:
	message = ""
	var error: int = net.host_room(name_field.text, int(port_field.value))
	if error != OK:
		message = "创建房间失败（错误 %d），请检查 UDP 端口。" % error
	_refresh()

func _join() -> void:
	message = ""
	var error: int = net.join_room(name_field.text, address_field.text.strip_edges(), int(port_field.value))
	if error != OK:
		message = "连接失败（错误 %d），请检查地址和 UDP 端口。" % error
	_refresh()

func _team_selected(index: int) -> void:
	net.set_profile(name_field.text, index)

func _toggle_ready() -> void:
	var me: Dictionary = net.roster.get(net.local_id, {})
	net.set_ready(not me.get("ready", false))

func _start() -> void:
	message = ""
	if not net.start_match():
		message = net.can_start()
	_refresh()

func _rematch() -> void:
	if net.is_host():
		net.return_to_lobby()

func _confirm(action: String) -> void:
	pending_action = action
	confirm_dialog.dialog_text = "结束当前对战，让所有玩家返回房间？" if action == "room" else ("你是房主，离开会断开所有玩家。确认离开？" if net.is_host() else "确认退出房间并断开连接？")
	confirm_dialog.popup_centered(Vector2i(430, 140))

func _confirmed() -> void:
	var quitting := pending_action == "quit"
	if pending_action == "room":
		local_menu = false
		net.return_to_lobby()
	else:
		_leave()
	pending_action = ""
	_refresh()
	if quitting:
		get_tree().quit()

func _leave() -> void:
	local_menu = false
	net.leave_room()
	_refresh()

func _toggle_menu() -> void:
	if net.mode != "playing":
		return
	local_menu = not local_menu
	key_order.clear()
	net.submit_input(-1, false)
	_release_focus()
	_refresh()

func _release_focus() -> void:
	var focus := get_viewport().gui_get_focus_owner()
	if focus != null:
		focus.release_focus()

func _refresh() -> void:
	if ui == null:
		return
	if net.mode != last_mode:
		local_menu = false
		key_order.clear()
		_release_focus()
		if net.mode in ["lobby", "playing"]:
			message = ""
		last_mode = net.mode
	%Header.visible = net.mode not in ["playing", "ended"]
	%BattleReadouts.visible = not %Header.visible
	entry_panel.visible = net.mode == "offline"
	room_panel.visible = net.mode == "lobby"
	connecting_panel.visible = net.mode == "connecting"
	menu_button.visible = net.mode == "playing" and not local_menu
	menu_panel.visible = net.mode == "playing" and local_menu
	menu_backdrop.visible = menu_panel.visible
	result_panel.visible = net.mode == "ended"
	room_button.visible = net.is_host()
	status_label.text = message if not message.is_empty() else net.reason
	if net.mode == "lobby":
		var me: Dictionary = net.roster.get(net.local_id, {})
		_update_room()
		team_field.select(int(me.get("team", 0)))
		ready_button.text = "房主已准备" if net.is_host() else ("取消准备" if me.get("ready", false) else "准备")
		ready_button.disabled = net.is_host()
		start_button.text = "开始对战" if net.is_host() else "等待房主开始"
		var blocked: String = net.can_start()
		start_button.disabled = not net.is_host() or not blocked.is_empty()
		room_status.text = message if not message.is_empty() else ("全员准备就绪，房主可以开始对战。" if blocked.is_empty() else blocked)
	if net.mode == "ended":
		result_label.text = "双方平局" if game.winner == 2 else ("红队获胜" if game.winner == 0 else "蓝队获胜")
		result_label.add_theme_color_override("font_color", RED if game.winner == 0 else (BLUE if game.winner == 1 else GOLD))
		rematch_button.text = "返回房间 / 再战" if net.is_host() else "等待房主再战"
		rematch_button.disabled = not net.is_host()
	queue_redraw()

func _input(event: InputEvent) -> void:
	if event is InputEventKey and not event.echo:
		var code: int = event.physical_keycode
		var direction := key_direction(code)
		if direction >= 0:
			if event.pressed:
				key_order.erase(direction)
				key_order.append(direction)
			elif not Input.is_action_pressed(["move_up", "move_right", "move_down", "move_left"][direction]):
				key_order.erase(direction)
		if event.pressed and net.mode == "playing":
			if code == KEY_ESCAPE and not confirm_dialog.visible:
				_toggle_menu()
				get_viewport().set_input_as_handled()
			elif code == KEY_M:
				muted = not muted

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		if net.mode == "offline":
			get_tree().quit()
		elif confirm_dialog != null:
			_confirm("quit")
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT and net != null and net.mode == "playing":
		local_menu = true
		key_order.clear()
		net.submit_input(-1, false)
		_refresh()

func key_direction(key: int) -> int:
	if key in [KEY_W, KEY_UP]: return 0
	if key in [KEY_D, KEY_RIGHT]: return 1
	if key in [KEY_S, KEY_DOWN]: return 2
	if key in [KEY_A, KEY_LEFT]: return 3
	return -1

func _physics_process(dt: float) -> void:
	var direction := -1
	var active: bool = net.mode == "playing" and not local_menu and not confirm_dialog.visible
	var focus := get_viewport().gui_get_focus_owner()
	if focus is LineEdit or focus is TextEdit:
		active = false
	if active:
		for candidate in key_order:
			if Input.is_action_pressed(["move_up", "move_right", "move_down", "move_left"][candidate]):
				direction = candidate
	net.submit_input(direction, active and Input.is_action_pressed("fire"))
	for event in game.events:
		play_sound(event)
	game.events.clear()
	if net.mode in ["playing", "ended"]:
		_update_hud()
	title_time += dt
	if net.mode != last_mode:
		_refresh()
	queue_redraw()

func _update_room() -> void:
	%RoomTitle.text = "对战房间 / {count} 人（最多 8 人）".format({"count": net.roster.size()})
	%Port.text = "UDP {port}".format({"port": net.port})
	for team: int in 2:
		var area: Control = %Red if team == 0 else %Blue
		var members: Array = net.roster.values().filter(func(player: Dictionary) -> bool: return player.team == team)
		for i: int in 4:
			var seat: Control = area.get_node("Seat%d" % (i+1))
			var name_label: Label = seat.get_node("Player")
			var ready_label: Label = seat.get_node("Ready")
			if i >= members.size():
				name_label.text = "+  等待玩家"
				ready_label.text = ""
				continue
			var player: Dictionary = members[i]
			name_label.text = ("> " if player.id == net.local_id else "") + str(player.name)
			ready_label.text = "房主" if player.id == 1 else ("已准备" if player.ready else "未准备")

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, viewport_size), INK)
	if net.mode in ["playing", "ended"]:
		_draw_battle()

func _draw_battle() -> void:
	# No panel, decorative arena frame or letterbox: the same ground continues to
	# every physical viewport edge. Terrain outside server bounds is scenery only.
	draw_rect(Rect2(Vector2.ZERO, viewport_size), FIELD_COLOR)
	_world_transform()
	_draw_ground()
	for cell in game.terrain:
		var kind: String = game.terrain[cell]
		if kind != "G":
			draw_terrain(cell, kind)
	for base in game.bases:
		draw_base(base)
	for tank in game.tanks:
		var opacity := invulnerability_alpha(tank.shield, game.elapsed)
		draw_tank(tank.pos, tank.dir, "red" if tank.team == 0 else "blue", tank.anim, 1, tank.hit > 0, 1.0, opacity)
		if tank.id == net.local_id:
			# A tiny identifying dot, never a focus frame or a shield outline.
			draw_rect(Rect2(tank.pos + Vector2(-1, 17), Vector2(3, 2)), GOLD)
	for bullet in game.bullets:
		var bullet_size := Vector2(6, 3) if bullet.dir % 2 == 1 else Vector2(3, 6)
		draw_rect(Rect2(bullet.pos - bullet_size / 2, bullet_size), Color("ffcaad") if bullet.team == 0 else Color("bcefff"))
	for cell in game.terrain:
		if game.terrain[cell] == "G":
			draw_terrain(cell, "G")
	for effect in game.effects:
		draw_explosion(effect)
	draw_set_transform(Vector2.ZERO)


func _draw_ground() -> void:
	var start := Vector2i((-field_origin / field_scale / 16.0).floor()) - Vector2i.ONE
	var end := Vector2i(((viewport_size - field_origin) / field_scale / 16.0).ceil()) + Vector2i.ONE
	for y in range(start.y, end.y):
		for x in range(start.x, end.x):
			var cell := Vector2i(x, y)
			var seed_value := absi(x * 17 + y * 31 + x * y * 3)
			var p := Vector2(cell * 16)
			# Low-contrast flecks give the entire viewport one continuous pixel floor.
			draw_rect(Rect2(p + Vector2(seed_value % 13, (seed_value / 7) % 13), Vector2(2, 1)), Color("243027"))
			if x >= 0 and x < game.WIDTH / 16 and y >= 0 and y < game.HEIGHT / 16:
				continue
			# Natural, irregular scrub marks impassable countryside; no hard outline.
			# It is decoration only and never appears in the replicated terrain map.
			# Dense treetops connect across tiles, so no apparently walkable void
			# is hidden behind an invisible wall. Irregular crowns avoid a UI frame.
			var inset := Vector2(seed_value % 4, (seed_value / 3) % 4)
			draw_rect(Rect2(p, Vector2(16, 16)), Color("192c20"))
			draw_rect(Rect2(p + Vector2(1, 3), Vector2(15, 11)), Color("27432b"))
			draw_rect(Rect2(p + inset, Vector2(12, 12)), Color("2e4b30"))
			draw_rect(Rect2(p + inset + Vector2(2, 1), Vector2(7, 3)), Color("3a5836"))
			draw_rect(Rect2(p + Vector2(8, 10), Vector2(8, 6)), Color("203b29"))

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

func draw_tank(pos: Vector2, direction: int, kind: String, anim: float = 0, hp: int = 1, hit: bool = false, scale_value: float = 1.0, opacity: float = 1.0) -> void:
	var body := GOLD
	var light := Color("fff0a2")
	var dark := Color("a37d32")
	if kind == "red":
		body = RED; light = Color("ffb99a"); dark = Color("8b4536")
	elif kind == "blue":
		body = BLUE; light = Color("b7e1e8"); dark = Color("376475")
	elif kind == "regular":
		body = Color("b9c4b9"); light = Color("e2e6ce"); dark = Color("697c76")
	elif kind == "scout":
		body = Color("df7954"); light = Color("ffb284"); dark = Color("8b4536")
	elif kind == "gunner":
		body = Color("6cabc0"); light = Color("b7d9d3"); dark = Color("376475")
	elif kind == "armor":
		body = Color("9dba77"); light = Color("e0dfa1"); dark = Color("576e47")
	if hit:
		body = WHITE; light = WHITE; dark = Color("b3b69c")
	draw_set_transform(field_origin + pos * field_scale, direction * PI / 2.0, Vector2.ONE * scale_value * field_scale)
	draw_rect(Rect2(-13, -12, 7, 25), Color(dark, opacity))
	draw_rect(Rect2(6, -12, 7, 25), Color(dark, opacity))
	for y in range(-11, 13, 5):
		var track_y := y + (int(anim / 3) % 2)
		draw_rect(Rect2(-13, track_y, 7, 2), Color(Color("242c2b"), opacity))
		draw_rect(Rect2(6, track_y, 7, 2), Color(Color("242c2b"), opacity))
		draw_rect(Rect2(-12, track_y + 2, 2, 2), Color(light, opacity))
		draw_rect(Rect2(10, track_y + 2, 2, 2), Color(light, opacity))
	draw_rect(Rect2(-7, -10, 14, 21), Color(body, opacity))
	draw_rect(Rect2(-5, -10, 10, 2), Color(light, opacity))
	draw_rect(Rect2(-5, 8, 10, 3), Color(dark, opacity))
	draw_rect(Rect2(-5, -6, 10, 11), Color(dark, opacity))
	draw_rect(Rect2(-4, -7, 8, 10), Color(body, opacity))
	draw_rect(Rect2(-3, -7, 6, 2), Color(light, opacity))
	draw_rect(Rect2(-2, -16, 4, 13), Color(dark, opacity))
	draw_rect(Rect2(-1, -16, 2, 13), Color(light, opacity))
	if kind == "armor":
		for i in range(hp):
			draw_rect(Rect2(-5 + i * 4, 6, 2, 3), Color(light, opacity))
	_world_transform()

func draw_base(base: Dictionary) -> void:
	var p: Vector2 = base.pos
	var color := RED if base.team == 0 else BLUE
	draw_rect(Rect2(p, Vector2(32, 32)), Color("282a25"))
	if base.hp <= 0:
		draw_line(p + Vector2(6, 6), p + Vector2(26, 26), color.darkened(0.3), 4)
		draw_line(p + Vector2(26, 6), p + Vector2(6, 26), color.darkened(0.3), 4)
		return
	var symbol := Color(color, invulnerability_alpha(base.shield, game.elapsed))
	for rect in [Rect2(14, 7, 5, 16), Rect2(5, 11, 22, 4), Rect2(3, 8, 5, 12), Rect2(24, 8, 5, 12), Rect2(8, 14, 4, 9), Rect2(20, 14, 4, 9), Rect2(12, 21, 9, 5), Rect2(18, 8, 4, 3)]:
		draw_rect(Rect2(p + rect.position, rect.size), symbol)
	draw_rect(Rect2(p + Vector2(15, 7), Vector2(2, 2)), INK)
	# HP remains visible in both phases; only the base symbol blinks.
	for i in range(game.BASE_HP):
		draw_rect(Rect2(p + Vector2(2 + i * 6, 1), Vector2(4, 2)), color if i < base.hp else Color("3c423a"))

func draw_explosion(effect: Dictionary) -> void:
	var progress: float = 1.0 - effect.life / effect.max_life
	var radius: float = float(effect.get("radius", effect.get("size", 14))) * (0.35 + progress)
	var pos: Vector2 = effect.pos
	var color := GOLD if progress < 0.45 else TERRACOTTA
	for i in range(8):
		var angle := i * PI / 4
		var point := pos + Vector2(cos(angle), sin(angle)) * radius * progress
		var sz := maxf(2, radius * (1.0 - progress) * 0.6)
		draw_rect(Rect2(point.round() - Vector2.ONE * sz / 2, Vector2.ONE * sz), color)
	if progress < 0.5:
		draw_rect(Rect2(pos - Vector2(3, 3), Vector2(6, 6)), WHITE)

func _update_hud() -> void:
	for team: int in game.bases.size():
		var base: Dictionary = game.bases[team]
		var readout: Control = %RedBase if team == 0 else %BlueBase
		readout.get_node("Health").text = "{hp} / {max}".format({"hp": base.hp, "max": game.BASE_HP})
		for i: int in game.BASE_HP:
			readout.get_node("Point%d" % (i+1)).modulate = Color.WHITE if i < base.hp else Color("354039")
	var me: Dictionary = game.players.get(net.local_id, {})
	%Respawn.visible = not me.is_empty() and float(me.respawn) >= 0
	if %Respawn.visible:
		%Respawn.text = "等待出生位置" if me.respawn <= 0.02 else "复活 %.1f 秒" % me.respawn

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
	if muted or not sounds.has(kind) or voices.is_empty():
		return
	voices[voice_index].stream = sounds[kind]
	voices[voice_index].play()
	voice_index = (voice_index + 1) % voices.size()
