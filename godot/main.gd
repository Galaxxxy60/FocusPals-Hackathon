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
var session_elapsed_secs: int = 0
var session_duration_secs: int = 3000  # 50 min default

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
var _last_anim_command_time: float = 0.0  # Timestamp of last Python anim command
const ANIM_COMMAND_COOLDOWN: float = 5.0  # Don't auto-anim if Python sent one recently

# ─── Expression System (UV Swap) ─────────────────────────
var _eyes_material: StandardMaterial3D = null
var _mouth_material: StandardMaterial3D = null
var _expression_ready: bool = false
# ⚠️ Set to true ONLY after expression variants are painted in the texture atlas
# When false: materials are found but NO UV offsets are applied (prevents white eyes)
var _expressions_painted: bool = true

# ─── Pupil Hide & Jaw (Blend Shapes) ─────────────────────
var _body_mesh: MeshInstance3D = null
var _bs_hide_left_eye: int = -1
var _bs_hide_right_eye: int = -1
var _bs_mouth_open: int = -1

# Jaw open amount per viseme (base values, modulated by amplitude)
const JAW_OPEN_MAP = {
	"REST": 0.0,
	"EE_TEETH": 0.2,
	"OH": 0.6,
	"AH": 1.0,
}

# UV offsets from neutral (A1) to each expression cell
# Texture is 512×512. Expressions are in the RIGHT HALF:
#   Column C = x: 0.50-0.75 | Column D = x: 0.75-1.00
#   Row 1 = y: 0.00-0.25   | Row 2 = y: 0.25-0.50
#   Row 3 = y: 0.50-0.75   | Row 4 = y: 0.75-1.00
# Neutral face is in A1 (x: 0.00-0.25, y: 0.00-0.25)
# Offset = target_cell_origin - neutral_cell_origin
const EYE_OFFSETS = {
	"E0": Vector3(0, 0, 0),           # Neutral (body default) — no offset
	"E1": Vector3(0.5, 0, 0),         # C1: Plissés fort suspicieux
	"E2": Vector3(0.75, 0, 0),        # D1: Fermés
	"E3": Vector3(0.5, 0.25, 0),      # C2: Wide/grands ouverts
	"E4": Vector3(0.75, 0.25, 0),     # D2: Happy
	"E5": Vector3(0.5, 0.5, 0),       # C3: Angry
	"E6": Vector3(0.75, 0.5, 0),      # D3: Semi-closed (blink frame)
	"E7": Vector3(0.5, 0.75, 0),      # C4: Plissés léger malicieux
	"E8": Vector3(0.75, 0.75, 0),     # D4: Furieux
}

const MOUTH_OFFSETS = {
	"M0": Vector3(0, 0, 0),           # Neutral (body default) — no offset
	"M1": Vector3(0.5, 0, 0),         # C1: Ronde "O" (grand)
	"M2": Vector3(0.75, 0, 0),        # D1: Large "A" (grand)
	"M3": Vector3(0.5, 0.25, 0),      # C2: Dents "I/E/F/S"
	"M4": Vector3(0.75, 0.25, 0),     # D2: Happy sourire
	"M5": Vector3(0.5, 0.5, 0),       # C3: Unhappy grimace
	"M6": Vector3(0.75, 0.5, 0),      # D3: "Huh" méchant
	"M7": Vector3(0.5, 0.75, 0),      # C4: Sourire malicieux
	"M8": Vector3(0.75, 0.75, 0),     # D4: Furieuse
	"M9": Vector3(0.25, 0.5, 0),      # B3 haut: "A" ouvert moyen
	"M10": Vector3(0.25, 0.625, 0),   # B3 bas: "A" ouvert petit
	"M11": Vector3(0.25, 0.75, 0),    # B4 haut: "O" ouvert moyen
	"M12": Vector3(0.25, 0.875, 0),   # B4 bas: "O" ouvert petit
}

# Viseme → mouth slot mapping (lip sync)
const VISEME_MAP = {
	"REST": "M0",
	"OH": "M1",
	"AH": "M2",
	"EE_TEETH": "M3",
}

# Mood → expression mapping
const MOOD_EYES = {
	"calm": "E4", "curious": "E0", "amused": "E4", "proud": "E4",
	"suspicious": "E7", "disappointed": "E7", "sarcastic": "E7",
	"annoyed": "E5", "angry": "E5", "furious": "E8",
}
const MOOD_MOUTH = {
	"calm": "M4", "curious": "M0", "amused": "M4", "proud": "M4",
	"suspicious": "M7", "disappointed": "M5", "sarcastic": "M6",
	"annoyed": "M5", "angry": "M5", "furious": "M8",
}

var _current_eye_slot: String = "E0"
var _current_mouth_slot: String = "M0"
var _current_mood: String = "calm"
var _is_speaking: bool = false  # True when visemes are active (lip sync overrides mouth)

# ─── Blink System ────────────────────────────────────────
var _blink_timer: float = 0.0
var _blink_next: float = 4.0  # seconds until next blink
var _blink_phase: int = 0     # 0=idle, 1=closing, 2=closed, 3=opening
var _blink_frame_timer: float = 0.0
const BLINK_FRAME_DURATION: float = 0.03

# ─── Radial Settings Menu ─────────────────────────────────
var radial_menu = null
const RadialMenuScript = preload("res://settings_radial.gd")

