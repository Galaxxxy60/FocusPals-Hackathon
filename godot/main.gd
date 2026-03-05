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
var _on_wall: bool = false              # True when Tama is leaning on the wall (Idle_wall)
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

# ─── Eyebrow Blend Shapes ─────────────────────────────
var _bs_eyebrow_question: int = -1
var _bs_eyebrow_sad: int = -1
var _bs_eyebrow_angry: int = -1
var _bs_eyebrow_surprise: int = -1

# ─── Eye Follow (Blend Shapes: LookLeft/Right/Up/Down) ───
var _bs_look_left: int = -1
var _bs_look_right: int = -1
var _bs_look_up: int = -1
var _bs_look_down: int = -1
var _eye_follow_active: bool = false   # Master switch (set by Python or F4 debug)
var _debug_eye_follow: bool = false    # F4 debug toggle (mouse follow)
var _eye_follow_h: float = 0.0        # Current horizontal: -1=left, 0=center, +1=right
var _eye_follow_v: float = 0.0        # Current vertical: -1=down, 0=center, +1=up
var _eye_target_h: float = 0.0        # Target horizontal
var _eye_target_v: float = 0.0        # Target vertical
var _eye_saccade_timer: float = 0.0   # Timer between saccades
const EYE_SACCADE_INTERVAL: float = 0.08  # Snap every ~80ms (like real saccades)
const EYE_SACCADE_THRESHOLD: float = 0.03 # Dead zone: ignore tiny changes
const EYE_RETURN_SPEED: float = 8.0       # Speed to return to center when deactivated

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

