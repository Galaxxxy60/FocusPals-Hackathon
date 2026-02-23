extends Node3D

# ─── WebSocket ─────────────────────────────────────────────
var ws := WebSocketPeer.new()
var ws_connected := false
var reconnect_timer: float = 0.0

# ─── Tama State (miroir du Python agent) ───────────────────
var suspicion_index: float = 0.0
var prev_suspicion: float = 0.0
var state: String = "CALM"
var alignment: float = 1.0
var current_task: String = "..."
var active_window: String = "Loading..."
var active_duration: int = 0

# ─── Session ───────────────────────────────────────────────
var session_active: bool = false
var just_connected: bool = false

# ─── Animation State Machine ──────────────────────────────
# Noms des animations dans le .glb (à ajuster si les noms sont différents)
const ANIM_WAVE       := "wave"         # Bonjour 👋
const ANIM_PEEK       := "peek"         # Rentre dans l'écran pour voir 👀
const ANIM_SUSPICIOUS := "suspicious"   # Regard interrogatif 🤔
const ANIM_ANGRY      := "angry"        # Pas contente 😡
const ANIM_LEAVE      := "leave"        # S'en va de l'écran 👋
const ANIM_IDLE_BREAK := "idle_break"   # Chill pendant les pauses 😌

var current_anim: String = ""
var anim_player_ref: AnimationPlayer = null

# ─── Slide animation ──────────────────────────────────────
var target_y: float = -6.0
var slide_speed: float = 3.0

func _ready() -> void:
	_position_window()
	_connect_ws()
	
	# Cherche l'AnimationPlayer une seule fois au démarrage
	var tama = get_node_or_null("Tama")
	if tama:
		anim_player_ref = _find_animation_player(tama)
		if anim_player_ref:
			var anims = anim_player_ref.get_animation_list()
			print("🎬 Animations trouvées: ", anims)
		else:
			print("⚠️ Pas d'AnimationPlayer trouvé dans Tama")
	
	print("🥷 FocusPals Godot — En attente de connexion...")

func _position_window() -> void:
	var screen_size := DisplayServer.screen_get_size()
	var win_size := DisplayServer.window_get_size()
	var x := screen_size.x - win_size.x - 20
	var y := screen_size.y - win_size.y - 60
	DisplayServer.window_set_position(Vector2i(x, y))
	get_viewport().transparent_bg = true

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
				just_connected = true
				session_active = true
				ws.send_text(JSON.stringify({"command": "START_SESSION"}))
				print("✅ WebSocket connecté!")

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

	# ── Animation + Position ──
	_update_tama_state(delta)

func _handle_message(raw: String) -> void:
	var data = JSON.parse_string(raw)
	if data == null:
		return

	prev_suspicion = suspicion_index
	suspicion_index = data.get("suspicion_index", 0.0)
	state = data.get("state", "CALM")
	alignment = data.get("alignment", 1.0)
	current_task = data.get("current_task", "...")
	active_window = data.get("active_window", "Unknown")
	active_duration = data.get("active_duration", 0)

# ─── STATE MACHINE: Animation + Position ──────────────────

func _update_tama_state(delta: float) -> void:
	var desired_anim := ""
	
	if not session_active:
		# Pas encore connecté → cachée
		target_y = -6.0
		desired_anim = ANIM_IDLE_BREAK
	
	elif just_connected:
		# Vient de se connecter → dit bonjour
		target_y = -1.0
		desired_anim = ANIM_WAVE
		# Après l'anim de bonjour, on passe en mode normal
		if anim_player_ref and not anim_player_ref.is_playing():
			just_connected = false
	
	elif suspicion_index >= 7.0:
		# ═══ ANGRY ═══ Tama est furieuse, totalement visible
		target_y = -1.0
		desired_anim = ANIM_ANGRY
	
	elif suspicion_index >= 5.0:
		# ═══ SUSPICIOUS ═══ Tama regarde avec un air interrogatif
		target_y = -1.0
		desired_anim = ANIM_SUSPICIOUS
	
	elif suspicion_index >= 3.0:
		# ═══ PEEK ═══ Tama entre dans l'écran, curieuse
		target_y = -2.5
		desired_anim = ANIM_PEEK
	
	elif suspicion_index <= 1.0 and prev_suspicion > 3.0:
		# ═══ LEAVE ═══ La suspicion est retombée, Tama s'en va
		target_y = -6.0
		desired_anim = ANIM_LEAVE
	
	elif suspicion_index <= 1.0:
		# ═══ CALM ═══ Tout va bien, Tama est cachée
		target_y = -6.0
		desired_anim = ANIM_IDLE_BREAK
	
	else:
		# Zone intermédiaire (S: 1-3)
		target_y = -4.0
		desired_anim = ANIM_PEEK
	
	# ── Applique l'animation ──
	_play_anim(desired_anim)
	
	# ── Slide smooth ──
	var tama = get_node_or_null("Tama")
	if tama:
		tama.position.y = lerpf(tama.position.y, target_y, delta * slide_speed)

func _play_anim(anim_name: String) -> void:
	if anim_player_ref == null:
		return
	
	if current_anim == anim_name:
		return
	
	if anim_player_ref.has_animation(anim_name):
		# 0.3 = durée du fondu enchaîné entre les 2 anims (en secondes)
		anim_player_ref.play(anim_name, 0.3)
		current_anim = anim_name
		print("🎬 Animation: ", anim_name)
	else:
		var anims = anim_player_ref.get_animation_list()
		if anims.size() > 0 and not anim_player_ref.is_playing():
			anim_player_ref.play(anims[0], 0.3)

# ─── Utilitaires ──────────────────────────────────────────

func _find_animation_player(node: Node) -> AnimationPlayer:
	for child in node.get_children():
		if child is AnimationPlayer:
			return child
		var found := _find_animation_player(child)
		if found:
			return found
	return null
