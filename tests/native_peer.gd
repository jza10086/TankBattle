extends SceneTree
## A separate real ENet client for native QA. This sends a prerecorded human-input
## sequence; it is not a game AI and is never loaded by the normal game scene.
var scene: Node
var port := 17779
var started := 0
var phase_started := 0
var previous_epoch := -1
var saw_match := false
var closing := false

func _initialize() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--port="):
			port = int(argument.trim_prefix("--port="))
	call_deferred("run")

func run() -> void:
	scene = load("res://scenes/main.tscn").instantiate()
	root.add_child(scene)
	# The capture client has no physical keyboard. Its input script is below.
	scene.set_physics_process(false)
	started = Time.get_ticks_msec()
	var error: int = scene.net.join_room("蓝队玩家", "127.0.0.1", port)
	if error != OK:
		push_error("NATIVE PEER: join failed %d" % error)
		quit(1)
		return
	while Time.get_ticks_msec() - started < 45000:
		await physics_frame
		if scene.net.mode == "lobby":
			if scene.net.roster.has(scene.net.local_id) and not scene.net.roster[scene.net.local_id].ready:
				scene.net.set_ready(true)
		elif scene.net.mode == "playing":
			if previous_epoch != scene.net.epoch:
				previous_epoch = scene.net.epoch
				phase_started = Time.get_ticks_msec()
				saw_match = true
			var elapsed := (Time.get_ticks_msec() - phase_started) / 1000.0
			# Up + fire for the opening, then hold position and continue firing.
			scene.net.submit_input(0 if elapsed < 1.4 else -1, elapsed < 5.0)
		elif scene.net.mode == "offline":
			print("NATIVE PEER EXIT: ", scene.net.reason, " saw_match=", saw_match)
			quit(0 if saw_match else 1)
			return
	scene.net.leave_room()
	push_error("NATIVE PEER: capture session timed out")
	quit(1)