# ─── Settings Panel ──────────────────────────────────────
var settings_panel = null
const SettingsPanelScript = preload("res://settings_panel.gd")

# ─── Session Progress Arc ─────────────────────────────
var _arc_canvas: CanvasLayer
var _arc_control: Control

# ─── Tama Status Indicator (connection state) ────────
var _status_label: Label
var _status_canvas: CanvasLayer
var _status_visible: bool = false
var _status_dots: int = 0
var _status_timer: float = 0.0
var _gemini_status: String = "disconnected"  # "disconnected", "connecting", "reconnecting", "connected"

# ─── Headphones (visible when Tama can't hear/respond) ───
var _headphones_node: Node3D = null

# ─── User Speaking Acknowledgment ───
var _ack_audio_player: AudioStreamPlayer = null
var _ack_eye_timer: float = 0.0  # Countdown to restore eyes after ack

# ─── Gaze System (procedural bone look-at) ───
var _skeleton: Skeleton3D = null
var _camera: Camera3D = null
var _head_bone_idx: int = -1
var _neck_bone_idx: int = -1
var _head_bone_rest: Quaternion = Quaternion.IDENTITY  # Rest pose (from animation)
var _neck_bone_rest: Quaternion = Quaternion.IDENTITY
var _gaze_current_head: Quaternion = Quaternion.IDENTITY
var _gaze_current_neck: Quaternion = Quaternion.IDENTITY
var _gaze_target_head: Quaternion = Quaternion.IDENTITY
var _gaze_target_neck: Quaternion = Quaternion.IDENTITY
var _gaze_speed: float = 3.0  # Slerp speed
var _gaze_active: bool = false
var _gaze_weight: float = 0.0  # 0 = animation only, 1 = full gaze override
var _gaze_weight_target: float = 0.0

# Gaze targets — procedural, no hardcoded angles
enum GazeTarget { USER, SCREEN_CENTER, SCREEN_TOP, SCREEN_BOTTOM, OTHER_MONITOR, BOOK, AWAY, NEUTRAL }

func _ready() -> void:
	_position_window()
	_connect_ws()
	_setup_radial_menu()
	_setup_arc()
	_setup_expression_system()
	_setup_status_indicator()
	call_deferred("_setup_headphones")
	_setup_ack_audio()
	call_deferred("_setup_gaze")
	print("🥷 FocusPals Godot — En attente de connexion...")

func _setup_radial_menu() -> void:
	radial_menu = CanvasLayer.new()
	radial_menu.set_script(RadialMenuScript)
	add_child(radial_menu)
	radial_menu.action_triggered.connect(_on_radial_action)
	radial_menu.request_hide.connect(_on_radial_hide)
	# Settings panel (replaces old mic panel)
	settings_panel = CanvasLayer.new()
	settings_panel.set_script(SettingsPanelScript)
	add_child(settings_panel)
	settings_panel.mic_selected.connect(_on_mic_selected)
	settings_panel.panel_closed.connect(_on_settings_panel_closed)
	settings_panel.api_key_submitted.connect(_on_api_key_submitted)
	settings_panel.language_changed.connect(_on_language_changed)
	settings_panel.volume_changed.connect(_on_volume_changed)
	settings_panel.session_duration_changed.connect(_on_session_duration_changed)
	print("🎛️ Radial menu + Settings panel initialisés OK")

func _setup_arc() -> void:
	_arc_canvas = CanvasLayer.new()
	_arc_canvas.layer = 50  # Behind menus (100+), above 3D
	add_child(_arc_canvas)
	_arc_control = Control.new()
	_arc_control.name = "SessionArc"
	_arc_control.set_anchors_preset(Control.PRESET_FULL_RECT)
	_arc_control.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_arc_control.connect("draw", _draw_session_arc)
	_arc_canvas.add_child(_arc_control)