# Mood → eyebrow blend shape mapping {blend_shape_name: intensity}
# Only one eyebrow shape is active at a time (others reset to 0)
const MOOD_EYEBROWS = {
	"calm": {},
	"curious": {"question": 0.7},
	"amused": {},
	"proud": {},
	"suspicious": {"question": 1.0},
	"disappointed": {"sad": 0.8},
	"sarcastic": {"question": 0.5},
	"annoyed": {"angry": 0.6},
	"angry": {"angry": 0.8},
	"furious": {"angry": 1.0},
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

# ─── Gaze System (post-process bone look-at) ───
var _skeleton: Skeleton3D = null
var _camera: Camera3D = null
var _head_bone_idx: int = -1
var _neck_bone_idx: int = -1

# Gaze rotation state
var _gaze_delta_head: Quaternion = Quaternion.IDENTITY   # Current smoothed rotation
var _gaze_delta_neck: Quaternion = Quaternion.IDENTITY
var _gaze_target_head: Quaternion = Quaternion.IDENTITY   # Target to slerp toward
var _gaze_target_neck: Quaternion = Quaternion.IDENTITY
var _gaze_lerp_speed: float = 5.0   # How fast we slerp toward target
var _gaze_active: bool = false
var _gaze_blend: float = 0.0        # 0 = pure animation, 1 = full gaze applied
var _gaze_blend_target: float = 0.0 # What blend is transitioning toward
const GAZE_BLEND_SPEED: float = 4.0 # How fast blend fades in/out

# Base rotation: the animation's natural head/neck rotation, captured once
# before gaze ever modifies the bones. Used instead of IDENTITY so that
# blend=0 returns to the animation pose (not the bind pose / chin-up).
var _head_base_rot: Quaternion = Quaternion.IDENTITY
var _neck_base_rot: Quaternion = Quaternion.IDENTITY
var _gaze_base_captured: bool = false

# Gaze targets — procedural, no hardcoded angles
enum GazeTarget { USER, SCREEN_CENTER, SCREEN_TOP, SCREEN_BOTTOM, OTHER_MONITOR, BOOK, AWAY, NEUTRAL }

# Current 3D world target for gaze (used by debug viz)
var _gaze_world_target: Vector3 = Vector3.ZERO

# Debug: gaze follows mouse + visual debug
var _debug_gaze_mouse: bool = false
var _debug_sphere: MeshInstance3D = null
var _debug_sphere_mat: StandardMaterial3D = null
var _debug_line_mesh: ImmediateMesh = null
var _debug_line_node: MeshInstance3D = null
var _debug_depth_mesh: ImmediateMesh = null   # Cyan Z-depth line
var _debug_depth_node: MeshInstance3D = null
var _debug_print_timer: float = 0.0

# ─── Spring Bones (Verlet virtual-tail simulation) ─────────
var _spring_bones: Array = []    # Array of spring bone dictionaries
var _spring_colliders: Array = []  # Sphere colliders to prevent body clipping
var _debug_colliders: bool = false  # F5 toggle: show collision spheres
var _debug_collider_meshes: Array = []  # MeshInstance3D nodes for debug viz
var _debug_selected_collider: int = 0  # Which collider is selected for tuning

# Collision spheres: [anchor_bone_name, local_offset, radius]
# anchor_bone_name: bone the sphere follows
# local_offset: offset from bone origin in bone-local space
# radius: sphere radius in world units
const SPRING_COLLIDER_CONFIGS = [
	# Head sphere — tuned via F5 debug
	["Jnt_C_Head", Vector3(0, -0.16, 0), 0.23],
	# Upper torso — tuned via F5 debug
	["Jnt_C_Spine2", Vector3(0, -0.03, 0.01), 0.21],
]

# Spring bone configs: [bone_name, stiffness, drag, gravity, max_X°, max_Y°, max_Z°]
# stiffness: constant force pulling tail back toward rest direction (higher = stiffer)
# drag: fraction of velocity lost per frame (0 = no damping, 1 = fully damped)
# gravity: world-space downward force strength
# max_X/Y/Z: per-axis rotation limits from rest (Euler degrees, matching Blender)
#   Y = bone-axis twist (keep tight for hair), X/Z = swing freedom
const SPRING_BONE_CONFIGS = [
	# Front hair — Y locked (no twist), X/Z free swing
	["Jnt_L_FrontHair", 1.2, 0.08, 0.5, 60.0, 4.0, 60.0],
	["Jnt_R_FrontHair", 1.2, 0.08, 0.5, 60.0, 4.0, 60.0],
	# Side hair — long locks, much less stiffness ("gel"), strong gravity so they hang naturally
	["Jnt_L_SideHair", 0.3, 0.05, 1.2, 70.0, 4.0, 70.0],
	["Jnt_L_SideHair2", 0.1, 0.04, 1.5, 70.0, 4.0, 70.0],
	["Jnt_R_SideHair", 0.3, 0.05, 1.2, 70.0, 4.0, 70.0],
	["Jnt_R_SideHair2", 0.1, 0.04, 1.5, 70.0, 4.0, 70.0],
	# Back hair — similar to side hair but slightly stiffer
	["Jnt_C_HairBack", 0.4, 0.05, 1.0, 60.0, 4.0, 60.0],
	# Hoodie strings — heavier pendulum, more freedom all axes
	["Jnt_L_Strings", 0.7, 0.07, 1.0, 50.0, 20.0, 50.0],
	["Jnt_L_Strings2", 0.5, 0.06, 1.2, 55.0, 20.0, 55.0],
	["Jnt_L_strings3", 0.4, 0.06, 1.4, 55.0, 20.0, 55.0],
	["Jnt_L_strings4", 0.3, 0.05, 1.6, 60.0, 20.0, 60.0],
	["Jnt_R_strings", 0.7, 0.07, 1.0, 50.0, 20.0, 50.0],
	["Jnt_R_strings2", 0.5, 0.06, 1.2, 55.0, 20.0, 55.0],
	["Jnt_R_strings3", 0.4, 0.06, 1.4, 55.0, 20.0, 55.0],
	["Jnt_L_Shoulder4", 0.3, 0.05, 1.6, 60.0, 20.0, 60.0],  # Last bone in R string chain
]

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
	call_deferred("_setup_gaze_debug")
	call_deferred("_setup_spring_bones")
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
	# F3 = debug gaze: Tama follows mouse cursor + visual debug
	if event is InputEventKey and event.pressed and event.keycode == KEY_F3:
		_debug_gaze_mouse = !_debug_gaze_mouse
		if _debug_gaze_mouse:
			print("👀 [DEBUG] Gaze → MOUSE FOLLOW ON")
			_show_status_indicator("👀 Debug Gaze: ON (F3)", Color(1, 0.8, 0.2))
			# Show debug viz
			if _debug_sphere: _debug_sphere.visible = true
			if _debug_line_node: _debug_line_node.visible = true
			if _debug_depth_node: _debug_depth_node.visible = true
		else:
			print("👀 [DEBUG] Gaze → MOUSE FOLLOW OFF")
			set_gaze(GazeTarget.NEUTRAL, 2.0)
			_hide_status_indicator()
			# Hide debug viz
			if _debug_sphere: _debug_sphere.visible = false
			if _debug_line_node: _debug_line_node.visible = false
			if _debug_depth_node: _debug_depth_node.visible = false
	# F4 = debug eye follow: eyes track mouse cursor
	if event is InputEventKey and event.pressed and event.keycode == KEY_F4:
		_debug_eye_follow = !_debug_eye_follow
		_eye_follow_active = _debug_eye_follow
		if _debug_eye_follow:
			print("👁️ [DEBUG] Eye Follow → ON")
			_show_status_indicator("👁️ Eye Follow: ON (F4)", Color(0.5, 1.0, 0.8))
		else:
			print("👁️ [DEBUG] Eye Follow → OFF")
			_hide_status_indicator()
			# Reset eyes to center
			_eye_target_h = 0.0
			_eye_target_v = 0.0
	# F5 = debug collider spheres: show/hide collision volumes
	if event is InputEventKey and event.pressed and event.keycode == KEY_F5:
		_debug_colliders = !_debug_colliders
		if _debug_colliders:
			print("🛡️ [DEBUG] Colliders ON — +/- = resize, Arrows = move offset, Tab = switch collider")
			_show_status_indicator("🛡️ Colliders: ON (F5)", Color(0.3, 1.0, 0.5))
			_create_debug_collider_meshes()
		else:
			print("🛡️ [DEBUG] Colliders OFF")
			_hide_status_indicator()
			_remove_debug_collider_meshes()

	# Interactive collider tuning (only when F5 debug is active)
	if _debug_colliders and event is InputEventKey and event.pressed:
		var changed := false
		var sel := _debug_selected_collider
		if sel >= 0 and sel < _spring_colliders.size():
			var col = _spring_colliders[sel]
			match event.keycode:
				KEY_EQUAL, KEY_KP_ADD:  # + key = bigger
					col["radius"] += 0.01
					changed = true
				KEY_MINUS, KEY_KP_SUBTRACT:  # - key = smaller
					col["radius"] = maxf(0.01, col["radius"] - 0.01)
					changed = true
				KEY_UP:  # Move offset up (Y+)
					col["offset"].y += 0.01
					changed = true
				KEY_DOWN:  # Move offset down (Y-)
					col["offset"].y -= 0.01
					changed = true
				KEY_RIGHT:  # Move offset forward (Z+)
					col["offset"].z += 0.01
					changed = true
				KEY_LEFT:  # Move offset backward (Z-)
					col["offset"].z -= 0.01
					changed = true
				KEY_TAB:  # Switch collider
					_debug_selected_collider = (_debug_selected_collider + 1) % _spring_colliders.size()
					var new_name = SPRING_COLLIDER_CONFIGS[_debug_selected_collider][0]
					print("🛡️ Selected: [%d] %s" % [_debug_selected_collider, new_name])
					_show_status_indicator("🛡️ [%s] r=%.3f" % [new_name, _spring_colliders[_debug_selected_collider]["radius"]], Color(0.3, 1.0, 0.5))
			if changed:
				# Update debug mesh size
				_remove_debug_collider_meshes()
				_create_debug_collider_meshes()
				# Print all values so user can copy to code
				var name = SPRING_COLLIDER_CONFIGS[sel][0]
				var r = col["radius"]
				var o = col["offset"]
				print("🛡️ [%s] radius=%.3f offset=Vector3(%.3f, %.3f, %.3f)" % [name, r, o.x, o.y, o.z])
				_show_status_indicator("🛡️ [%s] r=%.3f" % [name, r], Color(0.3, 1.0, 0.5))

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
	if _debug_gaze_mouse and _gaze_active:
		# Track global mouse cursor → convert to 3D → look at it
		var mouse_pos = DisplayServer.mouse_get_position()
		var target_3d = _screen_to_world(float(mouse_pos.x), float(mouse_pos.y))
		_gaze_world_target = target_3d
		_look_at_world_point(target_3d, 8.0)
	_update_gaze(delta)

	# Eye follow system — blend shape eye tracking
	if _debug_eye_follow and _eye_follow_active:
		var mouse_pos = DisplayServer.mouse_get_position()
		_set_eye_target_from_screen(float(mouse_pos.x), float(mouse_pos.y))
	_update_eye_follow(delta)

	# Spring bones — secondary motion on hair & hoodie strings
	_update_spring_bones(delta)

	# Debug collider sphere positions (follow bones each frame)
	if _debug_colliders:
		_update_debug_collider_meshes()


func _create_debug_collider_meshes() -> void:
	"""Create translucent sphere meshes to visualize collision volumes."""
	_remove_debug_collider_meshes()
	for i in range(_spring_colliders.size()):
		var col = _spring_colliders[i]
		var sphere_mesh := SphereMesh.new()
		sphere_mesh.radius = col["radius"]
		sphere_mesh.height = col["radius"] * 2.0
		sphere_mesh.radial_segments = 16
		sphere_mesh.rings = 8

		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.2, 1.0, 0.3, 0.25)
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		sphere_mesh.material = mat

		var node := MeshInstance3D.new()
		node.mesh = sphere_mesh
		node.name = "DebugCollider_%d" % i
		add_child(node)
		_debug_collider_meshes.append(node)
	_update_debug_collider_meshes()

