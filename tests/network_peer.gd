extends SceneTree
## Real-process ENet integration harness. All automated input is test-only;
## production contains no AI. Host fixtures position targets to exercise replication.
const Network = preload("res://scripts/network.gd")
var net
var role := "client"
var address := "127.0.0.1"
var room_port := 17777
var expected := 2
var index := 1
var out_dir := "/tmp/tank-net"
var checks := 0
var failures := 0
var started := 0
var lobby_at := 0
var match_at := 0
var end_at := 0
var phase := 0
var last_epoch := -1
var lobby_ready_epoch := -1
var sent_attack := false
var initial_positions := {}
var saw_death := false
var saw_respawn := false
var saw_base_hit := false
var saw_base_shield := false
var saw_bullet := false
var saw_wing_position := false
var saw_terrain_change := false
var terrain_count := 0
var snapshot_count := 0
var max_wire_bytes := 0
var seen_epochs := {}
var completed := false
var opponent_id := 0
var rematch_positions := {}
var rejected_at_rematch := 0
var once := {}

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		var pair := arg.split("=", true, 1)
		if pair.size() != 2: continue
		match pair[0]:
			"role": role = pair[1]
			"address": address = pair[1]
			"port": room_port = int(pair[1])
			"expected": expected = int(pair[1])
			"index": index = int(pair[1])
			"out": out_dir = pair[1]
	call_deferred("_setup")

func _setup() -> void:
	started = Time.get_ticks_msec()
	net = Network.new()
	net.name = "Network"
	root.add_child(net)
	net.snapshot_received.connect(_snapshot)
	physics_frame.connect(_step)
	var err: int
	if role == "host":
		err = net.host_room("P0", room_port)
		check(err == OK, "host UDP socket created")
		check(not net.can_start().is_empty(), "single-player start rejected")
	else:
		err = net.join_room("P%d" % index, address, room_port)
		check(err == OK, "client UDP connection created")
	if err != OK:
		finish()