func _draw_session_arc() -> void:
	if not session_active or session_duration_secs <= 0:
		return

	var vp := get_viewport().get_visible_rect().size
	# Same center as radial menu (right edge, 70% down)
	var center := Vector2(vp.x, vp.y * 0.7)
	var radius := 36.0
	var thickness := 4.0
	var progress := clampf(float(session_elapsed_secs) / float(session_duration_secs), 0.0, 1.0)

	# Semicircle opening LEFT: from top (PI/2) down to bottom (-PI/2)
	# In Godot's coordinate system: PI/2 = down, -PI/2 = up
	# We want the arc to open to the left, so angles go from PI/2 to 3*PI/2
	var segments := 48
	var start_angle := PI * 0.5    # bottom (6 o'clock on right edge)
	var end_angle := PI * 1.5      # top (12 o'clock on right edge)
	var arc_span := end_angle - start_angle  # PI — semicircle

	# Track (dark, subtle)
	for i in range(segments):
		var a1 := start_angle + arc_span * (float(i) / float(segments))
		var a2 := start_angle + arc_span * (float(i + 1) / float(segments))
		var p1 := center + Vector2(cos(a1), sin(a1)) * radius
		var p2 := center + Vector2(cos(a2), sin(a2)) * radius
		_arc_control.draw_line(p1, p2, Color(0.15, 0.2, 0.3, 0.4), thickness, true)

	# Fill (bright, based on progress)
	if progress > 0.005:
		var fill_segments := int(segments * progress)
		var fill_color := Color(0.3, 0.7, 1.0, 0.85)
		if progress > 0.9:
			fill_color = Color(0.3, 1.0, 0.5, 0.9)
		elif progress > 0.75:
			fill_color = Color(0.4, 0.85, 0.6, 0.85)
		for i in range(fill_segments):
			var a1 := start_angle + arc_span * (float(i) / float(segments))
			var a2 := start_angle + arc_span * (float(i + 1) / float(segments))
			var p1 := center + Vector2(cos(a1), sin(a1)) * radius
			var p2 := center + Vector2(cos(a2), sin(a2)) * radius
			_arc_control.draw_line(p1, p2, fill_color, thickness + 1.5, true)

		# Glow dot at tip
		var tip_angle := start_angle + arc_span * progress
		var tip := center + Vector2(cos(tip_angle), sin(tip_angle)) * radius
		_arc_control.draw_circle(tip, 3.5, fill_color)
		_arc_control.draw_circle(tip, 6.0, Color(fill_color.r, fill_color.g, fill_color.b, 0.25))

	# Time remaining text, offset left of center
	var remaining := maxi(session_duration_secs - session_elapsed_secs, 0)
	var mins := remaining / 60
	var secs := remaining % 60
	var time_str := "%d:%02d" % [mins, secs]
	var font := ThemeDB.fallback_font
	var ts := font.get_string_size(time_str, HORIZONTAL_ALIGNMENT_CENTER, -1, 10)
	_arc_control.draw_string(font,
		Vector2(center.x - radius - ts.x - 6, center.y + ts.y * 0.3),
		time_str, HORIZONTAL_ALIGNMENT_CENTER, -1, 10,
		Color(0.6, 0.75, 0.9, 0.7))

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
	if action_id == "settings":
		# Request settings data from Python (mics + API key status)
		if ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
			ws.send_text(JSON.stringify({"command": "GET_SETTINGS"}))
		return
	if ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		var msg := JSON.stringify({"command": "MENU_ACTION", "action": action_id})
		ws.send_text(msg)

func _on_radial_hide() -> void:
	# Don't re-enable click-through or send HIDE_RADIAL if settings panel just opened
	if settings_panel and settings_panel.is_open:
		return
	_safe_restore_passthrough()
	if ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		ws.send_text(JSON.stringify({"command": "HIDE_RADIAL"}))

func _on_mic_selected(mic_index: int) -> void:
	print("🎤 Micro sélectionné: " + str(mic_index))
	if ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		ws.send_text(JSON.stringify({"command": "SELECT_MIC", "index": mic_index}))

func _on_settings_panel_closed() -> void:
	_safe_restore_passthrough()
	if ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		ws.send_text(JSON.stringify({"command": "HIDE_RADIAL"}))

func _on_api_key_submitted(key: String) -> void:
	print("🔑 API key submitted")
	if ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		ws.send_text(JSON.stringify({"command": "SET_API_KEY", "key": key}))

func _on_language_changed(lang: String) -> void:
	print("🌐 Language changed: " + lang)
	if ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		ws.send_text(JSON.stringify({"command": "SET_LANGUAGE", "language": lang}))

func _on_volume_changed(volume: float) -> void:
	if ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		ws.send_text(JSON.stringify({"command": "SET_TAMA_VOLUME", "volume": volume}))

func _on_session_duration_changed(duration: int) -> void:
	print("⏱️ Session duration changed: " + str(duration) + " min")
	if ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		ws.send_text(JSON.stringify({"command": "SET_SESSION_DURATION", "duration": duration}))

