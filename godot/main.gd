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

# ─── Animation State Machine ──────────────────────────────
# Intro:  HIDDEN → PEEKING → HELLO (loop) → LEAVING → HIDDEN
# Normal: HIDDEN → PEEKING → ACTIVE (Suspicious/Angry loop) → LEAVING → HIDDEN
#         ou:      PEEKING → STRIKING (Strike once, freeze)
# Conversation: HIDDEN → PEEKING → HELLO (loop, waiting) → LEAVING → HIDDEN
enum Phase { HIDDEN, PEEKING, HELLO, ACTIVE, STRIKING, LEAVING }
var phase: int = Phase.HIDDEN
var intro_done: bool = false
var conversation_active: bool = false  # True during casual chat (no deep work)
var current_anim: String = ""
var _anim_player: AnimationPlayer = null
var _prev_suspicion_tier: int = -1

# ─── Radial Settings Menu ─────────────────────────────────
var radial_menu = null
const RadialMenuScript = preload("res://settings_radial.gd")

# ─── Mic Selection Panel ─────────────────────────────────
var mic_panel = null
const MicPanelScript = preload("res://mic_panel.gd")

func _ready() -> void:
	_position_window()
	_connect_ws()
	_setup_radial_menu()
	print("🥷 FocusPals Godot — En attente de connexion...")

func _setup_radial_menu() -> void:
	radial_menu = CanvasLayer.new()
	radial_menu.set_script(RadialMenuScript)
	add_child(radial_menu)
	radial_menu.action_triggered.connect(_on_radial_action)
	radial_menu.request_hide.connect(_on_radial_hide)
	# Mic panel
	mic_panel = CanvasLayer.new()
	mic_panel.set_script(MicPanelScript)
	add_child(mic_panel)
	mic_panel.mic_selected.connect(_on_mic_selected)
	mic_panel.panel_closed.connect(_on_mic_panel_closed)
	print("🎛️ Radial menu + Mic panel initialisés OK")

func _unhandled_input(event: InputEvent) -> void:
	# F1 = debug toggle du menu radial (fonctionne même sans Python)
	if event is InputEventKey and event.pressed and event.keycode == KEY_F1:
		if radial_menu:
			if radial_menu.is_open:
				print("🎛️ [DEBUG] F1 → Fermeture du radial menu")
				radial_menu.close()
			else:
				print("🎛️ [DEBUG] F1 → Ouverture du radial menu")
				radial_menu.open()

func _on_radial_action(action_id: String) -> void:
	print("🎛️ Radial action: " + action_id)
	if action_id == "mic":
		# Demander la liste des micros à Python
		if ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
			ws.send_text(JSON.stringify({"command": "GET_MICS"}))
		return
	if ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		var msg := JSON.stringify({"command": "MENU_ACTION", "action": action_id})
		ws.send_text(msg)

func _on_radial_hide() -> void:
	# Don't re-enable click-through or send HIDE_RADIAL if mic panel just opened
	if mic_panel and mic_panel.is_open:
		return
	_safe_restore_passthrough()
	if ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		ws.send_text(JSON.stringify({"command": "HIDE_RADIAL"}))

func _on_mic_selected(mic_index: int) -> void:
	print("🎤 Micro sélectionné: " + str(mic_index))
	if ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		ws.send_text(JSON.stringify({"command": "SELECT_MIC", "index": mic_index}))

func _on_mic_panel_closed() -> void:
	_safe_restore_passthrough()
	if ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		ws.send_text(JSON.stringify({"command": "HIDE_RADIAL"}))

func _safe_restore_passthrough() -> void:
	if radial_menu and radial_menu.is_open:
		return
	if mic_panel and mic_panel.is_open:
		return
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_MOUSE_PASSTHROUGH, true)

func _position_window() -> void:
	var screen_size := DisplayServer.screen_get_size()
	var win_size := DisplayServer.window_get_size()
	# Positionne LA FENETRE exactement dans le coin en bas à droite
	var x := screen_size.x - win_size.x
	var y := screen_size.y - win_size.y
	DisplayServer.window_set_position(Vector2i(x, y))
	call_deferred("_apply_passthrough")

