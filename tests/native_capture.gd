extends SceneTree
## Native 2-process ENet QA. Screenshots are taken from the running Godot viewport,
## not from mock data. Run on the existing desktop display, never a new X server.
var scene: Node
var out_dir := ""
var peer_pid := -1
var port := 17779
var failed := false

func _initialize() -> void:
	call_deferred("run")

func frames(count: int) -> void:
	for _i in range(count):
		await physics_frame

func wait_until(predicate: Callable, timeout: float = 10.0) -> bool:
	var started := Time.get_ticks_msec()
	while Time.get_ticks_msec() - started < timeout * 1000:
		if predicate.call():
			return true
		await physics_frame
	return false

func check(condition: bool, label: String) -> bool:
	if condition:
		print("NATIVE PASS: ", label)
	else:
		failed = true
		push_error("NATIVE FAIL: " + label)
	return condition

func capture(name: String) -> void:
	await RenderingServer.frame_post_draw
	var result := root.get_texture().get_image().save_png(out_dir.path_join(name + ".png"))
	check(result == OK, "viewport capture " + name)
	print("CAPTURE ", name, " ", root.size)

func key(code: int, pressed: bool) -> void:
	var event := InputEventKey.new()
	event.physical_keycode = code
	event.keycode = code
	event.pressed = pressed
	Input.parse_input_event(event)
	# Physics catch-up may deliver multiple physics_frame signals before one idle
	# input flush. Dispatch test events before asserting GUI state.
	Input.flush_buffered_events()

func tap(code: int) -> void:
	key(code, true)
	await frames(2)
	key(code, false)

func finish() -> void:
	if scene != null:
		scene.net.leave_room()
	if peer_pid > 0:
		var ended := await wait_until(func(): return not OS.is_process_running(peer_pid), 5.0)
		check(ended, "separate client exits after host closes")
		if not ended:
			OS.kill(peer_pid)
	print("NATIVE_MULTIPLAYER_QA: ", "FAIL" if failed else "PASS", " (real host + separate ENet client)")
	quit(1 if failed else 0)