func _safe_restore_passthrough() -> void:
	if radial_menu and radial_menu.is_open:
		return
	if settings_panel and settings_panel.is_open:
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
	# Only auto-animate if Python hasn't sent a recent animation command
	if Time.get_unix_time_from_system() - _last_anim_command_time > ANIM_COMMAND_COOLDOWN:
		_update_suspicion_anim()

	# Blink system
	_update_blink(delta)

	# Session progress arc redraw (only when session active)
	if _arc_control and session_active:
		_arc_control.queue_redraw()

	# Tama status indicator
	_update_status_indicator(delta)

	# Ack eye timer — restore eyes after acknowledgment
	if _ack_eye_timer > 0:
		_ack_eye_timer -= delta
		if _ack_eye_timer <= 0:
			# Restore to current mood eyes
			var mood_eye = MOOD_EYES.get(_current_mood, "E0")
			_set_expression_slot("eyes", mood_eye)

	# Gaze system — smooth bone rotation each frame
	_update_gaze(delta)


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
		# If settings panel is open, close it first then open radial
		if settings_panel and settings_panel.is_open:
			settings_panel.close()
		if radial_menu:
			radial_menu.open()
		return
	elif command == "HIDE_RADIAL":
		if radial_menu:
			radial_menu.close()
		return
	elif command == "SETTINGS_DATA":
		var mics = data.get("mics", [])
		var selected = int(data.get("selected", -1))
		var has_api_key = data.get("has_api_key", false)
		var key_valid = data.get("key_valid", false)
		var lang = data.get("language", "fr")
		var tama_vol = data.get("tama_volume", 1.0)
		var session_duration = int(data.get("session_duration", 50))
		var api_usage = data.get("api_usage", {})
		print("⚙️ Settings: %d micros, selected: %d, API key: %s, valid: %s, lang: %s, duration: %d" % [mics.size(), selected, str(has_api_key), str(key_valid), lang, session_duration])
		if settings_panel:
			if radial_menu and radial_menu.is_open:
				radial_menu.close()
			settings_panel.show_settings(mics, selected, has_api_key, key_valid, lang, tama_vol, session_duration, api_usage)
		return
	elif command == "API_KEY_UPDATED":
		var valid = data.get("valid", false)
		print("🔑 API key validation result: %s" % str(valid))
		if settings_panel:
			settings_panel.update_key_valid(valid)
		return
	elif command == "USER_SPEAKING":
		# Instant local reaction — Tama acknowledges user before Gemini responds
		if conversation_active:
			_on_user_speaking_ack()
		return
	elif command == "GAZE_AT":
		# Python tells Tama where to look
		# Supports: {x, y} screen pixels OR {target: "user"/"screen"/"book"/etc}
		var spd = data.get("speed", 3.0)
		if data.has("x") and data.has("y"):
			# Screen pixel coordinates
			set_gaze_at_screen_point(float(data["x"]), float(data["y"]), spd)
		elif data.has("target"):
			var t = str(data["target"]).to_lower()
			match t:
				"user": set_gaze(GazeTarget.USER, spd)
				"screen", "screen_center": set_gaze(GazeTarget.SCREEN_CENTER, spd)
				"screen_top": set_gaze(GazeTarget.SCREEN_TOP, spd)
				"screen_bottom": set_gaze(GazeTarget.SCREEN_BOTTOM, spd)
				"other_monitor": set_gaze(GazeTarget.OTHER_MONITOR, spd)
				"book": set_gaze(GazeTarget.BOOK, spd)
				"away": set_gaze(GazeTarget.AWAY, spd)
				"neutral": set_gaze(GazeTarget.NEUTRAL, spd)
		return
	elif command == "TAMA_ANIM":
		# Python tells Godot exactly which animation to play
		var anim_name = data.get("anim", "")
		var loop = data.get("loop", false)
		_last_anim_command_time = Time.get_unix_time_from_system()
		print("🎬 [ANIM CMD] " + anim_name + (" (loop)" if loop else ""))
		if anim_name == "bye":
			if phase != Phase.HIDDEN:
				_play("bye", false)
				phase = Phase.LEAVING
		elif anim_name == "Peek":
			if phase == Phase.HIDDEN:
				_play("Peek", false)
				phase = Phase.PEEKING
		else:
			# Suspicious, Angry, Strike, Hello — play directly
			if phase == Phase.HIDDEN:
				# Need to peek first, then the animation will be chosen in _on_animation_finished
				_prev_suspicion_tier = _get_tier()  # Sync tier so peek leads to right anim
				_play("Peek", false)
				phase = Phase.PEEKING
			else:
				if anim_name == "Strike":
					_play("Strike", false)
					phase = Phase.STRIKING
				else:
					_play(anim_name, loop)
					phase = Phase.ACTIVE
		return
	elif command == "TAMA_MOOD":
		var mood_name = data.get("mood", "calm")
		var mood_intensity = data.get("intensity", 0.5)
		_current_mood = mood_name
		print("🎭 Mood: " + mood_name + " (" + str(mood_intensity) + ")")
		# Set expression from mood (eyes + mouth idle)
		var eye_key = MOOD_EYES.get(mood_name, "E0")
		var mouth_key = MOOD_MOUTH.get(mood_name, "M0")
		# Suspicious intensity affects which eyes
		if mood_name == "suspicious" and mood_intensity >= 0.7:
			eye_key = "E1"  # Plissés fort instead of léger
		_set_eyes(eye_key)
		if not _is_speaking:  # Don't override lip sync
			_set_mouth(mouth_key)
		return
	elif command == "VISEME":
		var shape = data.get("shape", "REST")
		var amp: float = data.get("amp", 0.5)
		var mouth_slot = VISEME_MAP.get(shape, "M0")
		# Track Tama speech
		if shape != "REST":
			if not _is_speaking and conversation_active:
				set_gaze(GazeTarget.USER, 5.0)  # Look at user while talking
		if shape == "REST":
			_is_speaking = false
			# Return to mood-based mouth expression
			_set_mouth(_current_mouth_slot)
			_set_jaw_open(0.0)
			if conversation_active:
				set_gaze(GazeTarget.NEUTRAL, 2.0)  # Relax gaze after speaking
		else:
			_is_speaking = true
			# Amplitude-based mouth selection for AH and OH
			if shape == "AH":
				if _current_mood in ["angry", "furious", "annoyed"]:
					mouth_slot = "M6"  # Huh méchant when angry
				elif amp > 0.6:
					mouth_slot = "M2"   # A grand ouvert (loud)
				elif amp > 0.3:
					mouth_slot = "M9"   # A ouvert moyen
				else:
					mouth_slot = "M10"  # A ouvert petit (quiet)
			elif shape == "OH":
				if amp > 0.6:
					mouth_slot = "M1"   # O grand ouvert (loud)
				elif amp > 0.3:
					mouth_slot = "M11"  # O ouvert moyen
				else:
					mouth_slot = "M12"  # O ouvert petit (quiet)
			_set_mouth(mouth_slot)
			# Jaw open = base amount per viseme × amplitude
			var base_jaw: float = JAW_OPEN_MAP.get(shape, 0.3)
			_set_jaw_open(base_jaw * clampf(amp, 0.3, 1.0))
		return
	elif command == "CONNECTION_STATUS":
		var conn_status = data.get("status", "")
		_gemini_status = conn_status
		if conn_status == "connecting":
			_show_status_indicator("Tama se connecte", Color(0.5, 0.7, 1.0, 0.9))
			_set_headphones_visible(true)
		elif conn_status == "reconnecting":
			var attempt = data.get("attempt", 1)
			_show_status_indicator("Reconnexion (" + str(attempt) + ")", Color(0.9, 0.7, 0.3, 0.9))
			_set_headphones_visible(true)
		elif conn_status == "connected":
			_hide_status_indicator()
			_set_headphones_visible(false)
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
	session_elapsed_secs = data.get("session_elapsed_secs", 0)
	session_duration_secs = data.get("session_duration_secs", 3000)

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