func _apply_passthrough() -> void:
	get_viewport().transparent_bg = true
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_MOUSE_PASSTHROUGH, true)

func _connect_ws() -> void:
	var err := ws.connect_to_url("ws://localhost:8080")
	if err != OK:
		print("❌ WebSocket: impossible de se connecter")
	else:
		print("🔌 Connexion à ws://localhost:8080...")

func _process(delta: float) -> void:
	ws.poll()
	match ws.get_ready_state():
		WebSocketPeer.STATE_OPEN:
			if not ws_connected:
				ws_connected = true
				# Mode Libre : on n'active PAS la session automatiquement
				# On attend que Python envoie START_SESSION (clic tray)
				print("✅ WebSocket connecté — Mode Libre (en attente de Deep Work)")
			while ws.get_available_packet_count() > 0:
				_handle_message(ws.get_packet().get_string_from_utf8())
		WebSocketPeer.STATE_CLOSED:
			if ws_connected:
				ws_connected = false
				print("🔌 Déconnecté. Reconnexion dans 2s...")
			reconnect_timer += delta
			if reconnect_timer >= 2.0:
				reconnect_timer = 0.0
				_connect_ws()

	# Gestion des anims selon la suspicion (mode normal uniquement)
	_update_suspicion_anim()

func _handle_message(raw: String) -> void:
	var data = JSON.parse_string(raw)
	if data == null:
		return

	# ── Commandes depuis Python ──
	var command = data.get("command", "")
	if command == "QUIT":
		print("👋 Signal QUIT reçu, fermeture propre.")
		get_tree().quit()
		return
	elif command == "START_SESSION":
		if not session_active:
			session_active = true
			conversation_active = false  # Session overrides conversation
			print("🚀 Session Deep Work lancée !")
			_play("Peek", false)
			phase = Phase.PEEKING
		return
	elif command == "START_CONVERSATION":
		if not session_active and not conversation_active:
			conversation_active = true
			print("💬 Mode conversation — Tama arrive !")
			_play("Peek", false)
			phase = Phase.PEEKING
		return
	elif command == "END_CONVERSATION":
		if conversation_active:
			conversation_active = false
			print("💬 Fin de conversation — Tama repart.")
			if phase != Phase.HIDDEN:
				_play("bye", false)
				phase = Phase.LEAVING
		return
	elif command == "SHOW_RADIAL":
		# Kill mic panel IMMEDIATELY — no tween, no _input() interference
		if mic_panel and mic_panel.is_open:
			mic_panel.is_open = false
			mic_panel.visible = false
		if radial_menu:
			radial_menu.open()
		return
	elif command == "HIDE_RADIAL":
		if radial_menu:
			radial_menu.close()
		return
	elif command == "MIC_LIST":
		var mics = data.get("mics", [])
		var selected = int(data.get("selected", -1))
		print("🎤 Reçu %d micros, sélectionné: %d" % [mics.size(), selected])
		if mic_panel and mics.size() > 0:
			if radial_menu and radial_menu.is_open:
				radial_menu.close()
			mic_panel.show_mics(mics, selected)
		return

	# ── Mode Libre : on ignore les données de surveillance ──
	if not data.get("session_active", false):
		return

	# ── Session Active : mise à jour de l'état ──
	suspicion_index = data.get("suspicion_index", 0.0)
	state = data.get("state", "CALM")
	alignment = data.get("alignment", 1.0)
	current_task = data.get("current_task", "...")
	active_window = data.get("active_window", "Unknown")
	active_duration = data.get("active_duration", 0)

	# Pendant l'intro : dès qu'on reçoit les premières données de l'agent,
	# Tama dit bye et repart se cacher (elle a fini son coucou).
	if not intro_done and phase == Phase.HELLO:
		_play("bye", false)
		phase = Phase.LEAVING

# ─── Suspicion Tiers ──────────────────────────────────────
func _get_tier() -> int:
	if suspicion_index >= 9.0: return 3  # STRIKE
	if suspicion_index >= 6.0: return 2  # ANGRY
	if suspicion_index >= 3.0: return 1  # SUSPICIOUS
	return 0                             # CALM → HIDDEN