func _remove_debug_collider_meshes() -> void:
	"""Remove all debug collider sphere meshes."""
	for node in _debug_collider_meshes:
		if is_instance_valid(node):
			node.queue_free()
	_debug_collider_meshes.clear()

func _update_debug_collider_meshes() -> void:
	"""Move debug spheres to match current collider bone positions."""
	if _skeleton == null:
		return
	for i in range(mini(_spring_colliders.size(), _debug_collider_meshes.size())):
		var col = _spring_colliders[i]
		var node = _debug_collider_meshes[i]
		var col_global: Transform3D = _skeleton.global_transform * _skeleton.get_bone_global_pose(col["bone_idx"])
		var center: Vector3 = col_global.origin + col_global.basis * col["offset"]
		node.global_position = center
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
			_on_wall = true  # Will be on the wall until speech starts
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
			# If still on wall, get off first
			if _on_wall and phase == Phase.HELLO:
				_on_wall = false
				_play("OffThewall", false)
				phase = Phase.ACTIVE
				print("🧑 OffThewall: user parle, Tama se lève")
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
		_set_eyebrows(mood_name)
		return
	elif command == "VISEME":
		var shape = data.get("shape", "REST")
		var amp: float = data.get("amp", 0.5)
		var mouth_slot = VISEME_MAP.get(shape, "M0")
		# Track Tama speech
		if shape != "REST":
			# If on wall and speech starts → transition off the wall
			if conversation_active and _on_wall and phase == Phase.HELLO:
				_on_wall = false
				_play("OffThewall", false)
				phase = Phase.ACTIVE
				print("🧑 OffThewall: Tama se lève pour parler")
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
				# Conversation: Peek terminé → Idle_wall loop (elle attend la discussion)
				_on_wall = true
				_play("Idle_wall", true)
				phase = Phase.HELLO
			elif not intro_done:
				# Intro : Peek terminé → Idle_wall (loop tant qu'on attend les données)
				_play("Idle_wall", true)
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
		Phase.ACTIVE:
			# OffThewall just finished → chain into Idle loop
			if conversation_active and not _on_wall:
				_play("Idle", true)
				print("🧑 Idle: conversation en cours")
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
				# Eye follow blend shapes
				elif bs_name == "BS_LookLeft":
					_bs_look_left = bs_i
					_body_mesh = mesh_inst
					print("  👁️ BS_LookLeft found (index %d)" % bs_i)
				elif bs_name == "BS_LookRight":
					_bs_look_right = bs_i
					_body_mesh = mesh_inst
					print("  👁️ BS_LookRight found (index %d)" % bs_i)
				elif bs_name == "BS_LookUp":
					_bs_look_up = bs_i
					_body_mesh = mesh_inst
					print("  👁️ BS_LookUp found (index %d)" % bs_i)
				elif bs_name == "BS_LookDown":
					_bs_look_down = bs_i
					_body_mesh = mesh_inst
					print("  👁️ BS_LookDown found (index %d)" % bs_i)
				# Eyebrow blend shapes
				elif bs_name == "BS_Eyebrow_Question":
					_bs_eyebrow_question = bs_i
					_body_mesh = mesh_inst
					print("  🤨 BS_Eyebrow_Question found (index %d)" % bs_i)
				elif bs_name == "BS_Eyebrow_Sad":
					_bs_eyebrow_sad = bs_i
					_body_mesh = mesh_inst
					print("  😢 BS_Eyebrow_Sad found (index %d)" % bs_i)
				elif bs_name == "BS_Eyebrow_Angry":
					_bs_eyebrow_angry = bs_i
					_body_mesh = mesh_inst
					print("  😠 BS_Eyebrow_Angry found (index %d)" % bs_i)
				elif bs_name == "BS_Eyebrow_suprise":
					_bs_eyebrow_surprise = bs_i
					_body_mesh = mesh_inst
					print("  😲 BS_Eyebrow_suprise found (index %d)" % bs_i)
	for child in node.get_children():
		_scan_for_materials(child)

func _set_expression_slot(slot_type: String, slot: String) -> void:
	if slot_type == "eyes":
		_set_eyes(slot)
	elif slot_type == "mouth":
		_set_mouth(slot)