func check(condition: bool, description: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		print("FAIL: ", description)
	else:
		print("PASS: ", description)

func stage(value: String) -> void:
	print("PHASE ", value)
	var file := FileAccess.open(out_dir.path_join("stage.txt"), FileAccess.WRITE)
	if file: file.store_string(value)

func finish() -> void:
	if completed: return
	completed = true
	print("NETWORK_PEER_RESULT role=%s index=%d checks=%d failures=%d snapshots=%d max_compressed_state_bytes=%d" % [role, index, checks, failures, snapshot_count, max_wire_bytes])
	quit(1 if failures else 0)

func _snapshot() -> void:
	if net.mode not in ["playing", "ended"]: return
	snapshot_count += 1
	var data: Dictionary = net.game.snapshot()
	var encoded := var_to_bytes(data)
	max_wire_bytes = maxi(max_wire_bytes, encoded.compress(FileAccess.COMPRESSION_DEFLATE).size())
	var digest := encoded.hex_encode().sha256_text()
	print("SNAP %d %d %s" % [net.epoch, net.game.tick, digest])
	seen_epochs[net.epoch] = true
	if terrain_count == 0:
		terrain_count = net.game.terrain.size()
		check(data.terrain.size() == net.game.TERRAIN_COLUMNS * net.game.TERRAIN_ROWS, "snapshot has complete rectangular terrain dimensions")
		check(net.game.bases[0].pos.x == 352 and net.game.bases[1].pos.x == 352, "replicated bases use shared wide-world coordinates")
	if net.game.terrain.size() < terrain_count: saw_terrain_change = true
	if net.game.bullets.size() > 0: saw_bullet = true
	for tank in net.game.tanks:
		if tank.pos.x > net.game.WIDTH - 32:
			saw_wing_position = true
	if net.game.bases[0].hp < 5: saw_base_hit = true
	if net.game.bases[0].shield > 0: saw_base_shield = true
	for player in net.game.players.values():
		if player.name == _shooter_name():
			if player.deaths > 0 and player.respawn > 0: saw_death = true
			var tank: Dictionary = net.game.tank_for(player.id)
			if player.deaths > 0 and not tank.is_empty() and tank.shield > 0: saw_respawn = true

func _step() -> void:
	if completed or net == null: return
	if Time.get_ticks_msec() - started > 27000:
		check(false, "integration process timed out: %s %s" % [net.mode, net.reason])
		finish()
		return
	if role.begins_with("reject"):
		if net.mode == "offline" and not net.reason.is_empty():
			check("full" in net.reason if role == "reject_full" else "already started" in net.reason, "explicit rejection: " + net.reason)
			finish()
		return
	if role == "host": _host_step()
	else: _client_step()

func _shooter_name() -> String:
	var names: Array[String] = []
	for player in net.roster.values():
		if player.team == 1: names.append(player.name)
	names.sort()
	return names[0] if not names.is_empty() else ""

func _is_shooter() -> bool:
	return net.roster.has(net.local_id) and net.roster[net.local_id].name == _shooter_name()

func _all_ready() -> bool:
	if net.roster.size() != expected: return false
	for player in net.roster.values():
		if not player.ready: return false
	return true

func _host_step() -> void:
	if phase == 0 and _all_ready():
		phase = 1
		lobby_at = Time.get_ticks_msec()
		check(net.team_counts() == [ceili(expected / 2.0), floori(expected / 2.0)], "balanced teams and all players ready")
		if expected == 8:
			var counts_before: Array = net.team_counts()
			var blue_id := 0
			for id in net.roster:
				if net.roster[id].team == 1: blue_id = id; break
			net._accept_profile(blue_id, [net.roster[blue_id].name, 0])
			check(net.team_counts() == counts_before, "team limit rejects fifth player")
		stage("full_lobby")
	if phase == 1 and Time.get_ticks_msec() - lobby_at >= 1800:
		check(net.start_match(), "host starts ready room")
		phase = 2
		for tank in net.game.tanks: initial_positions[tank.id] = tank.pos
		for id in net.roster:
			if net.roster[id].name == _shooter_name(): opponent_id = id
		stage("playing")
	if phase == 2:
		net.submit_input(-1, false)
		var tick: int = net.game.tick
		if tick >= 100 and not once.has("ownership"):
			once.ownership = true
			check(net.game.tank_for(1).pos == initial_positions[1], "client input cannot move host tank")
			check(net.game.tank_for(opponent_id).pos != initial_positions[opponent_id], "real client movement replicated to host")
		if tick >= 150 and not once.has("malformed"):
			once.malformed = true
			check(net.rejected_packets > 0, "malformed and spam input rejected")
			check(net.game.tank_for(1).pos == initial_positions[1], "spoofed ID/direction did not move host")
		if tick >= 155 and not once.has("flight"):
			once.flight = true
			# Test-only fixture gives a long clear firing lane independent of random peer-ID spawn ordering.
			var flying_tank: Dictionary = net.game.tank_for(opponent_id)
			flying_tank.pos = Vector2(net.game.WIDTH / 2, net.game.HEIGHT / 2)
			flying_tank.dir = 0
		if tick >= 180 and not once.has("target"):
			once.target = true
			# Test-only fixture: the selected blue human shoots the red base through its brick cover.
			var tank: Dictionary = net.game.tank_for(opponent_id)
			tank.pos = Vector2(net.game.WIDTH / 2, 80)
			tank.shield_until = 0
			tank.dir = 0
		if tick >= 300 and not once.has("kill"):
			once.kill = true
			check(net.game.bases[0].hp < 5, "real client fire damages enemy base")
			check(net.game.terrain.size() < terrain_count, "real client fire destroys brick cover")
			check(net.game.damage_tank(net.game.tank_for(opponent_id), 1), "host fixture records a death")
		if tick >= 425 and not once.has("respawn"):
			once.respawn = true
			check(not net.game.tank_for(opponent_id).is_empty(), "player respawned after two seconds")
			check(net.game.tank_for(opponent_id).shield > 0, "respawn invulnerability active")
			check(net.game.players[opponent_id].deaths == 1 and net.game.players[1].kills == 1, "authoritative scores recorded")
		if tick >= 430 and not once.has("wing"):
			once.wing = true
			# A separate long-lived firing observation in the new outer corridor
			# checks coordinates beyond the old square and lets slow-starting peers
			# observe bullets after the short base-cover impact sequence.
			var wing_tank: Dictionary = net.game.tank_for(opponent_id)
			wing_tank.pos = Vector2(net.game.WIDTH - 16, net.game.HEIGHT - 96)
			wing_tank.dir = 0
		if tick >= 510:
			# Test-only fixture: finish after all replication observations; production victory path is unchanged.
			net.game.bases[0].hp = 1
			net.game.bases[0].shield_until = 0
			net.game.damage_base(0)
			phase = 3
	if phase == 3 and net.mode == "ended":
		check(net.game.winner == 1, "base destruction ends match with correct winner")
		end_at = Time.get_ticks_msec()
		phase = 4
	if phase == 4 and Time.get_ticks_msec() - end_at > 700:
		check(saw_wing_position, "client-authorized movement and shots replicate in far playable wing")
		check(saw_bullet and saw_base_hit and saw_base_shield and saw_death and saw_respawn and saw_terrain_change, "host saw fields: bullet=%s base=%s shield=%s death=%s respawn=%s terrain=%s" % [saw_bullet, saw_base_hit, saw_base_shield, saw_death, saw_respawn, saw_terrain_change])
		net.return_to_lobby()
		phase = 5
		stage("rematch")
	if phase == 5 and _all_ready():
		check(net.start_match(), "rematch starts with same connected humans")
		check(net.game.bases[0].hp == 5 and net.game.players[opponent_id].deaths == 0, "rematch resets health and scores")
		for tank in net.game.tanks: rematch_positions[tank.id] = tank.pos
		rejected_at_rematch = net.rejected_packets
		phase = 6
	if phase == 6:
		net.submit_input(-1, false)
		if net.game.tick >= 100 and not once.has("stale_epoch"):
			once.stale_epoch = true
			check(net.rejected_packets > rejected_at_rematch, "stale previous-match input rejected")
			var all_stationary := true
			for tank in net.game.tanks:
				if tank.pos != rematch_positions[tank.id]: all_stationary = false
			check(all_stationary, "stale epoch cannot move any rematch tank")
		if expected == 8 and net.game.tick >= 120 and net.roster.size() == expected - 1:
			var has_departed := false
			for p in net.game.players.values():
				if p.name == "P7": has_departed = true
			check(not has_departed, "disconnect removes player from authoritative model")
			phase = 7
		elif expected != 8 and net.game.tick >= 120:
			phase = 7
	if phase == 7:
		check(seen_epochs.size() == 2, "both match epochs produced snapshots")
		stage("host_closing")
		net.leave_room()
		phase = 8
		end_at = Time.get_ticks_msec()
	if phase == 8 and Time.get_ticks_msec() - end_at > 600: finish()

func _client_step() -> void:
	if net.mode == "lobby" and net.roster.has(net.local_id):
		if lobby_ready_epoch != net.epoch:
			lobby_ready_epoch = net.epoch
			check(not net.is_host(), "client is not authority")
			check(not net.start_match(), "client cannot start room")
			net.set_ready(true)
	if net.mode == "playing":
		var tick: int = net.game.tick
		var first_match: bool = net.epoch == 1
		var direction := 1 if _is_shooter() and first_match and tick < 45 else -1
		var firing := _is_shooter() and first_match and ((tick >= 20 and tick < 40) or (tick >= 160 and tick < 175) or (tick >= 180 and tick < 300) or (tick >= 440 and tick < 500))
		if firing and tick >= 160: direction = 0
		net.submit_input(direction, firing)
		if _is_shooter() and first_match and tick >= 90 and not sent_attack:
			sent_attack = true
			net._input_packet.rpc_id(1, {"id": 1, "dir": 3, "fire": true, "team": 1})
			net._input_packet.rpc_id(1, [net.epoch, net._seq + 1, 99, true])
			net._input_packet.rpc_id(1, [net.epoch, net._seq + 1, 0, "yes"])
			for i in range(200): net._input_packet.rpc_id(1, [net.epoch, -1, 3, true])
		if _is_shooter() and not first_match and tick >= 20 and tick < 50:
			once.stale_epoch = true
			net._input_packet.rpc_id(1, [1, net._seq + 1, 3, true])
		if expected == 8 and index == 7 and not first_match and tick >= 120:
			check(seen_epochs.size() == 2, "disconnecting client received both matches")
			net.leave_room()
			finish()
			return
	if net.mode == "offline" and seen_epochs.size() > 0:
		check("host" in net.reason.to_lower(), "host loss returns to entry with clear reason: " + net.reason)
		check(seen_epochs.size() == 2, "client received rematch epoch")
		check(snapshot_count > 30, "client received continuous authoritative snapshots")
		check(saw_wing_position, "client-authorized movement and shots replicate in far playable wing")
		check(saw_bullet and saw_base_hit and saw_base_shield and saw_death and saw_respawn and saw_terrain_change, "client saw fields: bullet=%s base=%s shield=%s death=%s respawn=%s terrain=%s" % [saw_bullet, saw_base_hit, saw_base_shield, saw_death, saw_respawn, saw_terrain_change])
		finish()
