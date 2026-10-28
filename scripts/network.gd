class_name BattleNetwork
extends Node

## ENet room owner is peer 1. Only the host runs combat; clients send cardinal
## input, never player IDs, positions, health, teams, damage or projectiles.
signal changed
signal notice(message: String)
signal snapshot_received

const BattleModel = preload("res://scripts/battle.gd")
const DEFAULT_PORT := 7777
const MAX_PLAYERS := 8
const MAX_TEAM := 4
const PROTOCOL := 1
const SNAPSHOT_INTERVAL := 3 # 60 Hz / 3 = 20 snapshots / second.
const INPUT_TIMEOUT_MS := 300
const CONNECT_TIMEOUT_MS := 8000
var game = BattleModel.new()
var roster: Dictionary = {}
var mode := "offline"
var reason := ""
var local_id := 0
var port := DEFAULT_PORT
var epoch := 0
var enet: ENetMultiplayerPeer
var _name := "Player"
var _connect_started := 0
var _seq := 0
var _frame := 0
var _inputs: Dictionary = {}
var _last_input: Dictionary = {}
var _last_seq: Dictionary = {}
var _limits: Dictionary = {}
var _pending: Dictionary = {}
var _rejecting: Dictionary = {}
var _last_snapshot_tick := -1
var _last_state := ""
var rejected_packets := 0 # Diagnostic counter; never changes simulation.

func _ready() -> void:
	multiplayer.peer_connected.connect(_peer_connected)
	multiplayer.peer_disconnected.connect(_peer_disconnected)
	multiplayer.connected_to_server.connect(_connected)
	multiplayer.connection_failed.connect(_connection_failed)
	multiplayer.server_disconnected.connect(_server_lost)
	# Do not relay client RPCs to other clients. All accepted traffic terminates here.
	multiplayer.server_relay = false
	multiplayer.allow_object_decoding = false

func is_host() -> bool:
	return local_id == 1 and enet != null and mode != "offline"

func _valid_port(value: int) -> bool:
	return value >= 1024 and value <= 65535

func clean_name(value: String) -> String:
	var result := ""
	for character in value.strip_edges():
		var code := character.unicode_at(0)
		if code >= 32 and code != 127 and not (code >= 0x202a and code <= 0x202e) and not (code >= 0x2066 and code <= 0x2069):
			result += character
		if result.length() >= 16:
			break
	return result if not result.is_empty() else "Player"

func host_room(player_name: String, room_port: int = DEFAULT_PORT) -> Error:
	if not _valid_port(room_port):
		_message("Port must be between 1024 and 65535.")
		return ERR_INVALID_PARAMETER
	leave_room(false)
	enet = ENetMultiplayerPeer.new()
	# Allow a small transport-only margin so a ninth human gets an explicit rejection.
	var err := enet.create_server(room_port, 12, 3)
	if err != OK:
		enet = null
		_message("Cannot host UDP port %d (error %d). Is it already in use?" % [room_port, err])
		return err
	multiplayer.multiplayer_peer = enet
	local_id = 1
	port = room_port
	_name = clean_name(player_name)
	roster[1] = {"id": 1, "name": _name, "team": 0, "ready": true}
	mode = "lobby"
	reason = "Room open on UDP %d. Share your reachable IP with friends." % port
	changed.emit()
	return OK

func join_room(player_name: String, address: String, room_port: int = DEFAULT_PORT) -> Error:
	if not _valid_port(room_port) or address.strip_edges().is_empty() or address.length() > 253:
		_message("Enter a host IP/address and a port from 1024 to 65535.")
		return ERR_INVALID_PARAMETER
	leave_room(false)
	_name = clean_name(player_name)
	port = room_port
	enet = ENetMultiplayerPeer.new()
	var err := enet.create_client(address.strip_edges(), room_port, 3)
	if err != OK:
		enet = null
		_message("Cannot connect (error %d). Check host IP and UDP port." % err)
		return err
	multiplayer.multiplayer_peer = enet
	mode = "connecting"
	_connect_started = Time.get_ticks_msec()
	reason = "Connecting to %s:%d ..." % [address, port]
	changed.emit()
	return OK

