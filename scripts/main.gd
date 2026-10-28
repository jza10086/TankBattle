extends Node2D

## The UI never advances combat and never pauses the server. All gameplay input
## passes through BattleNetwork; only the host owns the simulation.
const NetworkModel = preload("res://scripts/network.gd")
const FONT = preload("res://assets/fonts/Interface.ttf")
const ORIGIN := Vector2(24, 48)
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
var ui: Control
var entry_panel: Control
var room_panel: Control
var connecting_panel: Control
var menu_panel: Control
var result_panel: Control
var name_field: LineEdit
var address_field: LineEdit
var port_field: SpinBox
var team_field: OptionButton
var ready_button: Button
var start_button: Button
var menu_button: Button
var status_label: Label
var room_status: Label
var result_label: Label
var rematch_button: Button
var room_button: Button
var confirm_dialog: ConfirmationDialog
var pending_action := ""

func _ready() -> void:
	get_window().min_size = Vector2i(640, 480)
	get_tree().auto_accept_quit = false
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
	_build_ui()
	_refresh()

func _style(fill: Color, border: Color = Color("48534d")) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = fill
	style.border_color = border
	style.set_border_width_all(1)
	style.content_margin_left = 9
	style.content_margin_right = 9
	style.content_margin_top = 4
	style.content_margin_bottom = 4
	return style

func _control(parent: Control, rect: Rect2) -> Control:
	var node := Control.new()
	node.position = rect.position
	node.size = rect.size
	node.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(node)
	return node

func _label(parent: Control, value: String, rect: Rect2, font_size: int = 13, color: Color = PAPER) -> Label:
	var label := Label.new()
	label.text = value
	label.position = rect.position
	label.size = rect.size
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(label)
	return label

func _button(parent: Control, value: String, rect: Rect2, action: Callable, primary: bool = false) -> Button:
	var button := Button.new()
	button.text = value
	button.position = rect.position
	button.size = rect.size
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	if primary:
		button.add_theme_stylebox_override("normal", _style(GOLD, GOLD))
		button.add_theme_stylebox_override("hover", _style(GOLD.lightened(0.12), WHITE))
		button.add_theme_stylebox_override("pressed", _style(GOLD.darkened(0.13), WHITE))
		button.add_theme_color_override("font_color", INK)
		button.add_theme_color_override("font_hover_color", INK)
		button.add_theme_color_override("font_pressed_color", INK)
	button.pressed.connect(action)
	parent.add_child(button)
	return button

