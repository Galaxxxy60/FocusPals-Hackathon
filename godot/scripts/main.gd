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
# Les vrais noms de TES animations !
const ANIM_HELLO      := "Hello"        # Bonjour (loop)
const ANIM_PEEK       := "Peek"         # Rentre dans l'écran (play once)
const ANIM_SUSPICIOUS := "Suspicious"   # Regard interrogatif (loop)
const ANIM_ANGRY      := "Angry"        # Pas contente (loop)
const ANIM_STRIKE     := "Strike"       # Intervient (play once)
const ANIM_BYE        := "bye"          # S'en va (play once)
const ANIM_IDLE       := "Idle"         # Par défaut (loop)
const ANIM_RELAX      := "Relax"        # Pause (loop)

var current_anim: String = ""
var anim_player_ref: AnimationPlayer = null

# ─── Intro State ───
var has_done_intro: bool = false
var intro_step: String = ""
var intro_timer: float = 0.0

func _ready() -> void:
	_position_window()
	_connect_ws()
	
	# Cherche l'AnimationPlayer (chemin direct, puis fallback récursif)
	anim_player_ref = get_node_or_null("Tama/AnimationPlayer")
	if anim_player_ref == null:
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
	# Position fenêtre de base, RIEN à voir avec Tama 3D
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

	# ── Animation SEULEMENT (plus de position) ──
	_update_tama_state(delta)


func _handle_message(raw: String) -> void:
	var data = JSON.parse_string(raw)
	if data == null:
		return

	# ── Commande QUIT : fermeture propre depuis Python ──
	if data.get("command", "") == "QUIT":
		print("👋 Signal QUIT reçu, fermeture propre.")
		get_tree().quit()
		return

	# Démarrage de l'intro UNIQUEMENT 1 FOIS quand la fenêtre est positionnée 
	if data.get("window_ready", false) and not has_done_intro and intro_step == "":
		intro_step = "PEEK"
		print("📐 Fenêtre en place. Lancement de l'intro !")

	prev_suspicion = suspicion_index
	suspicion_index = data.get("suspicion_index", 0.0)
	state = data.get("state", "CALM")
	alignment = data.get("alignment", 1.0)
	current_task = data.get("current_task", "...")
	active_window = data.get("active_window", "Unknown")
	active_duration = data.get("active_duration", 0)

# ─── STATE MACHINE: Animation (Root Motion gère la position) ──

func _update_tama_state(delta: float) -> void:
	if not session_active:
		_play_anim(ANIM_IDLE)
		return
	
	# ─── Séquence d'intro chronologique ───
	if intro_step != "":
		if intro_step == "PEEK":
			_play_anim(ANIM_PEEK)
			# Attendre la fin du play_once
			if anim_player_ref and current_anim == ANIM_PEEK and not anim_player_ref.is_playing():
				intro_step = "HELLO"
				intro_timer = 4.0  # Jouer l'animation Hello pendant 4 secondes
		
		elif intro_step == "HELLO":
			_play_anim(ANIM_HELLO)
			intro_timer -= delta
			if intro_timer <= 0.0:
				intro_step = "BYE"
				
		elif intro_step == "BYE":
			_play_anim(ANIM_BYE)
			# Attendre que "bye" se termine
			if anim_player_ref and current_anim == ANIM_BYE and not anim_player_ref.is_playing():
				intro_step = ""
				has_done_intro = true
				print("👋 Intro terminée, passage en écoute du code Suspicion !")
				
		return # Interdit de lire les autres humeurs comportementales pendant l'intro
	
	# ─── Comportement Standard (Basé sur le Suspicion Index) ───
	var desired_anim := ""
	
	if suspicion_index >= 9.0:
		desired_anim = ANIM_STRIKE
	
	elif suspicion_index >= 7.0:
		desired_anim = ANIM_ANGRY
	
	elif suspicion_index >= 5.0:
		desired_anim = ANIM_SUSPICIOUS
	
	elif suspicion_index >= 3.0:
		desired_anim = ANIM_PEEK
	
	elif suspicion_index <= 1.0 and prev_suspicion > 3.0:
		desired_anim = ANIM_BYE
	
	elif suspicion_index <= 1.0:
		desired_anim = ANIM_RELAX
	
	else:
		desired_anim = ANIM_PEEK
	
	_play_anim(desired_anim)

func _play_anim(anim_name: String) -> void:
	if anim_player_ref == null:
		return
	
	if current_anim == anim_name:
		return
	
	if anim_player_ref.has_animation(anim_name):
		# 0.3 = durée du fondu enchaîné entre les 2 anims
		anim_player_ref.play(anim_name, 0.3)
		current_anim = anim_name
		print("🎬 Animation: ", anim_name)
	else:
		# Fallback de sécu, si le nom est mauvais on prévient dans la console
		print("⚠️ L'animation '", anim_name, "' n'existe pas dans l'AnimationPlayer ! Noms trouvés: ", anim_player_ref.get_animation_list())

# ─── Utilitaires ──────────────────────────────────────────

func _find_animation_player(node: Node) -> AnimationPlayer:
	for child in node.get_children():
		if child is AnimationPlayer:
			return child
		var found := _find_animation_player(child)
		if found:
			return found
	return null
