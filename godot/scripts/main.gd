extends Node3D

# ─── WebSocket ─────────────────────────────────────────────
var ws := WebSocketPeer.new()
var ws_connected := false
var reconnect_timer: float = 0.0

# ─── Tama State (miroir du Python agent) ───────────────────
var suspicion_index: float = 0.0
var state: String = "CALM"
var alignment: float = 1.0
var current_task: String = "..."
var active_window: String = "Loading..."
var active_duration: int = 0

# ─── Session ───────────────────────────────────────────────
var session_active: bool = false

# ─── Slide animation ──────────────────────────────────────
var target_y: float = -1.0
var slide_speed: float = 3.0

func _ready() -> void:
	# Position la fenêtre en bas à droite de l'écran
	_position_window()
	# Connecte au WebSocket du Python agent
	_connect_ws()
	print("🥷 FocusPals Godot — En attente de connexion...")

func _position_window() -> void:
	var screen_size := DisplayServer.screen_get_size()
	var win_size := DisplayServer.window_get_size()
	var x := screen_size.x - win_size.x - 20
	var y := screen_size.y - win_size.y - 60
	DisplayServer.window_set_position(Vector2i(x, y))
	get_viewport().transparent_bg = true
	# Click-through géré par click_through.py (Windows API externe)


func _connect_ws() -> void:
	var err := ws.connect_to_url("ws://localhost:8080")
	if err != OK:
		print("❌ WebSocket: impossible de se connecter")
	else:
		print("🔌 Connexion à ws://localhost:8080...")

func _process(delta: float) -> void:
	# ── WebSocket ──
	ws.poll()

	match ws.get_ready_state():
		WebSocketPeer.STATE_OPEN:
			if not ws_connected:
				ws_connected = true
				print("✅ WebSocket connecté au Python agent!")
				# Démarre la session automatiquement
				session_active = true
				ws.send_text(JSON.stringify({"command": "START_SESSION"}))

			while ws.get_available_packet_count() > 0:
				var packet := ws.get_packet().get_string_from_utf8()
				_handle_message(packet)

		WebSocketPeer.STATE_CLOSED:
			if ws_connected:
				ws_connected = false
				print("🔌 Déconnecté. Reconnexion dans 2s...")
			reconnect_timer += delta
			if reconnect_timer >= 2.0:
				reconnect_timer = 0.0
				_connect_ws()

	# ── Slide Tama selon la suspicion ──
	_update_slide(delta)

	# ── Vitesse d'animation ──
	_update_anim_speed()

func _handle_message(raw: String) -> void:
	var data = JSON.parse_string(raw)
	if data == null:
		return

	suspicion_index = data.get("suspicion_index", 0.0)
	state = data.get("state", "CALM")
	alignment = data.get("alignment", 1.0)
	current_task = data.get("current_task", "...")
	active_window = data.get("active_window", "Unknown")
	active_duration = data.get("active_duration", 0)

func _update_slide(delta: float) -> void:
	# Tama monte/descend selon le niveau de suspicion
	if not session_active:
		target_y = -1.0  # Visible au lobby
	elif suspicion_index >= 6.0:
		target_y = -1.0  # Furieux: visible
	elif suspicion_index >= 3.0:
		target_y = -3.0  # Suspect: à moitié caché
	else:
		target_y = -6.0  # Calme: caché en bas

	var tama = get_node_or_null("Tama")
	if tama:
		tama.position.y = lerpf(tama.position.y, target_y, delta * slide_speed)

func _update_anim_speed() -> void:
	# Cherche un AnimationPlayer dans Tama (s'il existe)
	var tama = get_node_or_null("Tama")
	if tama == null:
		return

	var anim_player: AnimationPlayer = _find_animation_player(tama)
	if anim_player == null:
		return

	# Joue la première animation si rien ne joue
	if not anim_player.is_playing():
		var anims := anim_player.get_animation_list()
		if anims.size() > 0:
			anim_player.play(anims[0])

	# Module la vitesse selon la suspicion
	if suspicion_index >= 9.0:
		anim_player.speed_scale = 4.0
	elif suspicion_index >= 6.0:
		anim_player.speed_scale = 2.0
	elif suspicion_index >= 3.0:
		anim_player.speed_scale = 1.5
	else:
		anim_player.speed_scale = 1.0

func _find_animation_player(node: Node) -> AnimationPlayer:
	# Cherche récursivement un AnimationPlayer dans les enfants
	for child in node.get_children():
		if child is AnimationPlayer:
			return child
		var found := _find_animation_player(child)
		if found:
			return found
	return null