func _build_ui() -> void:
	ui = Control.new()
	ui.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	ui.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var theme := Theme.new()
	theme.default_font = FONT
	theme.default_font_size = 13
	for type in ["Button", "OptionButton"]:
		theme.set_stylebox("normal", type, _style(Color("28332d")))
		theme.set_stylebox("hover", type, _style(Color("3b4940"), PAPER))
		theme.set_stylebox("pressed", type, _style(Color("1a211e"), GOLD))
		theme.set_stylebox("focus", type, _style(Color(0, 0, 0, 0), GOLD))
		theme.set_stylebox("disabled", type, _style(Color("1c2420"), Color("354039")))
		theme.set_color("font_color", type, PAPER)
		theme.set_color("font_disabled_color", type, Color("6b786f"))
	theme.set_stylebox("normal", "LineEdit", _style(Color("101713")))
	theme.set_stylebox("focus", "LineEdit", _style(Color("101713"), GOLD))
	theme.set_color("font_color", "LineEdit", WHITE)
	ui.theme = theme
	add_child(ui)
	entry_panel = _control(ui, Rect2(0, 0, 640, 480))
	_label(entry_panel, "玩家名称", Rect2(150, 167, 100, 30), 11, MUTED)
	name_field = LineEdit.new()
	name_field.position = Vector2(260, 166)
	name_field.size = Vector2(230, 31)
	name_field.text = "Player"
	name_field.max_length = 16
	entry_panel.add_child(name_field)
	_label(entry_panel, "房主地址", Rect2(150, 213, 110, 30), 11, MUTED)
	address_field = LineEdit.new()
	address_field.position = Vector2(260, 212)
	address_field.size = Vector2(230, 31)
	address_field.text = "127.0.0.1"
	address_field.placeholder_text = "局域网 / 公网 IP"
	address_field.max_length = 128
	entry_panel.add_child(address_field)
	_label(entry_panel, "UDP 端口", Rect2(150, 259, 110, 30), 11, MUTED)
	port_field = SpinBox.new()
	port_field.position = Vector2(260, 258)
	port_field.size = Vector2(230, 31)
	port_field.min_value = 1024
	port_field.max_value = 65535
	port_field.value = 7777
	entry_panel.add_child(port_field)
	_button(entry_panel, "创建房间", Rect2(150, 314, 164, 36), _host, true)
	_button(entry_panel, "加入房间", Rect2(326, 314, 164, 36), _join)
	status_label = _label(entry_panel, "", Rect2(112, 366, 416, 44), 12, RED)
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label(entry_panel, "局域网 / IP 直连；公网房主需自行转发 UDP 端口。", Rect2(101, 422, 450, 22), 10, MUTED)
	_label(entry_panel, "WASD / 方向键 移动　空格 开火　Esc 本地菜单", Rect2(101, 445, 450, 22), 10, PAPER)

	room_panel = _control(ui, Rect2(0, 0, 640, 480))
	_label(room_panel, "我的队伍", Rect2(30, 323, 90, 30), 11, MUTED)
	team_field = OptionButton.new()
	team_field.position = Vector2(113, 322)
	team_field.size = Vector2(133, 32)
	team_field.add_item("红队 / 北侧", 0)
	team_field.add_item("蓝队 / 南侧", 1)
	team_field.item_selected.connect(_team_selected)
	room_panel.add_child(team_field)
	ready_button = _button(room_panel, "准备", Rect2(258, 322, 122, 32), _toggle_ready)
	start_button = _button(room_panel, "开始对战", Rect2(392, 322, 218, 32), _start, true)
	room_status = _label(room_panel, "", Rect2(30, 368, 580, 40), 12, GOLD)
	room_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_button(room_panel, "离开房间", Rect2(452, 424, 158, 30), func(): _confirm("leave"))
	_label(room_panel, "2–8 名真人玩家 · 每队最多 4 人 · 无 AI", Rect2(30, 427, 400, 22), 11, MUTED)

	connecting_panel = _control(ui, Rect2(0, 0, 640, 480))
	_label(connecting_panel, "正在连接房主…", Rect2(176, 216, 310, 32), 18, GOLD)
	_button(connecting_panel, "取消连接", Rect2(232, 287, 176, 36), _leave)
	menu_button = _button(ui, "菜单 / Esc", Rect2(464, 405, 152, 28), _toggle_menu)

	menu_panel = _control(ui, Rect2(0, 0, 640, 480))
	var dim := ColorRect.new()
	dim.color = Color(0.02, 0.04, 0.03, 0.75)
	dim.size = Vector2(640, 480)
	menu_panel.add_child(dim)
	_label(menu_panel, "本地菜单", Rect2(215, 130, 260, 35), 24, GOLD)
	_label(menu_panel, "联机对战仍在继续；你的战车暂时停止操作。", Rect2(137, 183, 390, 28), 12, PAPER)
	_button(menu_panel, "返回战场", Rect2(204, 230, 232, 36), _toggle_menu, true)
	room_button = _button(menu_panel, "结束本局，返回房间", Rect2(204, 280, 232, 32), func(): _confirm("room"))
	_button(menu_panel, "离开房间", Rect2(204, 324, 232, 32), func(): _confirm("leave"))

	result_panel = _control(ui, Rect2(0, 0, 640, 480))
	var shade := ColorRect.new()
	shade.position = Vector2(57, 148)
	shade.size = Vector2(350, 214)
	shade.color = Color(0.04, 0.07, 0.06, 0.96)
	result_panel.add_child(shade)
	result_label = _label(result_panel, "", Rect2(67, 171, 330, 46), 28, GOLD)
	result_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label(result_panel, "本局对战结束", Rect2(91, 220, 282, 24), 12, PAPER).horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	rematch_button = _button(result_panel, "返回房间 / 再战", Rect2(100, 269, 264, 34), _rematch, true)
	_button(result_panel, "离开房间", Rect2(100, 312, 264, 29), func(): _confirm("leave"))

	confirm_dialog = ConfirmationDialog.new()
	confirm_dialog.title = "确认离开？"
	confirm_dialog.ok_button_text = "确认"
	confirm_dialog.cancel_button_text = "取消"
	confirm_dialog.confirmed.connect(_confirmed)
	ui.add_child(confirm_dialog)

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
	entry_panel.visible = net.mode == "offline"
	room_panel.visible = net.mode == "lobby"
	connecting_panel.visible = net.mode == "connecting"
	menu_button.visible = net.mode == "playing" and not local_menu
	menu_panel.visible = net.mode == "playing" and local_menu
	result_panel.visible = net.mode == "ended"
	room_button.visible = net.is_host()
	status_label.text = message if not message.is_empty() else net.reason
	if net.mode == "lobby":
		var me: Dictionary = net.roster.get(net.local_id, {})
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
	title_time += dt
	if net.mode != last_mode:
		_refresh()
	queue_redraw()