# How much to hide pupils (3D spheres) per eye slot. 0.0 = fully visible, 1.0 = fully hidden.
# Slots not listed default to 0.0 (visible).
const PUPIL_HIDE_AMOUNT = {
	"E1": 0.8,   # Plissés fort — mostly hidden
	"E2": 1.0,   # Fermés — fully hidden
	"E4": 1.0,   # Happy ^^^ — fully hidden
	"E6": 1.0,   # Semi-closed (blink) — fully hidden
	"E7": 0.5,   # Plissés léger — half hidden
	# E0, E3, E5, E8: pupils fully visible (not listed = 0.0)
}

func _set_eyes(slot: String) -> void:
	_current_eye_slot = slot
	_apply_eye_offset(slot)
	# Set pupil visibility based on how much the expression covers them
	var hide_val: float = PUPIL_HIDE_AMOUNT.get(slot, 0.0)
	_set_pupil_hide(hide_val)

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

func _set_eyebrows(mood: String) -> void:
	"""Set eyebrow blend shapes based on mood. Resets all then applies the active one."""
	if _body_mesh == null:
		return
	# Reset all eyebrows to 0
	if _bs_eyebrow_question >= 0:
		_body_mesh.set_blend_shape_value(_bs_eyebrow_question, 0.0)
	if _bs_eyebrow_sad >= 0:
		_body_mesh.set_blend_shape_value(_bs_eyebrow_sad, 0.0)
	if _bs_eyebrow_angry >= 0:
		_body_mesh.set_blend_shape_value(_bs_eyebrow_angry, 0.0)
	if _bs_eyebrow_surprise >= 0:
		_body_mesh.set_blend_shape_value(_bs_eyebrow_surprise, 0.0)
	# Apply mood's eyebrow
	var eyebrow_map = MOOD_EYEBROWS.get(mood, {})
	for key in eyebrow_map:
		var val: float = eyebrow_map[key]
		match key:
			"question":
				if _bs_eyebrow_question >= 0:
					_body_mesh.set_blend_shape_value(_bs_eyebrow_question, val)
			"sad":
				if _bs_eyebrow_sad >= 0:
					_body_mesh.set_blend_shape_value(_bs_eyebrow_sad, val)
			"angry":
				if _bs_eyebrow_angry >= 0:
					_body_mesh.set_blend_shape_value(_bs_eyebrow_angry, val)
			"surprise":
				if _bs_eyebrow_surprise >= 0:
					_body_mesh.set_blend_shape_value(_bs_eyebrow_surprise, val)

# ─── Blink System ────────────────────────────────────────
func _set_pupils_visible(visible: bool) -> void:
	if _body_mesh == null:
		return
	var val: float = 0.0 if visible else 1.0
	if _bs_hide_left_eye >= 0:
		_body_mesh.set_blend_shape_value(_bs_hide_left_eye, val)
	if _bs_hide_right_eye >= 0:
		_body_mesh.set_blend_shape_value(_bs_hide_right_eye, val)

func _set_pupil_hide(amount: float) -> void:
	"""Set pupil hide amount: 0.0 = fully visible, 1.0 = fully hidden."""
	if _body_mesh == null:
		return
	var val: float = clampf(amount, 0.0, 1.0)
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


# ─── Eye Follow System (Blend Shape) ────────────────────
func _set_eye_target_from_screen(screen_x: float, screen_y: float) -> void:
	"""Convert screen mouse position to eye target direction (-1..+1)."""
	var win_pos := DisplayServer.window_get_position()
	var win_size := DisplayServer.window_get_size()

	# Tama's eye center on screen (approximate: center-top of Godot window)
	var eye_sx: float = float(win_pos.x) + float(win_size.x) * 0.5
	var eye_sy: float = float(win_pos.y) + float(win_size.y) * 0.35

	# Delta from eye center to mouse
	var dx: float = screen_x - eye_sx
	var dy: float = screen_y - eye_sy

	# Normalize by a reference distance (half screen width)
	var screen_w: float = float(DisplayServer.screen_get_size().x)
	var ref: float = screen_w * 0.4

	# H: negative = mouse to left of Tama, positive = to right
	# V: negative = mouse above Tama, positive = below
	_eye_target_h = clampf(dx / ref, -1.0, 1.0)
	_eye_target_v = clampf(dy / ref, -1.0, 1.0)

func _set_eye_look(h: float, v: float) -> void:
	"""Public API: set eye direction. h: -1=left +1=right, v: -1=up +1=down."""
	_eye_target_h = clampf(h, -1.0, 1.0)
	_eye_target_v = clampf(v, -1.0, 1.0)
	_eye_follow_active = true

func _update_eye_follow(delta: float) -> void:
	"""Saccadic eye movement — snaps between fixation points like real eyes."""
	if _body_mesh == null:
		return

	if _eye_follow_active:
		# Saccade: snap to target at intervals (not every frame)
		_eye_saccade_timer += delta
		if _eye_saccade_timer >= EYE_SACCADE_INTERVAL:
			_eye_saccade_timer = 0.0
			# Only snap if target has moved enough (dead zone prevents jitter)
			var dh: float = absf(_eye_target_h - _eye_follow_h)
			var dv: float = absf(_eye_target_v - _eye_follow_v)
			if dh > EYE_SACCADE_THRESHOLD or dv > EYE_SACCADE_THRESHOLD:
				_eye_follow_h = _eye_target_h
				_eye_follow_v = _eye_target_v
	else:
		# Not active → smoothly return eyes to center
		var t: float = clampf(EYE_RETURN_SPEED * delta, 0.0, 1.0)
		_eye_follow_h = lerpf(_eye_follow_h, 0.0, t)
		_eye_follow_v = lerpf(_eye_follow_v, 0.0, t)

	# Apply blend shapes (only one direction per axis is non-zero)
	# Compensate for head gaze: if head is already rotated toward target,
	# reduce eye movement — they share the workload naturally
	var head_comp: float = 1.0 - (_gaze_blend * 0.5)  # 1.0 → 0.5 as head engages
	var h: float = _eye_follow_h * head_comp
	var v: float = _eye_follow_v * head_comp

	# Horizontal: swapped because Tama faces the user (mirrored)
	if _bs_look_left >= 0:
		_body_mesh.set_blend_shape_value(_bs_look_left, clampf(h, 0.0, 1.0))
	if _bs_look_right >= 0:
		_body_mesh.set_blend_shape_value(_bs_look_right, clampf(-h, 0.0, 1.0))
	# Vertical
	if _bs_look_up >= 0:
		_body_mesh.set_blend_shape_value(_bs_look_up, clampf(-v, 0.0, 1.0))
	if _bs_look_down >= 0:
		_body_mesh.set_blend_shape_value(_bs_look_down, clampf(v, 0.0, 1.0))

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

	# Log bone discovery
	if _head_bone_idx >= 0:
		print("\ud83d\udc40 Gaze: Head bone [%d] '%s'" % [_head_bone_idx, _skeleton.get_bone_name(_head_bone_idx)])
	if _neck_bone_idx >= 0:
		print("\ud83d\udc40 Gaze: Neck bone [%d] '%s'" % [_neck_bone_idx, _skeleton.get_bone_name(_neck_bone_idx)])

	_gaze_active = _head_bone_idx >= 0 and _camera != null
	if _gaze_active:
		print("\u2705 Gaze system ready (additive post-process)!")
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