# ─── Expression System ───────────────────────────────────
func _setup_expression_system() -> void:
	# Find the Tama node and its mesh materials
	# Deferred because the .glb instance needs time to instantiate
	call_deferred("_find_face_materials")

func _find_face_materials() -> void:
	var tama = get_node_or_null("Tama")
	if tama == null:
		print("⚠️ Expression: Tama node not found")
		return
	# Search for MeshInstance3D nodes with eyes/mouth materials
	_scan_for_materials(tama)
	if _eyes_material:
		print("👀 Eyes material found")
	else:
		print("⚠️ Eyes material NOT found — looking for material named 'eyes'")
	if _mouth_material:
		print("👄 Mouth material found")
	else:
		print("⚠️ Mouth material NOT found — looking for material named 'mouth'")
	_expression_ready = _eyes_material != null or _mouth_material != null
	if _expression_ready:
		print("🎭 Expression system ready!")

func _scan_for_materials(node: Node) -> void:
	if node is MeshInstance3D:
		var mesh_inst: MeshInstance3D = node as MeshInstance3D
		var surf_count: int = mesh_inst.get_surface_override_material_count()
		print("🔍 MeshInstance3D '%s' — %d surfaces" % [mesh_inst.name, surf_count])
		for i in range(surf_count):
			# Get the override material (what we'll manipulate)
			var override_mat: Material = mesh_inst.get_surface_override_material(i)
			# Get the ORIGINAL mesh material (has the real name from Blender)
			var original_name: String = ""
			if mesh_inst.mesh and i < mesh_inst.mesh.get_surface_count():
				var orig: Material = mesh_inst.mesh.surface_get_material(i)
				if orig:
					original_name = orig.resource_name
			# Use override if present, otherwise original
			var active_mat: Material = override_mat
			if active_mat == null and mesh_inst.mesh:
				active_mat = mesh_inst.mesh.surface_get_material(i)
			var override_name: String = ""
			if override_mat:
				override_name = override_mat.resource_name
			print("  [%d] original='%s' override='%s'" % [i, original_name, override_name])
			if active_mat == null:
				continue
			if not (active_mat is StandardMaterial3D):
				continue
			# Check ORIGINAL name for identification (Blender names: mouth, body, eyes, etc.)
			var name_lower: String = original_name.to_lower()
			if name_lower == "":
				name_lower = override_name.to_lower()
			var std_mat: StandardMaterial3D = active_mat as StandardMaterial3D
			if "eye" in name_lower or "yeux" in name_lower:
				var dup: StandardMaterial3D = std_mat.duplicate() as StandardMaterial3D
				mesh_inst.set_surface_override_material(i, dup)
				_eyes_material = dup
				print("  ✅ → EYES material (index %d)" % i)
			elif "mouth" in name_lower or "bouche" in name_lower:
				var dup: StandardMaterial3D = std_mat.duplicate() as StandardMaterial3D
				mesh_inst.set_surface_override_material(i, dup)
				_mouth_material = dup
				print("  ✅ → MOUTH material (index %d)" % i)
		# Find blend shapes for pupil hiding + jaw
		if mesh_inst.mesh and mesh_inst.mesh is ArrayMesh:
			var arr_mesh: ArrayMesh = mesh_inst.mesh as ArrayMesh
			var bs_count: int = arr_mesh.get_blend_shape_count()
			for bs_i in range(bs_count):
				var bs_name: String = arr_mesh.get_blend_shape_name(bs_i)
				if bs_name == "BS_HideLeftEye":
					_bs_hide_left_eye = bs_i
					_body_mesh = mesh_inst
					print("  👁️ BS_HideLeftEye found (index %d)" % bs_i)
				elif bs_name == "BS_HideRightEye":
					_bs_hide_right_eye = bs_i
					_body_mesh = mesh_inst
					print("  👁️ BS_HideRightEye found (index %d)" % bs_i)
				elif bs_name == "BS_MoutOpen":
					_bs_mouth_open = bs_i
					_body_mesh = mesh_inst
					print("  💥 BS_MoutOpen found (index %d)" % bs_i)
	for child in node.get_children():
		_scan_for_materials(child)

func _set_expression_slot(slot_type: String, slot: String) -> void:
	if slot_type == "eyes":
		_set_eyes(slot)
	elif slot_type == "mouth":
		_set_mouth(slot)

func _set_eyes(slot: String) -> void:
	_current_eye_slot = slot
	_apply_eye_offset(slot)