func run() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("Native capture needs the existing desktop display; do not run headless.")
		quit(1)
		return
	out_dir = OS.get_environment("TANK_CAPTURE_DIR")
	if not check(not out_dir.is_empty(), "capture output directory configured"):
		quit(1)
		return
	if not OS.get_environment("TANK_NATIVE_PORT").is_empty():
		port = int(OS.get_environment("TANK_NATIVE_PORT"))
	DirAccess.make_dir_recursive_absolute(out_dir)
	root.size = Vector2i(1280, 720)
	scene = load("res://scenes/main.tscn").instantiate()
	root.add_child(scene)
	await frames(5)
	await capture("tankbattle-online-entry")
	if not check(scene.net.host_room("红队房主", port) == OK, "host opened real ENet room"):
		await finish()
		return
	peer_pid = OS.create_process(OS.get_executable_path(), ["--headless", "--path", ProjectSettings.globalize_path("res://"), "--script", "res://tests/native_peer.gd", "--", "--port=%d" % port])
	if not check(peer_pid > 0, "separate native client process launched"):
		await finish()
		return
	var ready := await wait_until(func(): return scene.net.roster.size() == 2 and scene.net.can_start().is_empty())
	if not check(ready, "two real peers joined, balanced teams, client ready"):
		await finish()
		return
	await frames(6)
	await capture("tankbattle-online-lobby")
	if not check(scene.net.start_match(), "host started two-player online match"):
		await finish()
		return
	await frames(3)
	check(scene.viewport_size == Vector2(root.size), "native canvas matches wide window without letterboxing")
	check(is_equal_approx(scene.field_scale, minf(float(root.size.x) / scene.game.WIDTH, float(root.size.y) / scene.game.HEIGHT)), "uniform world fit preserves full authoritative arena")
	check(scene.invulnerability_alpha(2.0, 0.0) == 1.0 and scene.invulnerability_alpha(2.0, 0.2) == 0.28, "invulnerability blinks tank pixels at 3 Hz")
	check(scene.invulnerability_alpha(0.0, 0.2) == 1.0, "non-invulnerable tanks never blink")
	await capture("tankbattle-fullfield-blink-bright")
	await wait_until(func(): return scene.invulnerability_alpha(scene.game.tank_for(1).shield, scene.game.elapsed) < 1.0, 1.0)
	await capture("tankbattle-fullfield-blink-dim")
	var before: Vector2 = scene.game.tank_for(1).pos
	key(KEY_D, true)
	await frames(35)
	key(KEY_D, false)
	key(KEY_S, true)
	key(KEY_SPACE, true)
	await frames(72)
	check(scene.game.tank_for(1).pos.distance_to(before) > 10, "host keyboard input moved its own tank")
	check(scene.game.players.size() == 2 and scene.game.tanks.size() == 2, "both human tanks replicated in live match")
	await capture("tankbattle-fullfield-wide")
	# Explicit host-only visual fixture invokes the real damage/protection path.
	# No fabricated shield/HP fields; the next screenshots show the live timer.
	check(scene.game.damage_base(0), "base damage fixture uses real authoritative protection")
	await frames(24)
	await wait_until(func(): return scene.invulnerability_alpha(scene.game.bases[0].shield, scene.game.elapsed) == 1.0, 1.0)
	await capture("tankbattle-fullfield-base-bright")
	await wait_until(func(): return scene.invulnerability_alpha(scene.game.bases[0].shield, scene.game.elapsed) < 1.0, 1.0)
	await capture("tankbattle-fullfield-base-dim")
	check(scene.game.bases[0].hp == 4 and scene.game.bases[0].shield > 0, "base HP persists during symbol-only protection blink")
	await tap(KEY_ESCAPE)
	check(scene.local_menu and scene.game.state == "playing", "Escape opens only a local menu")
	var tick_before: int = scene.game.tick
	var pos_before: Vector2 = scene.game.tank_for(1).pos
	await frames(45)
	check(scene.game.tick > tick_before + 20, "host simulation continues behind local menu")
	check(scene.game.tank_for(1).pos == pos_before, "menu suppresses held movement and fire input")
	await capture("tankbattle-online-local-menu")
	key(KEY_S, false)
	key(KEY_SPACE, false)
	scene._confirm("leave")
	await frames(3)
	check(scene.confirm_dialog.visible, "leave requires confirmation")
	scene.confirm_dialog.get_cancel_button().pressed.emit()
	await frames(3)
	check(not scene.confirm_dialog.visible and scene.net.mode == "playing", "cancel leave keeps room and match intact")
	await tap(KEY_ESCAPE)
	for window_size in [Vector2i(800, 800), Vector2i(640, 900), Vector2i(1280, 720)]:
		root.size = window_size
		await frames(5)
		check(scene.viewport_size == Vector2(window_size), "viewport fills resized %s" % window_size)
		check(scene.menu_button.get_global_rect().end.x <= window_size.x and scene.menu_button.get_global_rect().end.y <= window_size.y, "HUD menu remains inside resized viewport")
		check(scene.field_origin.x >= 0 and scene.field_origin.y >= 0, "complete shared arena visible at every aspect")
		await capture("tankbattle-fullfield-%dx%d" % [window_size.x, window_size.y])
		# Native mouse events hit the actual HUD button after each resize.
		var pointer := InputEventMouseMotion.new()
		pointer.position = scene.menu_button.get_global_rect().get_center()
		pointer.global_position = pointer.position
		Input.parse_input_event(pointer)
		await frames(2)
		check(root.gui_get_hovered_control() == scene.menu_button, "resized pointer hits only the HUD menu")
		key(KEY_SPACE, true)
		await frames(2)
		var mouse := InputEventMouseButton.new()
		mouse.position = pointer.position
		mouse.global_position = mouse.position
		mouse.button_index = MOUSE_BUTTON_LEFT
		mouse.pressed = true
		mouse.button_mask = MOUSE_BUTTON_MASK_LEFT
		Input.parse_input_event(mouse)
		Input.flush_buffered_events()
		await process_frame
		mouse = mouse.duplicate()
		mouse.pressed = false
		mouse.button_mask = 0
		Input.parse_input_event(mouse)
		Input.flush_buffered_events()
		await process_frame
		await process_frame
		check(scene.local_menu, "resized HUD mouse click opens menu")
		await frames(2)
		check(not scene.net._inputs.get(1, {}).get("fire", false), "HUD menu suppresses even held fire input")
		key(KEY_SPACE, false)
		await tap(KEY_ESCAPE)
		check(not scene.local_menu, "Escape returns from menu repeatedly")
	await tap(KEY_ESCAPE)
	scene._confirm("room")
	await frames(2)
	scene.confirm_dialog.get_ok_button().pressed.emit()
	await frames(4)
	check(scene.net.mode == "lobby", "host confirmed return-to-room without disconnecting peers")
	var rematch_ready := await wait_until(func(): return scene.net.roster.size() == 2 and scene.net.can_start().is_empty(), 5)
	check(rematch_ready, "client readies again in preserved room")
	if rematch_ready:
		check(scene.net.start_match(), "host starts rematch")
		await frames(8)
		check(scene.game.bases[0].hp == 5 and scene.game.bases[1].hp == 5 and scene.game.players[1].deaths == 0, "rematch resets bases and scores")
		root.size = Vector2i(1280, 720)
		await frames(5)
		await capture("tankbattle-online-rematch")
	await finish()