# Max rotation angles (degrees) — prevent neck-breaking
const GAZE_MAX_YAW: float = 40.0   # Left/right
const GAZE_MAX_PITCH: float = 45.0  # Up/down (increased for more range)

# Constant pitch offset (degrees) to compensate for camera–head height mismatch.
# Positive = tilts gaze upward (counters "looking down" bias).
# Adjust visually: if head looks too high, make this MORE NEGATIVE; too low, MORE POSITIVE.
const GAZE_PITCH_OFFSET_DEG: float = -20.0

# Preset targets → 3D world offsets from head (X=right, Y=up, Z=toward camera)
# These are relative to the head bone position
var GAZE_PRESET_OFFSETS = {
	GazeTarget.USER: Vector3(0, 0.1, 2.0),            # Straight at camera, slightly up
	GazeTarget.SCREEN_CENTER: Vector3(-1.5, 0, 2.0),   # Left toward screen center
	GazeTarget.SCREEN_TOP: Vector3(-1.5, 0.8, 2.0),    # Left + up
	GazeTarget.SCREEN_BOTTOM: Vector3(-1.5, -0.5, 2.0),# Left + down
	GazeTarget.OTHER_MONITOR: Vector3(3.0, 0, 2.0),    # Far right (second monitor)
	GazeTarget.BOOK: Vector3(-0.3, -0.8, 0.5),         # Down in front
	GazeTarget.AWAY: Vector3(2.0, 0.2, -0.5),          # Behind to the right
}

func set_gaze(target: GazeTarget, speed: float = 5.0) -> void:
	"""Look at a named preset target. NEUTRAL = fade gaze out (pure animation)."""
	if not _gaze_active:
		return
	_gaze_lerp_speed = speed
	if target == GazeTarget.NEUTRAL:
		_gaze_target_head = Quaternion.IDENTITY
		_gaze_target_neck = Quaternion.IDENTITY
		_gaze_blend_target = 0.0
	else:
		var head_pos = _get_head_world_pos()
		var offset = GAZE_PRESET_OFFSETS.get(target, Vector3(0, 0, 2))
		var target_point = head_pos + offset
		_gaze_world_target = target_point
		_look_at_world_point(target_point, speed)

# ─── Screen → 3D World Conversion (Orthographic Camera) ──────
func _screen_to_world(screen_x: float, screen_y: float) -> Vector3:
	"""Convert desktop screen pixel coordinates to a 3D world point.
	Uses the orthographic camera's linear projection extended to the full screen."""
	var win_pos := DisplayServer.window_get_position()
	var win_size := DisplayServer.window_get_size()
	# Convert global screen coords to viewport-local coords
	# (can be negative or > viewport — that's fine for ortho projection!)
	var vp_x: float = screen_x - float(win_pos.x)
	var vp_y: float = screen_y - float(win_pos.y)
	var vp_w: float = float(win_size.x)
	var vp_h: float = float(win_size.y)

	# Orthographic camera: linear mapping from viewport pixels to world units
	# Camera.size = full height of visible area in world units (KEEP_HEIGHT mode)
	var cam_pos := _camera.global_position
	var ortho_size: float = _camera.size  # e.g., 2.095
	var half_h: float = ortho_size / 2.0
	var aspect: float = vp_w / vp_h
	var half_w: float = half_h * aspect

	# Viewport pixel → world position (camera faces -Z)
	var world_x: float = cam_pos.x + ((vp_x / vp_w) - 0.5) * 2.0 * half_w
	var world_y: float = cam_pos.y + (0.5 - (vp_y / vp_h)) * 2.0 * half_h
	# Place the target on a plane between Tama and camera
	var world_z: float = cam_pos.z - 1.0

	return Vector3(world_x, world_y, world_z)

func _get_head_world_pos() -> Vector3:
	"""Get head bone position in world space."""
	if _head_bone_idx >= 0 and _skeleton != null:
		return _skeleton.global_transform * _skeleton.get_bone_global_pose(_head_bone_idx).origin
	return Vector3(0, 1.3, 0)  # Approximate fallback

# ─── Look-At via 3D Target Point ──────────────────────────────
func _look_at_world_point(target: Vector3, speed: float = 5.0) -> void:
	"""Compute gaze rotation so head looks at a 3D world point."""
	if not _gaze_active:
		return
	_gaze_lerp_speed = speed

	var head_pos: Vector3 = _get_head_world_pos()

	# Y compensation: _screen_to_world maps screen-center to camera.y in world,
	# but we want screen-center to correspond to head.y (so pitch=0 when mouse
	# is visually at Tama's eye level). Shift target Y up by the height difference.
	var corrected_target: Vector3 = target
	if _camera:
		corrected_target.y += (head_pos.y - _camera.global_position.y)
	var delta: Vector3 = corrected_target - head_pos

	# Yaw: horizontal angle (uses full XZ plane — correct for left/right)
	var yaw_rad: float = atan2(delta.x, delta.z)
	# Pitch: vertical angle in YZ plane ONLY — ignoring lateral distance X.
	# This prevents horizontal mouse movement from affecting head tilt.
	# (Old: asin(dir.y) on normalized 3D vector — pitch changed when X changed)
	var pitch_rad: float = atan2(delta.y, absf(delta.z))
	var yaw_deg: float = rad_to_deg(yaw_rad)
	var pitch_deg: float = rad_to_deg(pitch_rad) + GAZE_PITCH_OFFSET_DEG

	# -pitch_deg is required: the bone's Z-FORWARD rotation axis is inverted
	# relative to the geometric pitch, so the negation corrects up/down direction.
	_set_gaze_from_angles(yaw_deg, -pitch_deg, speed)