# Apply UV offset without changing _current_eye_slot (used by blink)
func _apply_eye_offset(slot: String) -> void:
	if not _expressions_painted:
		return
	if _eyes_material and EYE_OFFSETS.has(slot):
		_eyes_material.uv1_offset = EYE_OFFSETS[slot]

func _set_mouth(slot: String) -> void:
	if not _is_speaking:
		_current_mouth_slot = slot  # Remember mood-based mouth for when lip sync stops
	if not _expressions_painted:
		return
	if _mouth_material and MOUTH_OFFSETS.has(slot):
		_mouth_material.uv1_offset = MOUTH_OFFSETS[slot]

func _set_jaw_open(amount: float) -> void:
	if _body_mesh and _bs_mouth_open >= 0:
		_body_mesh.set_blend_shape_value(_bs_mouth_open, clampf(amount, 0.0, 1.0))

# ─── Blink System ────────────────────────────────────────
func _set_pupils_visible(visible: bool) -> void:
	if _body_mesh == null:
		return
	var val: float = 0.0 if visible else 1.0
	if _bs_hide_left_eye >= 0:
		_body_mesh.set_blend_shape_value(_bs_hide_left_eye, val)
	if _bs_hide_right_eye >= 0:
		_body_mesh.set_blend_shape_value(_bs_hide_right_eye, val)

func _update_blink(delta: float) -> void:
	if not _expression_ready:
		return

	if _blink_phase == 0:
		# Waiting for next blink
		_blink_timer += delta
		if _blink_timer >= _blink_next:
			_blink_timer = 0.0
			_blink_next = randf_range(3.0, 7.0)  # Random interval
			_blink_phase = 1
			_blink_frame_timer = 0.0
			_set_pupils_visible(false)  # Hide pupils
			_apply_eye_offset("E6")  # Semi-closed
	else:
		_blink_frame_timer += delta
		if _blink_frame_timer >= BLINK_FRAME_DURATION:
			_blink_frame_timer = 0.0
			if _blink_phase == 1:
				_blink_phase = 2
				_apply_eye_offset("E2")  # Fully closed
			elif _blink_phase == 2:
				_blink_phase = 3
				_apply_eye_offset("E6")  # Semi-closed (opening)
			elif _blink_phase == 3:
				_blink_phase = 0
				_set_pupils_visible(true)  # Show pupils
				_apply_eye_offset(_current_eye_slot)  # Back to mood expression


# ─── Headphones (deaf mode indicator) ───────────────────
func _setup_headphones() -> void:
	# HeadPhones is attached to Tama's skeleton in the scene tree
	_headphones_node = get_node_or_null("Tama/Armature/Skeleton3D/HeadPhones")
	if _headphones_node == null:
		# Try alternative paths (in case of different hierarchy)
		var tama = get_node_or_null("Tama")
		if tama:
			_headphones_node = _find_node_by_name(tama, "HeadPhones")
	if _headphones_node:
		_headphones_node.visible = true  # Visible by default (Tama can't hear yet)
		print("🎧 Headphones node found — visible (not connected yet)")
	else:
		print("⚠️ HeadPhones node not found in scene tree")

func _find_node_by_name(root: Node, target_name: String) -> Node:
	for child in root.get_children():
		if child.name == target_name:
			return child
		var found = _find_node_by_name(child, target_name)
		if found:
			return found
	return null

func _set_headphones_visible(show: bool) -> void:
	if _headphones_node:
		_headphones_node.visible = show

# (Silence watchdog removed — headphones now only reflect connection status)

# ─── User Speaking Acknowledgment ───────────────────
func _setup_ack_audio() -> void:
	_ack_audio_player = AudioStreamPlayer.new()
	var audio_file = load("res://hmm_acknowledge.wav")
	if audio_file:
		_ack_audio_player.stream = audio_file
		_ack_audio_player.volume_db = -12.0  # Soft, unobtrusive
	else:
		push_warning("\u26a0\ufe0f hmm_acknowledge.wav not found")
	add_child(_ack_audio_player)

func _on_user_speaking_ack() -> void:
	# Skip if Tama is already speaking (Gemini response playing)
	if _is_speaking:
		return
	# Play soft acknowledgment sound
	if _ack_audio_player and _ack_audio_player.stream:
		_ack_audio_player.play()
	# Change eyes to curious/attentive (E0 = wide eyes)
	_set_expression_slot("eyes", "E0")
	_ack_eye_timer = 2.0  # Restore after 2 seconds
	# Look at the user
	set_gaze(GazeTarget.USER, 4.0)
	print("\ud83d\udc40 Ack: Tama heard you!")

