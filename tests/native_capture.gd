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
	root.size = Vector2i(1040, 780)
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
	await frames(5)
	var before: Vector2 = scene.game.tank_for(1).pos
	key(KEY_D, true)
	await frames(35)
	key(KEY_D, false)
	key(KEY_S, true)
	key(KEY_SPACE, true)
	await frames(72)
	check(scene.game.tank_for(1).pos.distance_to(before) > 10, "host keyboard input moved its own tank")
	check(scene.game.players.size() == 2 and scene.game.tanks.size() == 2, "both human tanks replicated in live match")
	await capture("tankbattle-online-battle")
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
	root.size = Vector2i(900, 600)
	await frames(5)
	await capture("tankbattle-online-resized")
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
		root.size = Vector2i(1040, 780)
		await frames(5)
		await capture("tankbattle-online-rematch")
	await finish()