func set_gaze_at_screen_point(screen_x: float, screen_y: float, speed: float = 8.0) -> void:
	"""Map screen pixel coordinates to 3D world point and look there."""
	if not _gaze_active:
		return
	var target_3d = _screen_to_world(screen_x, screen_y)
	_gaze_world_target = target_3d
	_look_at_world_point(target_3d, speed)

func _set_gaze_from_angles(yaw_deg: float, pitch_deg: float, speed: float) -> void:
	"""Set gaze target from yaw/pitch angles in degrees."""
	_gaze_lerp_speed = speed

	# When eye follow is active, head shares the workload (does less)
	if _eye_follow_active:
		yaw_deg *= 0.5
		pitch_deg *= 0.5

	yaw_deg = clamp(yaw_deg, -GAZE_MAX_YAW, GAZE_MAX_YAW)
	pitch_deg = clamp(pitch_deg, -GAZE_MAX_PITCH, GAZE_MAX_PITCH)

	# Head gets 70%, Neck gets 30% (natural head-lead motion)
	var head_yaw = deg_to_rad(yaw_deg * 0.7)
	var head_pitch = deg_to_rad(pitch_deg * 0.7)
	var neck_yaw = deg_to_rad(yaw_deg * 0.3)
	var neck_pitch = deg_to_rad(pitch_deg * 0.3)

	# Build rotation quaternions:
	#   Yaw (turn head left/right) = rotate around local Y ✅
	#   Pitch (nod up/down) = rotate around local Z (NOT X — X is roll/tilt!)
	_gaze_target_head = Quaternion(Vector3.UP, head_yaw) * Quaternion(Vector3.FORWARD, head_pitch)
	_gaze_target_neck = Quaternion(Vector3.UP, neck_yaw) * Quaternion(Vector3.FORWARD, neck_pitch)
	_gaze_blend_target = 1.0

# ─── Debug Visualization ──────────────────────────────────────
func _setup_gaze_debug() -> void:
	"""Create visible debug helpers: sphere at target, lines from head."""
	# Sphere at target point (color changes: green=front, red=behind)
	_debug_sphere = MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.05
	sphere.height = 0.10
	_debug_sphere.mesh = sphere
	_debug_sphere_mat = StandardMaterial3D.new()
	_debug_sphere_mat.albedo_color = Color.GREEN
	_debug_sphere_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_debug_sphere_mat.no_depth_test = true  # Always visible (even behind Tama)
	_debug_sphere.material_override = _debug_sphere_mat
	add_child(_debug_sphere)
	_debug_sphere.visible = false

	# Yellow line: head → target (look-at direction)
	_debug_line_mesh = ImmediateMesh.new()
	_debug_line_node = MeshInstance3D.new()
	_debug_line_node.mesh = _debug_line_mesh
	var line_mat := StandardMaterial3D.new()
	line_mat.albedo_color = Color.YELLOW
	line_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	line_mat.no_depth_test = true
	_debug_line_node.material_override = line_mat
	add_child(_debug_line_node)
	_debug_line_node.visible = false

	# Cyan line: Z-depth indicator (head → straight forward to target's Z)
	_debug_depth_mesh = ImmediateMesh.new()
	_debug_depth_node = MeshInstance3D.new()
	_debug_depth_node.mesh = _debug_depth_mesh
	var depth_mat := StandardMaterial3D.new()
	depth_mat.albedo_color = Color.CYAN
	depth_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	depth_mat.no_depth_test = true
	_debug_depth_node.material_override = depth_mat
	add_child(_debug_depth_node)
	_debug_depth_node.visible = false

func _update_debug_viz(delta: float) -> void:
	"""Update debug sphere + lines + console prints."""
	if not _debug_gaze_mouse or _debug_sphere == null:
		return

	var head_pos = _get_head_world_pos()
	var target = _gaze_world_target

	# ─── Sphere: position + color based on depth ───
	_debug_sphere.global_position = target
	# Green = target is IN FRONT of Tama (Z > head Z, toward camera)
	# Red = target is BEHIND Tama
	if target.z > head_pos.z:
		_debug_sphere_mat.albedo_color = Color.GREEN  # In front ✔
	else:
		_debug_sphere_mat.albedo_color = Color.RED    # Behind ✖

	# ─── Yellow line: head → target (actual look direction) ───
	_debug_line_mesh.clear_surfaces()
	_debug_line_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	_debug_line_mesh.surface_add_vertex(head_pos)
	_debug_line_mesh.surface_add_vertex(target)
	_debug_line_mesh.surface_end()

	# ─── Cyan line: Z-depth indicator ───
	# Goes from head straight along Z to show how far in front/behind the target is
	_debug_depth_mesh.clear_surfaces()
	_debug_depth_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	_debug_depth_mesh.surface_add_vertex(head_pos)
	_debug_depth_mesh.surface_add_vertex(Vector3(head_pos.x, head_pos.y, target.z))
	_debug_depth_mesh.surface_end()

	# ─── Console print every 0.5s ───
	_debug_print_timer += delta
	if _debug_print_timer >= 0.5:
		_debug_print_timer = 0.0
		var z_dist = target.z - head_pos.z
		var z_label = "DEVANT" if z_dist > 0 else "DERRIERE"
		print("🔴 Target: (%.2f, %.2f, %.2f) | Head: (%.2f, %.2f, %.2f) | Z dist: %.2f (%s)" % [
			target.x, target.y, target.z,
			head_pos.x, head_pos.y, head_pos.z,
			z_dist, z_label
		])