# ─── Gaze System ────────────────────────────────────────
func _setup_gaze() -> void:
	# Find Camera3D
	_camera = get_node_or_null("Camera3D")
	if _camera == null:
		# Try finding recursively
		for child in get_children():
			if child is Camera3D:
				_camera = child
				break
	if _camera:
		print("\ud83c\udfa5 Gaze: Camera3D found at %s" % str(_camera.global_position))

	# Find Skeleton3D
	var skel = get_node_or_null("Tama/Armature/Skeleton3D")
	if skel == null:
		var tama = get_node_or_null("Tama")
		if tama:
			skel = _find_skeleton(tama)
	if skel == null:
		print("\u26a0\ufe0f Gaze: Skeleton3D not found")
		return
	_skeleton = skel

	# Find Head and Neck bones
	for i in range(_skeleton.get_bone_count()):
		var bname = _skeleton.get_bone_name(i).to_lower()
		if bname == "head":
			_head_bone_idx = i
		elif bname == "neck":
			_neck_bone_idx = i

	# Partial match fallback
	if _head_bone_idx < 0:
		for i in range(_skeleton.get_bone_count()):
			if "head" in _skeleton.get_bone_name(i).to_lower():
				_head_bone_idx = i
				break
	if _neck_bone_idx < 0:
		for i in range(_skeleton.get_bone_count()):
			if "neck" in _skeleton.get_bone_name(i).to_lower():
				_neck_bone_idx = i
				break

	# Store rest poses
	if _head_bone_idx >= 0:
		_head_bone_rest = _skeleton.get_bone_rest(_head_bone_idx).basis.get_rotation_quaternion()
		print("\ud83d\udc40 Gaze: Head bone [%d] '%s'" % [_head_bone_idx, _skeleton.get_bone_name(_head_bone_idx)])
	if _neck_bone_idx >= 0:
		_neck_bone_rest = _skeleton.get_bone_rest(_neck_bone_idx).basis.get_rotation_quaternion()
		print("\ud83d\udc40 Gaze: Neck bone [%d] '%s'" % [_neck_bone_idx, _skeleton.get_bone_name(_neck_bone_idx)])

	# Print all bones for debug
	print("\ud83e\uddb4 Skeleton bones:")
	for i in range(_skeleton.get_bone_count()):
		print("  [%d] %s" % [i, _skeleton.get_bone_name(i)])

	_gaze_active = _head_bone_idx >= 0 and _camera != null
	if _gaze_active:
		print("\u2705 Gaze system ready (procedural look-at)!")
	elif _camera == null:
		print("\u26a0\ufe0f Gaze: Camera3D not found — gaze disabled")

func _find_skeleton(node: Node) -> Skeleton3D:
	if node is Skeleton3D:
		return node as Skeleton3D
	for child in node.get_children():
		var found = _find_skeleton(child)
		if found:
			return found
	return null

# Compute a world-space target point for a given GazeTarget
func _get_gaze_target_point(target: GazeTarget) -> Vector3:
	var cam_pos: Vector3 = _camera.global_position
	var head_pos: Vector3 = Vector3.ZERO
	if _head_bone_idx >= 0:
		head_pos = _skeleton.global_transform * _skeleton.get_bone_global_pose(_head_bone_idx).origin

	match target:
		GazeTarget.USER:
			# User is behind the camera, looking at the screen
			return cam_pos
		GazeTarget.SCREEN_CENTER:
			# Screen center = slightly behind camera, offset right from Tama
			var right = _camera.global_transform.basis.x
			return cam_pos - right * 1.5  # Center of screen (left from cam perspective)
		GazeTarget.SCREEN_TOP:
			var right = _camera.global_transform.basis.x
			var up = _camera.global_transform.basis.y
			return cam_pos - right * 1.5 + up * 0.8
		GazeTarget.SCREEN_BOTTOM:
			var right = _camera.global_transform.basis.x
			var up = _camera.global_transform.basis.y
			return cam_pos - right * 1.5 - up * 0.8
		GazeTarget.OTHER_MONITOR:
			# Far left from camera (second monitor)
			var right = _camera.global_transform.basis.x
			return cam_pos - right * 4.0
		GazeTarget.BOOK:
			# Below and slightly in front of head
			return head_pos + Vector3(0, -0.5, 0.3)
		GazeTarget.AWAY:
			# Behind and to the side of Tama
			var right = _camera.global_transform.basis.x
			return head_pos + right * 2.0
		GazeTarget.NEUTRAL, _:
			# Forward gaze — slightly in front of head
			var forward = _camera.global_transform.basis.z
			return head_pos - forward * 2.0

# Compute the bone-local rotation to look at a target point
func _compute_look_at_rotation(bone_idx: int, target_world: Vector3, influence: float) -> Quaternion:
	if bone_idx < 0:
		return Quaternion.IDENTITY

	# Get the bone's current global transform (from animation)
	var bone_global: Transform3D = _skeleton.global_transform * _skeleton.get_bone_global_pose(bone_idx)
	var bone_pos: Vector3 = bone_global.origin

	# Direction from bone to target
	var dir_to_target: Vector3 = (target_world - bone_pos).normalized()
	if dir_to_target.length_squared() < 0.001:
		return Quaternion.IDENTITY

	# Current forward direction of the bone (Y-up convention for head bones)
	var current_forward: Vector3 = bone_global.basis.z.normalized()

	# Rotation from current forward to target direction
	var rot_axis = current_forward.cross(dir_to_target).normalized()
	if rot_axis.length_squared() < 0.001:
		return Quaternion.IDENTITY
	var rot_angle = current_forward.angle_to(dir_to_target) * influence

	# Clamp max rotation to avoid unnatural neck breaking
	rot_angle = clamp(rot_angle, -1.2, 1.2)  # ~70 degrees max

	# Return rotation in bone-local space
	var world_rot = Quaternion(rot_axis, rot_angle)
	# Convert world rotation to bone-local space
	var parent_global_rot = bone_global.basis.get_rotation_quaternion()
	return parent_global_rot.inverse() * world_rot * parent_global_rot

