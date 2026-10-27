extends SceneTree
## Run on an existing desktop display, never under --headless.
## PNGs come directly from the live Godot viewport, not a recreation or mockup.
var scene: Node
var out_dir := ""
func _initialize() -> void:
	call_deferred("run")
func frames(count: int) -> void:
	for i in range(count):
		await physics_frame
func capture(name: String) -> void:
	await RenderingServer.frame_post_draw
	var result := root.get_texture().get_image().save_png(out_dir.path_join(name + ".png"))
	assert(result == OK)
	print("CAPTURE ", name, " ", root.size)
func key(code: int, pressed: bool) -> void:
	var e := InputEventKey.new()
	e.physical_keycode = code
	e.keycode = code
	e.pressed = pressed
	Input.parse_input_event(e)
func run() -> void:
	out_dir = OS.get_environment("TANK_CAPTURE_DIR")
	if out_dir.is_empty():
		push_error("Set TANK_CAPTURE_DIR to a writable output directory")
		quit(1)
		return
	DirAccess.make_dir_recursive_absolute(out_dir)
	scene = load("res://scenes/main.tscn").instantiate()
	root.add_child(scene)
	await frames(3)
	await capture("tankbattle-title")
	key(KEY_ENTER, true)
	await frames(1)
	key(KEY_ENTER, false)
	key(KEY_UP, true)
	key(KEY_SPACE, true)
	await frames(210)
	key(KEY_UP, false)
	await frames(150)
	key(KEY_SPACE, false)
	await capture("tankbattle-gameplay")
	key(KEY_P, true)
	await frames(1)
	key(KEY_P, false)
	assert(scene.game.state == "paused")
	var before: float = scene.game.elapsed
	await frames(60)
	assert(scene.game.elapsed == before)
	await capture("tankbattle-paused")
	root.size = Vector2i(900, 600)
	await frames(5)
	await capture("tankbattle-resized")
	key(KEY_R, true)
	await frames(1)
	key(KEY_R, false)
	assert(scene.game.lives == 3 and scene.game.killed == 0 and scene.game.spawned == 0)
	# Explicit checkpoint fixtures exercise otherwise long-to-reach result screens.
	scene.game.state = "won"
	scene.game.killed = 20
	scene.game.score = 5350
	await frames(2)
	await capture("tankbattle-win-fixture")
	scene.game.state = "lost"
	scene.game.base_alive = false
	await frames(2)
	await capture("tankbattle-defeat-fixture")
	print("NATIVE QA PASS: live input, fire, pause freeze, restart, resize, result layouts")
	quit(0)