func _update_gaze(delta: float) -> void:
	"""Gaze system — blends between animation's base rotation and gaze target."""
	if not _gaze_active or _skeleton == null:
		return

	# 0. Capture the animation's natural bone rotation ONCE (before gaze touches it)
	#    This is the "base" that blend=0 returns to (not IDENTITY/bind-pose).
	if not _gaze_base_captured:
		if _head_bone_idx >= 0:
			_head_base_rot = _skeleton.get_bone_pose_rotation(_head_bone_idx)
		if _neck_bone_idx >= 0:
			_neck_base_rot = _skeleton.get_bone_pose_rotation(_neck_bone_idx)
		_gaze_base_captured = true
		print("\ud83d\udc40 Gaze: captured animation base rotation (head=%s)" % str(_head_base_rot))

	# 1. Smooth blend weight (fade in/out)
	var blend_t: float = clampf(GAZE_BLEND_SPEED * delta, 0.0, 1.0)
	_gaze_blend = lerpf(_gaze_blend, _gaze_blend_target, blend_t)

	# 2. Slerp toward target rotation
	var slerp_t: float = clampf(_gaze_lerp_speed * delta, 0.0, 1.0)
	_gaze_delta_head = _gaze_delta_head.slerp(_gaze_target_head, slerp_t).normalized()
	_gaze_delta_neck = _gaze_delta_neck.slerp(_gaze_target_neck, slerp_t).normalized()

	# 3. Update debug visualization
	_update_debug_viz(delta)

	# 4. When blend ≈ 0, restore bone to animation base and stop
	if _gaze_blend < 0.005:
		# Ensure bone is at animation base (not stuck at some intermediate state)
		if _head_bone_idx >= 0:
			_skeleton.set_bone_pose_rotation(_head_bone_idx, _head_base_rot)
		if _neck_bone_idx >= 0:
			_skeleton.set_bone_pose_rotation(_neck_bone_idx, _neck_base_rot)
		return

	# 5. Blend between base rotation and base+gaze.
	#    base_rot → the animation's natural head position (no chin-up)
	#    base_rot * gaze_delta → gaze applied on top of animation
	if _head_bone_idx >= 0:
		var target_rot: Quaternion = (_head_base_rot * _gaze_delta_head).normalized()
		var final_rot: Quaternion = _head_base_rot.slerp(target_rot, _gaze_blend).normalized()
		_skeleton.set_bone_pose_rotation(_head_bone_idx, final_rot)
	if _neck_bone_idx >= 0:
		var target_rot: Quaternion = (_neck_base_rot * _gaze_delta_neck).normalized()
		var final_rot: Quaternion = _neck_base_rot.slerp(target_rot, _gaze_blend).normalized()
		_skeleton.set_bone_pose_rotation(_neck_bone_idx, final_rot)

# ─── Spring Bones System (Verlet Virtual-Tail) ──────────
func _setup_spring_bones() -> void:
	"""Configure spring bones using Verlet virtual-tail simulation."""
	if _skeleton == null:
		return

	_spring_bones.clear()
	for config in SPRING_BONE_CONFIGS:
		var bone_name: String = config[0]
		var idx: int = _skeleton.find_bone(bone_name)
		if idx < 0:
			print("⚠️ Spring bone '%s' not found" % bone_name)
			continue

		var parent_idx: int = _skeleton.get_bone_parent(idx)
		var base_rot: Quaternion = _skeleton.get_bone_pose_rotation(idx)

		# Get world transforms
		var bone_global: Transform3D = _skeleton.global_transform * _skeleton.get_bone_global_pose(idx)

		# Determine bone length and local axis by finding child bone
		var bone_length: float = 0.0
		var bone_local_dir: Vector3 = Vector3.ZERO

		for c in range(_skeleton.get_bone_count()):
			if _skeleton.get_bone_parent(c) == idx:
				var child_global: Transform3D = _skeleton.global_transform * _skeleton.get_bone_global_pose(c)
				var world_dir: Vector3 = child_global.origin - bone_global.origin
				var length: float = world_dir.length()
				if length > 0.001:
					bone_length = length
					bone_local_dir = (bone_global.basis.inverse() * world_dir.normalized()).normalized()
				break

		# If no child (leaf bone), assume the bone points along its local +Y axis.
		# In Godot 4 with Blender glTF imports, bones always point along +Y.
		if bone_length <= 0.001:
			bone_length = 0.06  # 6cm default for leaf tip
			bone_local_dir = Vector3.UP  # +Y axis

		# Initialize tail at rest position (bone tip in world space)
		var tail_pos: Vector3 = bone_global.origin + bone_global.basis * bone_local_dir * bone_length

		# Per-axis limits in radians (matching Blender Euler constraints)
		var limit_x: float = deg_to_rad(config[4]) if config.size() > 4 else deg_to_rad(45.0)
		var limit_y: float = deg_to_rad(config[5]) if config.size() > 5 else deg_to_rad(45.0)
		var limit_z: float = deg_to_rad(config[6]) if config.size() > 6 else deg_to_rad(45.0)

		var sb = {
			"idx": idx,
			"name": bone_name,
			"stiffness": config[1],
			"drag": config[2],
			"gravity": config[3],
			"limit_x": limit_x,
			"limit_y": limit_y,
			"limit_z": limit_z,
			"base_rot": base_rot,
			"bone_length": bone_length,
			"bone_local_dir": bone_local_dir,
			"tail_pos": tail_pos,
			"prev_tail_pos": tail_pos,
		}
		_spring_bones.append(sb)

	if _spring_bones.size() > 0:
		print("🌿 Spring bones: %d configured (Verlet virtual-tail)" % _spring_bones.size())

	# Setup collision spheres
	_spring_colliders.clear()
	for col_cfg in SPRING_COLLIDER_CONFIGS:
		var col_bone_name: String = col_cfg[0]
		var col_bone_idx: int = _skeleton.find_bone(col_bone_name)
		if col_bone_idx < 0:
			print("⚠️ Collider bone '%s' not found" % col_bone_name)
			continue
		_spring_colliders.append({
			"bone_idx": col_bone_idx,
			"offset": col_cfg[1],
			"radius": col_cfg[2],
		})
	if _spring_colliders.size() > 0:
		print("🛡️ Spring colliders: %d spheres" % _spring_colliders.size())