func leave_room(show_message: bool = true) -> void:
	if is_host():
		_closed.rpc("Host closed the room. Create or join another room.")
	if enet != null:
		enet.close()
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	enet = null
	roster.clear()
	_inputs.clear()
	_last_input.clear()
	_last_seq.clear()
	_limits.clear()
	_pending.clear()
	_rejecting.clear()
	game = BattleModel.new()
	local_id = 0
	_seq = 0
	_frame = 0
	epoch = 0
	_last_snapshot_tick = -1
	mode = "offline"
	if show_message:
		reason = "Left the room."
	changed.emit()

func _message(message: String) -> void:
	reason = message
	notice.emit(message)
	changed.emit()

func _connected() -> void:
	if mode != "connecting":
		return
	local_id = multiplayer.get_unique_id()
	_register.rpc_id(1, [PROTOCOL, _name])

func _connection_failed() -> void:
	leave_room(false)
	_message("Connection failed. Check the IP, UDP port and host availability.")

func _server_lost() -> void:
	if mode == "offline":
		return
	leave_room(false)
	_message("Connection to the host was lost. Create or join another room.")

func _peer_connected(id: int) -> void:
	if not is_host():
		return
	_pending[id] = Time.get_ticks_msec()
	var packet_peer := enet.get_peer(id)
	if packet_peer != null:
		packet_peer.set_timeout(8, 3000, 8000)
	if mode != "lobby":
		_reject(id, "Match already started. Join after the host returns to the lobby.")
	elif roster.size() >= MAX_PLAYERS:
		_reject(id, "Room is full (8 players maximum).")

func _peer_disconnected(id: int) -> void:
	if not is_host():
		return
	_pending.erase(id)
	_rejecting.erase(id)
	_inputs.erase(id)
	_last_input.erase(id)
	_last_seq.erase(id)
	for key in _limits.keys():
		if str(key).begins_with("%d:" % id):
			_limits.erase(key)
	if not roster.has(id):
		return
	var departed: String = roster[id].name
	roster.erase(id)
	if mode in ["playing", "ended"]:
		game.remove_player(id)
		if mode == "playing":
			var counts := team_counts()
			if counts[0] == 0 or counts[1] == 0:
				game.state = "ended"
				game.winner = 1 if counts[0] == 0 else 0
				mode = "ended"
				reason = "%s disconnected; the other team wins." % departed
				_broadcast_room()
				_publish_snapshot(true)
				return
	reason = "%s left the room." % departed
	_broadcast_room()

func _reject(id: int, message: String) -> void:
	if _rejecting.has(id):
		return
	_rejecting[id] = true
	_rejected.rpc_id(id, message)
	# Let the reliable explanatory packet leave before dropping transport state.
	var this_enet := enet
	await get_tree().create_timer(0.35).timeout
	if enet == this_enet and enet != null and multiplayer.get_peers().has(id):
		enet.disconnect_peer(id)
	_pending.erase(id)
	_rejecting.erase(id)

func _allow(id: int, category: String, capacity: float, refill: float) -> bool:
	var key := "%d:%s" % [id, category]
	var now := Time.get_ticks_msec()
	var limit: Dictionary = _limits.get(key, {"tokens": capacity, "time": now})
	limit.tokens = minf(capacity, float(limit.tokens) + float(now - int(limit.time)) * refill / 1000.0)
	limit.time = now
	if float(limit.tokens) < 1.0:
		_limits[key] = limit
		rejected_packets += 1
		return false
	limit.tokens -= 1.0
	_limits[key] = limit
	return true

func team_counts() -> Array[int]:
	var counts: Array[int] = [0, 0]
	for p in roster.values():
		counts[p.team] += 1
	return counts

@rpc("any_peer", "call_remote", "reliable", 0)
func _register(packet: Variant) -> void:
	if not is_host():
		return
	var sender := multiplayer.get_remote_sender_id()
	if not _allow(sender, "register", 2, 0.2) or _rejecting.has(sender):
		return
	if typeof(packet) != TYPE_ARRAY or packet.size() != 2 or typeof(packet[0]) != TYPE_INT or typeof(packet[1]) != TYPE_STRING or packet[1].length() > 128:
		_reject(sender, "Invalid room handshake.")
		return
	if int(packet[0]) != PROTOCOL:
		_reject(sender, "Different game version. Use the same version as the host.")
		return
	if roster.has(sender):
		return
	if mode != "lobby":
		_reject(sender, "Match already started. Join again from the lobby.")
		return
	if roster.size() >= MAX_PLAYERS:
		_reject(sender, "Room is full (8 players maximum).")
		return
	var counts := team_counts()
	var team := 0 if counts[0] <= counts[1] else 1
	roster[sender] = {"id": sender, "name": clean_name(packet[1]), "team": team, "ready": false}
	_pending.erase(sender)
	reason = "%s joined. Choose a team and get ready." % roster[sender].name
	_broadcast_room()