# ─── Logique Normale (Post-Intro) ─────────────────────────
func _update_suspicion_anim() -> void:
	if not session_active:
		return
	if not intro_done:
		return
	# Ne pas interférer pendant un Peek ou un Bye en cours
	if phase == Phase.PEEKING or phase == Phase.LEAVING:
		return

	var tier := _get_tier()
	if tier == _prev_suspicion_tier:
		return
	_prev_suspicion_tier = tier

	match tier:
		0: # Calme → elle part
			if phase != Phase.HIDDEN:
				_play("bye", false)
				phase = Phase.LEAVING
		1: # Suspecte
			if phase == Phase.HIDDEN:
				_play("Peek", false)
				phase = Phase.PEEKING  # → _on_animation_finished choisira Suspicious
			else:
				_play("Suspicious", true)
				phase = Phase.ACTIVE
		2: # En colère
			if phase == Phase.HIDDEN:
				_play("Peek", false)
				phase = Phase.PEEKING
			else:
				_play("Angry", true)
				phase = Phase.ACTIVE
		3: # Strike !
			if phase == Phase.HIDDEN:
				_play("Peek", false)
				phase = Phase.PEEKING
			else:
				_play("Strike", false)
				phase = Phase.STRIKING

# ─── Callback quand une anim "play once" se termine ──────
func _on_animation_finished(_anim_name: StringName) -> void:
	match phase:
		Phase.PEEKING:
			if conversation_active:
				# Conversation: Peek terminé → Hello loop (elle attend la discussion)
				_play("Hello", true)
				phase = Phase.HELLO
			elif not intro_done:
				# Intro : Peek terminé → dit Hello (loop tant qu'on attend les données)
				_play("Hello", true)
				phase = Phase.HELLO
			else:
				# Normal : Peek terminé → animation selon la suspicion actuelle
				var tier := _get_tier()
				if tier >= 3:
					_play("Strike", false)
					phase = Phase.STRIKING
				elif tier >= 2:
					_play("Angry", true)
					phase = Phase.ACTIVE
				elif tier >= 1:
					_play("Suspicious", true)
					phase = Phase.ACTIVE
				else:
					# La suspicion est retombée pendant le peek → bye direct
					_play("bye", false)
					phase = Phase.LEAVING
		Phase.LEAVING:
			phase = Phase.HIDDEN
			if conversation_active:
				conversation_active = false
				print("💬 Conversation terminée — Tama se cache.")
			elif not intro_done:
				intro_done = true
				print("👋 Intro terminée — Tama se cache.")
			else:
				print("👋 Tama se cache.")
		Phase.STRIKING:
			pass  # Freeze sur la dernière frame — elle reste figée menaçante

# ─── Jouer une animation ─────────────────────────────────
func _play(anim_name: String, loop: bool) -> void:
	_ensure_anim_player()
	if _anim_player == null:
		return
	var anims := _anim_player.get_animation_list()
	var real_name := _find_best_anim(anims, [anim_name])
	if real_name == "":
		push_warning("⚠️ Animation introuvable: " + anim_name)
		return
	current_anim = real_name
	# Force le mode loop/once directement sur la ressource
	var anim := _anim_player.get_animation(real_name)
	if anim:
		anim.loop_mode = Animation.LOOP_LINEAR if loop else Animation.LOOP_NONE
	_anim_player.play(real_name, 0.2)
	_anim_player.speed_scale = 1.0

# ─── Utilitaires ─────────────────────────────────────────
func _ensure_anim_player() -> void:
	if _anim_player != null:
		return
	var tama = get_node_or_null("Tama")
	if tama == null:
		return
	_anim_player = _find_animation_player(tama)
	if _anim_player and not _anim_player.animation_finished.is_connected(_on_animation_finished):
		_anim_player.animation_finished.connect(_on_animation_finished)

func _find_best_anim(available_anims: Array[StringName], priorities: Array) -> String:
	for p in priorities:
		var p_lower := String(p).to_lower()
		for a in available_anims:
			if String(a).to_lower() == p_lower:
				return String(a)
	return ""

func _find_animation_player(node: Node) -> AnimationPlayer:
	for child in node.get_children():
		if child is AnimationPlayer:
			return child
		var found := _find_animation_player(child)
		if found:
			return found
	return null