func _update_spring_bones(delta: float) -> void:
	"""Simulate virtual tail points with Verlet integration, then orient bones toward them."""
	if _skeleton == null or _spring_bones.is_empty():
		return

	var dt: float = minf(delta, 0.033)

	for sb in _spring_bones:
		var idx: int = sb["idx"]
		var parent_idx: int = _skeleton.get_bone_parent(idx)
		var base_rot: Quaternion = sb["base_rot"]
		var bone_length: float = sb["bone_length"]
		var bone_local_dir: Vector3 = sb["bone_local_dir"]

		# Parent transform (already includes spring mods for chain parents)
		var parent_global: Transform3D
		if parent_idx >= 0:
			parent_global = _skeleton.global_transform * _skeleton.get_bone_global_pose(parent_idx)
		else:
			parent_global = _skeleton.global_transform

		# Bone HEAD = pivot point in world space
		var bone_head: Vector3 = (_skeleton.global_transform * _skeleton.get_bone_global_pose(idx)).origin

		# Rest tail = where the tip WOULD be in rest pose
		# rest direction in world = parent_basis * base_rot_basis * bone_local_dir
		var rest_dir_world: Vector3 = (parent_global.basis * Basis(base_rot) * bone_local_dir).normalized()
		var rest_tail: Vector3 = bone_head + rest_dir_world * bone_length

		# Current and previous simulated tail positions
		var tail: Vector3 = sb["tail_pos"]
		var prev_tail: Vector3 = sb["prev_tail_pos"]

		# ─── Verlet Integration ───
		# 1) Inertia: velocity from previous frame, with drag
		var inertia: Vector3 = (tail - prev_tail) * (1.0 - sb["drag"])

		# 2) Stiffness: constant force pulling toward rest direction
		#    (VRM-style: force in rest direction, not toward rest position)
		var stiffness_force: Vector3 = rest_dir_world * sb["stiffness"] * dt

		# 3) Gravity: world-space downward pull
		var gravity_force: Vector3 = Vector3.DOWN * sb["gravity"] * dt

		# Step the tail position
		var new_tail: Vector3 = tail + inertia + stiffness_force + gravity_force

		# ─── Distance Constraint ───
		# Tail must stay exactly bone_length from bone_head (rigid bone)
		var to_tail: Vector3 = new_tail - bone_head
		if to_tail.length_squared() > 0.00001:
			new_tail = bone_head + to_tail.normalized() * bone_length
		else:
			new_tail = rest_tail  # Fallback to rest if degenerate

		# ─── Sphere Collision ───
		# Push tail out of body collision spheres
		for col in _spring_colliders:
			var col_global: Transform3D = _skeleton.global_transform * _skeleton.get_bone_global_pose(col["bone_idx"])
			var sphere_center: Vector3 = col_global.origin + col_global.basis * col["offset"]
			var sphere_radius: float = col["radius"]
			var diff: Vector3 = new_tail - sphere_center
			var dist: float = diff.length()
			if dist < sphere_radius and dist > 0.0001:
				# Push tail to sphere surface
				new_tail = sphere_center + diff.normalized() * sphere_radius
				# Re-apply distance constraint (keep bone length from head)
				var to_tail2: Vector3 = new_tail - bone_head
				if to_tail2.length_squared() > 0.00001:
					new_tail = bone_head + to_tail2.normalized() * bone_length

		# ─── Per-Axis Euler Constraint ───
		# Decompose the swing from rest→current into Euler angles,
		# clamp each axis independently, rebuild.
		var curr_dir: Vector3 = (new_tail - bone_head).normalized()
		var parent_inv_basis: Basis = parent_global.basis.inverse()
		var local_rest: Vector3 = (parent_inv_basis * rest_dir_world).normalized()
		var local_curr: Vector3 = (parent_inv_basis * curr_dir).normalized()

		# Build swing quaternion: rest_dir → curr_dir in parent local space
		var swing_axis: Vector3 = local_rest.cross(local_curr)
		var swing_quat: Quaternion = Quaternion.IDENTITY
		if swing_axis.length_squared() > 0.000001:
			swing_axis = swing_axis.normalized()
			var swing_angle: float = local_rest.angle_to(local_curr)
			swing_quat = Quaternion(swing_axis, swing_angle)

		# Decompose to Euler and clamp each axis
		var euler: Vector3 = swing_quat.get_euler()
		var clamped: bool = false
		var ex: float = clampf(euler.x, -sb["limit_x"], sb["limit_x"])
		var ey: float = clampf(euler.y, -sb["limit_y"], sb["limit_y"])
		var ez: float = clampf(euler.z, -sb["limit_z"], sb["limit_z"])
		if ex != euler.x or ey != euler.y or ez != euler.z:
			clamped = true
			var clamped_quat: Quaternion = Quaternion.from_euler(Vector3(ex, ey, ez))
			var clamped_dir_local: Vector3 = (clamped_quat * local_rest).normalized()
			var clamped_dir_world: Vector3 = (parent_global.basis * clamped_dir_local).normalized()
			new_tail = bone_head + clamped_dir_world * bone_length

		# Store for next frame
		sb["prev_tail_pos"] = tail
		sb["tail_pos"] = new_tail

		# ─── Compute Bone Rotation ───
		# Reuse local directions (updated if clamping occurred)
		var final_dir_world: Vector3 = (new_tail - bone_head).normalized()
		var local_final_dir: Vector3 = (parent_inv_basis * final_dir_world).normalized()

		# Rotation from rest to final direction
		var rot_axis: Vector3 = local_rest.cross(local_final_dir)
		if rot_axis.length_squared() > 0.000001:
			rot_axis = rot_axis.normalized()
			var rot_angle: float = local_rest.angle_to(local_final_dir)
			var swing: Quaternion = Quaternion(rot_axis, rot_angle)
			_skeleton.set_bone_pose_rotation(idx, (swing * base_rot).normalized())
		else:
			_skeleton.set_bone_pose_rotation(idx, base_rot)

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