func set_profile(player_name: String, team: int) -> void:
	if mode != "lobby" or not roster.has(local_id):
		return
	if is_host():
		_accept_profile(1, [player_name, team])
	else:
		_profile.rpc_id(1, [player_name, team])

@rpc("any_peer", "call_remote", "reliable", 0)
func _profile(packet: Variant) -> void:
	if not is_host():
		return
	var sender := multiplayer.get_remote_sender_id()
	if _allow(sender, "lobby", 8, 2):
		_accept_profile(sender, packet)

func _accept_profile(sender: int, packet: Variant) -> void:
	if mode != "lobby" or not roster.has(sender) or typeof(packet) != TYPE_ARRAY or packet.size() != 2:
		return
	if typeof(packet[0]) != TYPE_STRING or packet[0].length() > 128 or typeof(packet[1]) != TYPE_INT or packet[1] not in [0, 1]:
		rejected_packets += 1
		return
	var team: int = packet[1]
	if roster[sender].team != team and team_counts()[team] >= MAX_TEAM:
		if sender == 1: _message("That team is full (4 players maximum).")
		else: _feedback.rpc_id(sender, "That team is full (4 players maximum).")
		return
	roster[sender].name = clean_name(packet[0])
	roster[sender].team = team
	roster[sender].ready = sender == 1
	_broadcast_room()

func set_ready(ready_value: bool) -> void:
	if mode != "lobby" or not roster.has(local_id):
		return
	if is_host():
		roster[1].ready = true
		_broadcast_room()
	else:
		_ready_packet.rpc_id(1, ready_value)

@rpc("any_peer", "call_remote", "reliable", 0)
func _ready_packet(value: Variant) -> void:
	if not is_host():
		return
	var sender := multiplayer.get_remote_sender_id()
	if mode == "lobby" and roster.has(sender) and typeof(value) == TYPE_BOOL and _allow(sender, "lobby", 8, 2):
		roster[sender].ready = value
		_broadcast_room()

func can_start() -> String:
	if not is_host(): return "Only the host can start."
	if mode not in ["lobby", "ended"]: return "The match is already running."
	if roster.size() < 2 or roster.size() > MAX_PLAYERS: return "Need 2 to 8 human players."
	var counts := team_counts()
	if counts[0] == 0 or counts[1] == 0: return "Both teams need a player."
	if counts[0] > MAX_TEAM or counts[1] > MAX_TEAM: return "Maximum 4 players per team."
	if absi(counts[0] - counts[1]) > 1: return "Balance the teams (difference at most 1)."
	for p in roster.values():
		if not p.ready: return "Waiting for every player to be ready."
	return ""

func start_match() -> bool:
	var problem := can_start()
	if not problem.is_empty():
		_message(problem)
		return false
	epoch += 1
	_inputs.clear()
	_last_input.clear()
	_last_seq.clear()
	game.reset(roster)
	mode = "playing"
	_last_state = "playing"
	reason = "Destroy the enemy base. Respawns are unlimited."
	_broadcast_room()
	_publish_snapshot(true)
	return true

func return_to_lobby() -> void:
	if not is_host():
		return
	epoch += 1
	mode = "lobby"
	game = BattleModel.new()
	_inputs.clear()
	for id in roster:
		roster[id].ready = id == 1
	reason = "Back in the lobby. Choose teams and ready up for a rematch."
	_broadcast_room()

func submit_input(direction: int, firing: bool) -> void:
	if mode != "playing":
		return
	_seq += 1
	var packet := [epoch, _seq, direction, firing]
	if is_host():
		_accept_input(1, packet)
	else:
		_input_packet.rpc_id(1, packet)

@rpc("any_peer", "call_remote", "unreliable_ordered", 2)
func _input_packet(packet: Variant) -> void:
	if not is_host():
		return
	var sender := multiplayer.get_remote_sender_id()
	if _allow(sender, "input", 24, 75):
		_accept_input(sender, packet)