func text_at(value: String, pos: Vector2, size: int = 14, color: Color = WHITE) -> void:
	draw_string(FONT, pos, value, HORIZONTAL_ALIGNMENT_LEFT, -1, size, color)

func _fit_name(value: String, width: float, font_size: int) -> String:
	if FONT.get_string_size(value, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x <= width:
		return value
	while not value.is_empty() and FONT.get_string_size(value + "..", HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x > width:
		value = value.left(value.length() - 1)
	return value + ".."

func centered(value: String, y: float, size: int = 16, color: Color = WHITE, x: float = 320.0) -> void:
	var width := FONT.get_string_size(value, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	text_at(value, Vector2(x - width / 2, y), size, color)

func _draw() -> void:
	draw_rect(Rect2(0, 0, 640, 480), INK)
	text_at("铁鹰防线", Vector2(24, 30), 22, GOLD)
	text_at("T A N K   B A T T L E", Vector2(166, 28), 11, MUTED)
	text_at("团队联机", Vector2(518, 28), 11, PAPER)
	if net.mode in ["playing", "ended"]:
		_draw_battle()
	elif net.mode == "lobby":
		_draw_room()
	elif net.mode == "offline":
		centered("红蓝团队对抗", 94, 30, GOLD)
		centered("2–8 人实时联机 · 击毁敌方基地获胜", 125, 12, PAPER)
		draw_rect(Rect2(134, 146, 372, 216), Color("1c2520"))
		draw_rect(Rect2(134, 146, 372, 216), Color("475343"), false, 1)

func _draw_room() -> void:
	text_at("对战房间 / %d 人（最多 8 人）" % net.roster.size(), Vector2(30, 71), 18, GOLD)
	text_at("UDP %d" % net.port, Vector2(516, 70), 11, MUTED)
	for team in range(2):
		var x := 30 + team * 300
		var color := RED if team == 0 else BLUE
		draw_rect(Rect2(x, 89, 280, 29), color.darkened(0.7))
		text_at("红队 / 北侧" if team == 0 else "蓝队 / 南侧", Vector2(x + 12, 109), 13, color)
		var members: Array = []
		for id in net.roster:
			if net.roster[id].team == team:
				members.append(net.roster[id])
		for slot in range(4):
			var y := 125 + slot * 43
			draw_rect(Rect2(x, y, 280, 37), Color("202a24"))
			if slot >= members.size():
				text_at("+  等待玩家", Vector2(x + 13, y + 24), 12, Color("58675d"))
				continue
			var player: Dictionary = members[slot]
			var is_local: bool = player.id == net.local_id
			text_at(("> " if is_local else "  ") + _fit_name(str(player.name), 172, 13), Vector2(x + 10, y + 24), 13, WHITE if is_local else PAPER)
			var ready: bool = player.get("ready", false)
			text_at("房主" if player.id == 1 else ("已准备" if ready else "未准备"), Vector2(x + 222, y + 24), 10, GOLD if ready else MUTED)
			if is_local:
				draw_rect(Rect2(x, y, 280, 37), color, false, 1)

func _draw_battle() -> void:
	draw_rect(Rect2(ORIGIN - Vector2(3, 3), Vector2(422, 422)), Color("62665d"))
	draw_rect(Rect2(ORIGIN, Vector2(416, 416)), Color("090d0e"))
	draw_set_transform(ORIGIN)
	for cell in game.terrain:
		var kind: String = game.terrain[cell]
		if kind != "G":
			draw_terrain(cell, kind)
	for y in range(13):
		for x in range(13):
			var point := Vector2(x * 32 + 8, y * 32 + 24)
			if not game.terrain.has(Vector2i(point / 16)):
				draw_rect(Rect2(point, Vector2.ONE), Color("1c2424"))
	for base in game.bases:
		draw_base(base)
	for tank in game.tanks:
		draw_tank(tank.pos, tank.dir, "red" if tank.team == 0 else "blue", tank.anim, 1, tank.hit > 0)
		if tank.shield > 0 and int(tank.shield * 12) % 2 == 0:
			draw_rect(Rect2(tank.pos - Vector2(17, 17), Vector2(34, 34)), Color("f3ecc3"), false, 1)
			draw_rect(Rect2(tank.pos - Vector2(19, 19), Vector2(38, 38)), Color("729fa7"), false, 1)
		if tank.id == net.local_id:
			draw_line(tank.pos + Vector2(-4, 17), tank.pos + Vector2(4, 17), GOLD, 2)
	for bullet in game.bullets:
		var bullet_size := Vector2(6, 3) if bullet.dir % 2 == 1 else Vector2(3, 6)
		draw_rect(Rect2(bullet.pos - bullet_size / 2, bullet_size), Color("ffcaad") if bullet.team == 0 else Color("bcefff"))
	for cell in game.terrain:
		if game.terrain[cell] == "G":
			draw_terrain(cell, "G")
	for effect in game.effects:
		draw_explosion(effect)
	draw_set_transform(Vector2.ZERO)
	draw_hud()

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
	draw_rect(Rect2(-2, -16, 4, 13), dark)
	draw_rect(Rect2(-1, -16, 2, 13), light)
	if kind == "armor":
		for i in range(hp):
			draw_rect(Rect2(-5 + i * 4, 6, 2, 3), light)
	draw_set_transform(ORIGIN)

func draw_base(base: Dictionary) -> void:
	var p: Vector2 = base.pos
	var color := RED if base.team == 0 else BLUE
	draw_rect(Rect2(p, Vector2(32, 32)), Color("282a25"))
	if base.hp <= 0:
		draw_line(p + Vector2(6, 6), p + Vector2(26, 26), color.darkened(0.3), 4)
		draw_line(p + Vector2(26, 6), p + Vector2(6, 26), color.darkened(0.3), 4)
		return
	for rect in [Rect2(14, 7, 5, 16), Rect2(5, 11, 22, 4), Rect2(3, 8, 5, 12), Rect2(24, 8, 5, 12), Rect2(8, 14, 4, 9), Rect2(20, 14, 4, 9), Rect2(12, 21, 9, 5), Rect2(18, 8, 4, 3)]:
		draw_rect(Rect2(p + rect.position, rect.size), color)
	draw_rect(Rect2(p + Vector2(15, 7), Vector2(2, 2)), INK)
	for i in range(5):
		draw_rect(Rect2(p + Vector2(2 + i * 6, 1), Vector2(4, 2)), color if i < base.hp else Color("3c423a"))
	if base.shield > 0 and int(base.shield * 12) % 2 == 0:
		draw_rect(Rect2(p - Vector2.ONE, Vector2(34, 34)), WHITE, false, 2)

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

func draw_hud() -> void:
	for team in range(2):
		if game.bases.size() <= team:
			continue
		var base: Dictionary = game.bases[team]
		var y := 62 + team * 66
		var color := RED if team == 0 else BLUE
		text_at("红方基地" if team == 0 else "蓝方基地", Vector2(464, y + 9), 12, color)
		text_at("%d / %d" % [base.hp, game.BASE_HP], Vector2(583, y + 9), 11, PAPER)
		for i in range(game.BASE_HP):
			var bar_step: float = 155.0 / game.BASE_HP
			draw_rect(Rect2(464 + i * bar_step, y + 20, bar_step - 4, 9), color if i < base.hp else Color("303c34"))
		text_at("无敌 %.1f 秒" % (ceilf(base.shield * 10) / 10) if base.shield > 0 else "", Vector2(464, y + 45), 10, GOLD)
	draw_rect(Rect2(464, 189, 152, 1), Color("3e4743"))
	text_at("玩家", Vector2(464, 208), 11, MUTED)
	text_at("击破/阵亡", Vector2(572, 208), 10, MUTED)
	var row := 0
	for id in game.players:
		var player: Dictionary = game.players[id]
		var y := 228 + row * 18
		var color := RED if player.team == 0 else BLUE
		text_at((">" if id == net.local_id else " ") + _fit_name(str(player.name), 102, 11), Vector2(464, y), 11, color)
		text_at("%d/%d" % [player.kills, player.deaths], Vector2(586, y), 10, PAPER)
		row += 1
	var me: Dictionary = game.players.get(net.local_id, {})
	if not me.is_empty() and float(me.get("respawn", -1.0)) >= 0:
		text_at("等待出生位置" if me.respawn <= 0.02 else "复活 %.1f 秒" % maxf(0, me.respawn), Vector2(464, 386), 12, GOLD)
	else:
		var tank: Dictionary = game.tank_for(net.local_id)
		text_at("无敌 %.1f 秒" % (ceilf(tank.shield * 10) / 10) if not tank.is_empty() and tank.shield > 0 else "无限复活", Vector2(464, 386), 10, GOLD if not tank.is_empty() and tank.shield > 0 else PAPER)
	text_at("WASD / 方向键 移动", Vector2(464, 450), 10, MUTED)
	text_at("空格 开火　M 音效", Vector2(464, 466), 10, MUTED)

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