func set_gaze(target: GazeTarget, speed: float = 3.0) -> void:
	"""Convenience: look at a named preset target."""
	if not _gaze_active:
		return
	if target == GazeTarget.NEUTRAL:
		_gaze_speed = speed
		_gaze_target_head = Quaternion.IDENTITY
		_gaze_target_neck = Quaternion.IDENTITY
		_gaze_weight_target = 0.0
	else:
		var point = _get_gaze_target_point(target)
		set_gaze_at_world_point(point, speed)

func set_gaze_at_world_point(point: Vector3, speed: float = 3.0) -> void:
	"""Core: Tama looks at any arbitrary 3D world point."""
	if not _gaze_active:
		return
	_gaze_speed = speed
	_gaze_target_head = _compute_look_at_rotation(_head_bone_idx, point, 0.6)
	_gaze_target_neck = _compute_look_at_rotation(_neck_bone_idx, point, 0.4)
	_gaze_weight_target = 1.0

func set_gaze_at_screen_point(screen_x: float, screen_y: float, speed: float = 3.0) -> void:
	"""Map real screen pixel coordinates to a 3D point and look there.
	screen_x/y = pixel position on the actual monitor (e.g. 960, 540 = center of 1920x1080).
	Tama's window is at the right edge, so screen content is to her right."""
	if not _gaze_active:
		return
	# Normalize screen coords to -1..1 range (centered on screen)
	# Assuming 1920x1080 primary monitor — could be made dynamic
	var screen_w: float = DisplayServer.screen_get_size().x
	var screen_h: float = DisplayServer.screen_get_size().y
	var norm_x: float = (screen_x / screen_w - 0.5) * 2.0  # -1 (left) to 1 (right)
	var norm_y: float = (screen_y / screen_h - 0.5) * 2.0  # -1 (top) to 1 (bottom)

	# Map to 3D world space using camera orientation
	var cam_pos = _camera.global_position
	var right = _camera.global_transform.basis.x
	var up = _camera.global_transform.basis.y
	var forward = -_camera.global_transform.basis.z

	# The screen is "behind" the camera from Tama's perspective
	# X: negative norm_x = left of screen = more to the "screen side" from Tama
	# Y: negative norm_y = top of screen = up
	var world_point = cam_pos + forward * 0.5 - right * norm_x * 2.0 - up * norm_y * 1.2
	set_gaze_at_world_point(world_point, speed)

func _update_gaze(delta: float) -> void:
	if not _gaze_active or _skeleton == null:
		return

	# Smooth weight transition
	_gaze_weight = lerp(_gaze_weight, _gaze_weight_target, clamp(_gaze_speed * delta, 0.0, 1.0))

	# Smooth slerp toward target rotation
	var t = clamp(_gaze_speed * delta, 0.0, 1.0)
	_gaze_current_head = _gaze_current_head.slerp(_gaze_target_head, t)
	_gaze_current_neck = _gaze_current_neck.slerp(_gaze_target_neck, t)

	# Apply gaze as additive rotation blended by weight
	if _gaze_weight > 0.01:
		if _head_bone_idx >= 0:
			var anim_rot = _skeleton.get_bone_pose_rotation(_head_bone_idx)
			var blended = anim_rot.slerp(anim_rot * _gaze_current_head, _gaze_weight)
			_skeleton.set_bone_pose_rotation(_head_bone_idx, blended)
		if _neck_bone_idx >= 0:
			var anim_rot = _skeleton.get_bone_pose_rotation(_neck_bone_idx)
			var blended = anim_rot.slerp(anim_rot * _gaze_current_neck, _gaze_weight)
			_skeleton.set_bone_pose_rotation(_neck_bone_idx, blended)

# ─── Tama Status Indicator ──────────────────────────────
func _setup_status_indicator() -> void:
	_status_canvas = CanvasLayer.new()
	_status_canvas.layer = 10
	add_child(_status_canvas)
	_status_label = Label.new()
	_status_label.text = ""
	_status_label.add_theme_font_size_override("font_size", 13)
	_status_label.add_theme_color_override("font_color", Color(0.5, 0.7, 1.0, 0.9))
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	_status_label.offset_top = -40
	_status_label.offset_bottom = -10
	_status_canvas.add_child(_status_label)
	_status_label.visible = false

func _show_status_indicator(text: String, color: Color) -> void:
	_status_visible = true
	_status_label.visible = true
	_status_dots = 0
	_status_timer = 0.0
	_status_label.text = text + "..."
	_status_label.add_theme_color_override("font_color", color)

func _hide_status_indicator() -> void:
	_status_visible = false
	_status_label.visible = false
	_gemini_status = "connected"

func _update_status_indicator(delta: float) -> void:
	if not _status_visible:
		return
	_status_timer += delta
	if _status_timer >= 0.5:
		_status_timer = 0.0
		_status_dots = (_status_dots + 1) % 4
		var dots = ".".repeat(_status_dots + 1)
		# Extract base text (before dots)
		var base_text = _status_label.text
		var dot_start = base_text.find(".")
		if dot_start > 0:
			base_text = base_text.substr(0, dot_start)
		_status_label.text = base_text + dots
	# Pulse alpha — gentle breathing effect
	var alpha = 0.5 + 0.4 * sin(Time.get_ticks_msec() * 0.004)
	_status_label.modulate = Color(1, 1, 1, alpha)