func _accept_input(sender: int, packet: Variant) -> void:
	if mode != "playing" or not roster.has(sender):
		return
	if typeof(packet) != TYPE_ARRAY or packet.size() != 4:
		rejected_packets += 1
		return
	if typeof(packet[0]) != TYPE_INT or typeof(packet[1]) != TYPE_INT or typeof(packet[2]) != TYPE_INT or typeof(packet[3]) != TYPE_BOOL:
		rejected_packets += 1
		return
	if packet[0] != epoch:
		rejected_packets += 1
		return
	var sequence: int = packet[1]
	var previous: int = _last_seq.get(sender, -1)
	if sequence <= previous or sequence < 0 or sequence > 2147483647 or (previous >= 0 and sequence > previous + 10000) or packet[2] < -1 or packet[2] > 3:
		rejected_packets += 1
		return
	_last_seq[sender] = sequence
	_inputs[sender] = {"dir": packet[2], "fire": packet[3]}
	_last_input[sender] = Time.get_ticks_msec()

func _physics_process(dt: float) -> void:
	if mode == "connecting" and Time.get_ticks_msec() - _connect_started > CONNECT_TIMEOUT_MS:
		leave_room(false)
		_message("Connection timed out. Check host IP / UDP port. Public internet needs reachable UDP; no automatic NAT traversal.")
		return
	if not is_host():
		return
	for id in _pending.keys():
		if Time.get_ticks_msec() - int(_pending[id]) > 5000:
			_reject(id, "Room handshake timed out.")
	if mode != "playing":
		return
	for id in _inputs:
		if Time.get_ticks_msec() - int(_last_input.get(id, 0)) > INPUT_TIMEOUT_MS:
			_inputs[id] = {"dir": -1, "fire": false}
	game.update(dt, _inputs)
	_frame += 1
	if game.state == "ended":
		mode = "ended"
		_broadcast_room()
		_publish_snapshot(true)
	elif _frame % SNAPSHOT_INTERVAL == 0:
		_publish_snapshot(false)

func _broadcast_room() -> void:
	var packet := {"roster": roster, "mode": mode, "epoch": epoch, "reason": reason}
	_room_state.rpc(packet)
	changed.emit()

func _publish_snapshot(reliable: bool) -> void:
	var packet := {"epoch": epoch, "state": var_to_bytes(game.snapshot()).compress(FileAccess.COMPRESSION_DEFLATE)}
	if reliable: _final_snapshot.rpc(packet)
	else: _snapshot.rpc(packet)
	snapshot_received.emit()

@rpc("authority", "call_remote", "reliable", 0)
func _room_state(packet: Dictionary) -> void:
	if is_host(): return
	roster = packet.roster
	if mode != packet.mode or epoch != int(packet.epoch):
		_last_snapshot_tick = -1
	epoch = packet.epoch
	mode = packet.mode
	reason = packet.reason
	if mode == "lobby":
		game = BattleModel.new()
		_last_snapshot_tick = -1
	changed.emit()

@rpc("authority", "call_remote", "unreliable_ordered", 1)
func _snapshot(packet: Dictionary) -> void:
	_receive_snapshot(packet)

@rpc("authority", "call_remote", "reliable", 0)
func _final_snapshot(packet: Dictionary) -> void:
	_receive_snapshot(packet)

func _receive_snapshot(packet: Dictionary) -> void:
	if is_host() or packet.get("epoch", -1) != epoch or mode not in ["playing", "ended"]:
		return
	if typeof(packet.get("state")) != TYPE_PACKED_BYTE_ARRAY or packet.state.size() > 65536:
		return
	var decoded: PackedByteArray = packet.state.decompress_dynamic(262144, FileAccess.COMPRESSION_DEFLATE)
	var value = bytes_to_var(decoded)
	if typeof(value) != TYPE_DICTIONARY:
		return
	var data: Dictionary = value
	var tick: int = data.get("tick", 0)
	if tick < _last_snapshot_tick:
		return
	_last_snapshot_tick = tick
	game.apply_snapshot(data)
	if game.state == "ended" and mode != "ended":
		mode = "ended"
		changed.emit()
	snapshot_received.emit()

@rpc("authority", "call_remote", "reliable", 0)
func _rejected(message: String) -> void:
	leave_room(false)
	_message(message)

@rpc("authority", "call_remote", "reliable", 0)
func _closed(message: String) -> void:
	leave_room(false)
	_message(message)

@rpc("authority", "call_remote", "reliable", 0)
func _feedback(message: String) -> void:
	_message(message)
