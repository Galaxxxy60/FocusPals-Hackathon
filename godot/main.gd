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

# ─── Tama Scale (camera zoom + window resize) ─────────
const _BASE_WIN_SIZE := Vector2i(400, 500)
var _tama_scale_pct: int = 100
var _base_cam_size: float = 0.0   # Stored from Camera3D at startup
var _base_cam_y: float = 0.0      # Camera Y position at startup
var _base_cam_x: float = 0.0      # Camera X position at startup

# ─── Animation State Machine ──────────────────────────────
# Tama is ALWAYS visible. At rest she loops Idle_wall (on the wall).
# ON_WALL (Idle_wall loop) → TRANSITION_OFF (OffTheWall forward) → ACTIVE (Suspicious/Angry/Idle)
# ACTIVE → TRANSITION_ON (OffTheWall reverse) → ON_WALL (Idle_wall loop)
# STRIKING: Strike_Base → Strike_Dab → freeze
enum Phase { ON_WALL, TRANSITION_OFF, ACTIVE, STRIKING, TRANSITION_ON }
var phase: int = Phase.ON_WALL
var _started: bool = false  # True after first Idle_wall is played
var conversation_active: bool = false  # True during casual chat (no deep work)
var _convo_engagement: int = 0  # Number of speech exchanges — triggers OffTheWall at threshold
const CONVO_ENGAGE_THRESHOLD: int = 3  # Back-and-forths before Tama gets off the wall
var current_anim: String = ""
var _anim_player: AnimationPlayer = null
var _prev_suspicion_tier: int = -1
var _last_anim_command_time: float = 0.0  # Timestamp of last Python anim command
const ANIM_COMMAND_COOLDOWN: float = 5.0  # Don't auto-anim if Python sent one recently

# ─── Strike Fire Sync (Jnt_R_Hand Scale) ──────────────────
# The magic hand (hand_animation.py) is synchronized with Tama's
# Strike animation via the RIGHT HAND BONE (Jnt_R_Hand) scale.
#
# HOW IT WORKS:
#   In Blender, Jnt_R_Hand has scale (0,0,0) by default (hand hidden).
#   At the EXACT frame where the magic hand should fire, keyframe
#   its scale to (0.1, 0.1, 0.1) — the hand appears AND fires.
#   Godot detects scale > 0 → sends STRIKE_FIRE to Python.
#
# HOW TO ADD A NEW STRIKE ANIMATION:
#   1. Create the animation in Blender (e.g. "Strike_Snap")
#   The hand bone rests at scale (1,1,1). During Strike animations,
#   the hand "bounces" by scaling above 1.0 — that's the fire signal.
#   Threshold is 1.05 to catch the exact moment the bounce starts.
const STRIKE_FIRE_SCALE_THRESHOLD: float = 1.05  # Hand bone rests at 1.0 — bounce goes above 1
var _strike_hand_bone_idx: int = -1  # Jnt_R_Hand, auto-discovered in _setup_gaze
var _strike_fire_sent: bool = false  # Prevent duplicate fires per strike
var _strike_frame_count: int = 0     # Frames elapsed since entering STRIKING (warm-up delay)

# Arm IK bones (auto-discovered in _setup_gaze)
var _arm1_bone_idx: int = -1   # Jnt_R_Arm1 (upper arm)
var _arm2_bone_idx: int = -1   # Jnt_R_Arm2 (forearm)

# ─── IMBA Mode (Super Saiyan Levels) ─────────────────────
# Level 0: Normal
# Level 1: White glasses (BS_WhiteGlasses)
# Level 2: (future — aura particles?)
# Level 3: (future — full glow?)
var _imba_level: int = 0
var _imba_blend: float = 0.0           # Current BS_WhiteGlasses blend value
var _bs_white_glasses: int = -1        # Blend shape index
var _imba_tween: Tween = null          # For smooth transitions

# Strike target coordinates from Python (tab/window close button position)
var _strike_target: Vector2i = Vector2i(-1, -1)  # -1 = use mouse fallback

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
	"calm": "E0", "curious": "E0", "amused": "E4", "proud": "E7",
	"suspicious": "E7", "surprised": "E3", "disappointed": "E7", "sarcastic": "E7",
	"annoyed": "E5", "angry": "E5", "furious": "E8",
}
const MOOD_MOUTH = {
	"calm": "M0", "curious": "M0", "amused": "M4", "proud": "M4",
	"suspicious": "M7", "surprised": "M1", "disappointed": "M5", "sarcastic": "M6",
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
	"surprised": {"surprise": 0.8},
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

# ─── Eye Follow (Blend Shapes: LookLeft/Right/Up/Down) ───
var _bs_look_left: int = -1
var _bs_look_right: int = -1
var _bs_look_up: int = -1
var _bs_look_down: int = -1
var _eye_follow_active: bool = false   # Master switch
var _debug_eye_follow: bool = false    # F4 debug toggle (mouse follow)
var _eye_follow_h: float = 0.0        # Current horizontal: -1=left, 0=center, +1=right
var _eye_follow_v: float = 0.0        # Current vertical: -1=down, 0=center, +1=up
var _eye_target_h: float = 0.0        # Target horizontal
var _eye_target_v: float = 0.0        # Target vertical
var _eye_saccade_timer: float = 0.0   # Timer between saccades
const EYE_SACCADE_INTERVAL: float = 0.08  # Snap every ~80ms (like real saccades)
const EYE_SACCADE_THRESHOLD: float = 0.03 # Dead zone: ignore tiny changes
const EYE_RETURN_SPEED: float = 8.0       # Speed to return to center when deactivated

# ─── Radial + Settings Menu ─────────────────────────────────
var radial_menu = null
const RadialMenuScript = preload("res://settings_radial.gd")
var settings_panel = null
const SettingsPanelScript = preload("res://settings_panel.gd")


# ─── UI Module (separate script) ───────────────────────
var _tama_ui: Node = null  # tama_ui.gd instance
var _gemini_status: String = "disconnected"

# ─── Headphones (visible when Tama can't hear/respond) ───
var _headphones_node: Node3D = null

# ─── User Speaking Acknowledgment ───
var _ack_audio_player: AudioStreamPlayer = null
var _ack_eye_timer: float = 0.0  # Countdown to restore eyes after ack
var _ack_gaze_timer: float = 0.0 # Countdown to restore head gaze after ack

# ─── Gaze System (post-process bone look-at) ───
var _skeleton: Skeleton3D = null
var _gaze_modifier: Node = null  # gaze_modifier.gd instance (SkeletonModifier3D)
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

# Base rotation capture now lives in gaze_modifier.gd (SkeletonModifier3D)

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

# ─── Spring Bones (separate module) ───────────────────────
var _spring_bones_node: Node3D = null  # spring_bones.gd instance

# ─── Animation Tree (separate module) ─────────────────────
var _anim_tree_module = null  # tama_anim_tree.gd instance


# ─── Screen Scan Glance (periodic "checking" look) ────────
var _scan_glance_timer: float = 0.0       # Countdown: when >0, head is turned
var _scan_glance_cooldown: float = 0.0    # Time until next glance is allowed
var _scan_eye_active: bool = false        # Bypass eye head-compensation during scan
const SCAN_GLANCE_DURATION: float = 1.8   # How long she looks at screen
const SCAN_GLANCE_MIN_CD: float = 8.0     # Min seconds between glances
const SCAN_GLANCE_MAX_CD: float = 15.0    # Max seconds between glances
var _suspicion_staring: bool = false       # True when staring at screen due to suspicion
var _pending_leave_wall: bool = false      # Queue leave-wall after reverse wall_talk

# ─── Post-animation delta (for deferred gaze/spring bones) ──
var _last_delta: float = 0.0

func _ready() -> void:
	_position_window()
	_connect_ws()
	_setup_radial_menu()
	_setup_expression_system()
	_setup_tama_ui()
	call_deferred("_setup_headphones")
	_setup_ack_audio()
	call_deferred("_setup_gaze")
	call_deferred("_setup_gaze_debug")
	call_deferred("_setup_spring_bones_module")
	call_deferred("_setup_anim_tree")
	# Start in Idle_wall — Tama is always visible
	call_deferred("_start_idle_wall")
	# Enable internal processing for eye follow blend shapes (not bone mods — those use SkeletonModifier3D)
	# process_priority=100: run AFTER AnimTree (default 0) so our blend shape writes override animation data.
	# Without this, AnimTree overwrites BS_LookLeft/Right every frame and eye follow is invisible.
	process_priority = 100
	set_process_internal(true)
	print("🥷 FocusPals Godot — En attente de connexion...")

func _start_idle_wall() -> void:
	_ensure_anim_player()
	# If AnimTree module is active, it handles idle_wall via its StateMachine
	if _anim_tree_module and _anim_tree_module._ready_ok:
		_started = true
		print("🧱 Tama démarre en Idle_wall (via AnimTree)")
		return
	_play("Idle_wall", true)
	phase = Phase.ON_WALL
	_started = true
	print("🧱 Tama démarre en Idle_wall")


func _setup_anim_tree() -> void:
	_ensure_anim_player()
	var tama = get_node_or_null("Tama")
	if not tama or not _anim_player:
		push_warning("🎬 Cannot setup AnimTree — missing Tama or AnimPlayer")
		return
	# Find skeleton if not yet found
	if not _skeleton:
		_skeleton = _find_skeleton(tama)
	_anim_tree_module = load("res://tama_anim_tree.gd").new()
	add_child(_anim_tree_module)
	var ok = _anim_tree_module.setup(tama, _anim_player, _skeleton)
	if ok:
		_anim_tree_module.state_changed.connect(_on_tree_state_changed)
		_anim_tree_module.strike_fire_point.connect(_on_tree_strike_fire)
		_anim_tree_module.strike_sequence_started.connect(_on_tree_strike_started)
		_anim_tree_module.off_wall_complete.connect(_on_tree_off_wall_done)
		print("🎬 AnimTree module wired OK")
	else:
		push_warning("🎬 AnimTree setup failed — falling back to legacy")
		_anim_tree_module.queue_free()
		_anim_tree_module = null


func _on_tree_state_changed(old_state: String, new_state: String) -> void:
	print("🎬 State: %s → %s" % [old_state, new_state])

	if old_state == "STRIKING":
		_deactivate_imba()

	if new_state == "STRIKING":
		_activate_imba(1)

	# ── Gaze follows animation state ──
	if new_state == "WALL_TALK":
		if _suspicion_staring:
			# Suspicion-triggered wall_talk — stare at screen with full side-eye
			set_gaze(GazeTarget.SCREEN_CENTER, 3.0)
			_set_eye_look(-1.0, -0.3)
			_scan_eye_active = true
		elif conversation_active:
			set_gaze(GazeTarget.USER, 4.0)
		else:
			set_gaze(GazeTarget.SCREEN_CENTER, 3.0)
	elif new_state == "ON_WALL" and old_state == "RETURNING_WALL":
		# Returned from wall_talk — check if we need to immediately leave
		if _pending_leave_wall:
			_pending_leave_wall = false
			_suspicion_staring = false
			# Small delay then leave wall for real
			var tier := _get_tier()
			if tier == 2:
				_anim_tree_module.set_standing_anim("angry")
			else:
				_anim_tree_module.set_standing_anim("suspicious")
		else:
			_suspicion_staring = false
			_scan_eye_active = false
			_set_eye_look(0.0, 0.0)
			set_gaze(GazeTarget.NEUTRAL, 2.0)
	elif new_state == "ON_WALL" and old_state == "WALL_TALK":
		_suspicion_staring = false
		_scan_eye_active = false
		_set_eye_look(0.0, 0.0)
		set_gaze(GazeTarget.NEUTRAL, 2.0)
	elif new_state == "OFF_SCREEN":
		# Tama left the screen — reset all gaze
		_suspicion_staring = false
		_scan_eye_active = false
		_set_eye_look(0.0, 0.0)
		set_gaze(GazeTarget.NEUTRAL, 1.0)


func _on_tree_strike_fire() -> void:
	# Spawn hand window + arm IK + notify Python (same as existing strike fire logic)
	if _gaze_modifier:
		var aim: Vector2i
		if _strike_target.x >= 0:
			aim = _strike_target
		else:
			aim = DisplayServer.mouse_get_position()
		var target_3d := _screen_to_arm_target(float(aim.x), float(aim.y))
		_gaze_modifier.arm_ik_target = target_3d
		_gaze_modifier.arm_ik_active = true
		_gaze_modifier.arm_ik_blend_target = 1.0
	_spawn_hand_window()
	print("🎯 STRIKE_FIRE (via AnimTree) — hand window + arm IK + close signal")
	if ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		ws.send_text(JSON.stringify({"command": "STRIKE_FIRE"}))


func _on_tree_strike_started() -> void:
	# Now handled directly by state_changed → STRIKING (timer-based)
	pass


func _on_tree_off_wall_done() -> void:
	print("🎬 Off wall complete — Tama is now standing")

func _setup_radial_menu() -> void:
	radial_menu = CanvasLayer.new()
	radial_menu.set_script(RadialMenuScript)
	add_child(radial_menu)
	radial_menu.action_triggered.connect(_on_radial_action)
	radial_menu.request_hide.connect(_on_radial_hide)
	settings_panel = CanvasLayer.new()
	settings_panel.set_script(SettingsPanelScript)
	add_child(settings_panel)
	settings_panel.mic_selected.connect(_on_mic_selected)
	settings_panel.panel_closed.connect(_on_settings_panel_closed)
	settings_panel.api_key_submitted.connect(_on_api_key_submitted)
	settings_panel.language_changed.connect(_on_language_changed)
	settings_panel.volume_changed.connect(_on_volume_changed)
	settings_panel.session_duration_changed.connect(_on_session_duration_changed)
	settings_panel.screen_share_toggled.connect(_on_screen_share_toggled)
	settings_panel.mic_toggled.connect(_on_mic_toggled)
	settings_panel.tama_scale_changed.connect(_on_tama_scale_changed)
	print("🎛️ Radial menu + Settings panel OK")


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
			print("👀 [DEBUG] _gaze_active=%s head_bone=%d neck_bone=%d" % [str(_gaze_active), _head_bone_idx, _neck_bone_idx])
			print("👀 [DEBUG] _skeleton=%s _camera=%s" % [str(_skeleton != null), str(_camera != null)])
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
	# F4 = debug eye follow: eyes track mouse via blend shapes
	if event is InputEventKey and event.pressed and event.keycode == KEY_F4:
		_debug_eye_follow = !_debug_eye_follow
		_eye_follow_active = _debug_eye_follow
		if _debug_eye_follow:
			_eye_target_h = 0.0
			_eye_target_v = 0.0
			print("👁️ [DEBUG] Eye Follow → ON (mouse)")
			_show_status_indicator("👁️ Eye Follow: ON (F4)", Color(0.2, 0.8, 1.0))
		else:
			print("👁️ [DEBUG] Eye Follow → OFF")
			_hide_status_indicator()
	# F6 = Force head rotation test (no gaze system, raw bone write)
	if event is InputEventKey and event.pressed and event.keycode == KEY_F6:
		if _skeleton and _head_bone_idx >= 0:
			var current = _skeleton.get_bone_pose_rotation(_head_bone_idx)
			var nudge = Quaternion(Vector3.UP, deg_to_rad(20.0))
			_skeleton.set_bone_pose_rotation(_head_bone_idx, current * nudge)
			print("🦴 [DEBUG] F6 → Head bone nudged +20° yaw (current: %s)" % str(current))
	# F7 = Debug Strike: play Strike_Base + launch Godot hand window → mouse cursor
	if event is InputEventKey and event.pressed and event.keycode == KEY_F7:
		print("🎯 [DEBUG] F7 → Strike + Hand Window + Arm IK")
		_play("Strike_Base", false)
		phase = Phase.ACTIVE
		_strike_fire_sent = true  # Prevent real fire system from also firing
		_activate_imba(1)  # IMBA level 1!
		# Activate arm IK pointing towards mouse
		if _gaze_modifier:
			var mouse := DisplayServer.mouse_get_position()
			var target_3d := _screen_to_arm_target(float(mouse.x), float(mouse.y))
			_gaze_modifier.arm_ik_target = target_3d
			_gaze_modifier.arm_ik_active = true
			_gaze_modifier.arm_ik_blend_target = 1.0
			print("💪 Arm IK target: %s" % str(target_3d))
		# Delay hand window spawn to sync with the hand "bounce" in Strike_Base
		get_tree().create_timer(0.6).timeout.connect(_spawn_hand_window)
	if _spring_bones_node:
		_spring_bones_node.handle_input(event)


# ─── Multi-Window Hand Animation ─────────────────────────────
var _hand_window: Window = null

func _spawn_hand_window() -> void:
	# Clean up any existing hand window
	if _hand_window and is_instance_valid(_hand_window):
		_hand_window.queue_free()
		_hand_window = null

	# ── Start position: Tama's hand bone ──
	var win_pos := DisplayServer.window_get_position()
	var win_size := DisplayServer.window_get_size()
	var start_x: int = win_pos.x + int(win_size.x * 0.5)
	var start_y: int = win_pos.y + int(win_size.y * 0.45)
	var used_bone := false
	if _strike_hand_bone_idx >= 0 and _skeleton != null and _camera != null:
		var bone_global := _skeleton.global_transform * _skeleton.get_bone_global_pose(_strike_hand_bone_idx)
		var bone_world_pos := bone_global.origin
		var screen_pos := _camera.unproject_position(bone_world_pos)
		# viewport coords → screen coords (just add window position)
		start_x = int(screen_pos.x) + win_pos.x
		start_y = int(screen_pos.y) + win_pos.y
		used_bone = true
		print("🪟   [BONE] viewport=(%.0f,%.0f) → screen=(%d,%d)" % [screen_pos.x, screen_pos.y, start_x, start_y])

	# ── Target: mouse cursor ──
	var mouse := DisplayServer.mouse_get_position()
	var src_label := "BONE" if used_bone else "FALLBACK"
	print("🪟   [%s] Start=(%d,%d) → Target=(%d,%d)" % [src_label, start_x, start_y, mouse.x, mouse.y])

	# ── Create window hidden (avoids white flash) ──
	_hand_window = Window.new()
	_hand_window.title = "TamaHand"
	_hand_window.size = Vector2i(120, 120)
	_hand_window.position = Vector2i(start_x - 60, start_y - 60)
	_hand_window.borderless = true
	_hand_window.transparent_bg = true
	_hand_window.always_on_top = true
	_hand_window.unfocusable = true
	_hand_window.transparent = true
	_hand_window.gui_embed_subwindows = false
	_hand_window.visible = false  # Hidden until transparency is ready

	var label := Label.new()
	label.text = "🖐️"
	label.add_theme_font_size_override("font_size", 64)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.set_anchors_preset(Control.PRESET_FULL_RECT)
	_hand_window.add_child(label)
	add_child(_hand_window)

	# Wait 2 frames for transparency to take effect, THEN show
	await get_tree().process_frame
	await get_tree().process_frame
	if not is_instance_valid(_hand_window):
		return
	_hand_window.visible = true  # Now transparent — safe to show

	# ── Animate ──
	# Target: tab/window close button from Python, or mouse fallback
	var aim: Vector2i
	if _strike_target.x >= 0:
		aim = _strike_target
	else:
		aim = mouse
	var target_pos := Vector2i(aim.x - 60, aim.y - 60)
	var tween := create_tween()
	tween.set_ease(Tween.EASE_IN_OUT)
	tween.set_trans(Tween.TRANS_CUBIC)
	tween.tween_property(_hand_window, "position", target_pos, 0.7)
	tween.tween_callback(func():
		if is_instance_valid(label):
			label.text = "👆"
	)
	tween.tween_interval(0.5)
	tween.tween_callback(func():
		if _hand_window and is_instance_valid(_hand_window):
			_hand_window.queue_free()
			_hand_window = null
		# Keep arm IK active — it fades out when animation changes
		# Start IMBA fade out after hand window disappears
		_deactivate_imba()
		# Reset strike target for next time
		_strike_target = Vector2i(-1, -1)
	)


# ─── IMBA Mode (Super Saiyan Power-Up) ──────────────────────
func _activate_imba(level: int) -> void:
	"""Power up! Activate IMBA visual effects instantly (1 or 0)."""
	if _bs_white_glasses < 0 or _body_mesh == null:
		return
	_imba_level = level
	if _imba_tween and _imba_tween.is_valid():
		_imba_tween.kill()

	print("🔥 IMBA LEVEL %d ACTIVATED! (Instant)" % level)
	if level >= 1:
		_set_imba_blend(1.0)

func _deactivate_imba() -> void:
	"""Power down — instant fade out."""
	if _bs_white_glasses < 0 or _body_mesh == null:
		return
	if _imba_level == 0:
		return

	print("🔥 IMBA mode off. (Instant)")
	_imba_level = 0
	if _imba_tween and _imba_tween.is_valid():
		_imba_tween.kill()
	_set_imba_blend(0.0)

func _set_imba_blend(value: float) -> void:
	"""Tween callback — update BS_WhiteGlasses blend shape."""
	_imba_blend = value
	if _body_mesh and _bs_white_glasses >= 0:
		_body_mesh.set_blend_shape_value(_bs_white_glasses, clampf(value, 0.0, 1.0))


func _on_radial_action(action_id: String) -> void:
	print("🎛️ Radial action: " + action_id)
	if action_id == "settings":
		if ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
			ws.send_text(JSON.stringify({"command": "GET_SETTINGS"}))
		return
	if action_id == "quit":
		_show_quit_confirmation()
		return
	if ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		var msg := JSON.stringify({"command": "MENU_ACTION", "action": action_id})
		ws.send_text(msg)

func _on_radial_hide() -> void:
	if settings_panel and settings_panel.is_open:
		return
	if _quit_layer:
		return  # Don't re-enable click-through — quit dialog needs clicks
	_safe_restore_passthrough()
	if ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		ws.send_text(JSON.stringify({"command": "HIDE_RADIAL"}))

var _quit_layer: CanvasLayer = null

func _show_quit_confirmation() -> void:
	if _quit_layer:
		return  # Already visible
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_MOUSE_PASSTHROUGH, false)

	_quit_layer = CanvasLayer.new()
	_quit_layer.layer = 200
	add_child(_quit_layer)

	# Full-screen click catcher (clicking outside = cancel)
	var bg := ColorRect.new()
	bg.color = Color(0, 0, 0, 0.01)  # Nearly invisible but captures clicks
	bg.anchor_right = 1.0
	bg.anchor_bottom = 1.0
	bg.mouse_filter = Control.MOUSE_FILTER_STOP
	bg.gui_input.connect(func(event: InputEvent):
		if event is InputEventMouseButton and event.pressed:
			_hide_quit_confirmation()
	)
	_quit_layer.add_child(bg)

	# Panel
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.09, 0.14, 0.95)
	style.border_color = Color(0.3, 0.35, 0.55, 0.5)
	style.set_border_width_all(1)
	style.set_corner_radius_all(12)
	style.set_content_margin_all(20)
	style.shadow_color = Color(0, 0, 0, 0.4)
	style.shadow_size = 8
	panel.add_theme_stylebox_override("panel", style)
	panel.custom_minimum_size = Vector2(220, 0)
	_quit_layer.add_child(panel)

	# Position center of viewport
	var vp := get_viewport().get_visible_rect().size
	panel.position = Vector2(vp.x / 2 - 110, vp.y / 2 - 50)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 14)
	panel.add_child(vbox)

	# Question
	var lbl := Label.new()
	lbl.text = "Tu veux vraiment\npartir ? 😿"
	lbl.add_theme_font_size_override("font_size", 14)
	lbl.add_theme_color_override("font_color", Color(0.9, 0.92, 1.0))
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(lbl)

	# Buttons row
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_child(row)

	# Oui button
	var btn_yes := Button.new()
	btn_yes.text = "  Oui  "
	btn_yes.add_theme_font_size_override("font_size", 13)
	var yes_style := StyleBoxFlat.new()
	yes_style.bg_color = Color(0.6, 0.2, 0.2, 0.8)
	yes_style.set_corner_radius_all(8)
	yes_style.set_content_margin_all(8)
	btn_yes.add_theme_stylebox_override("normal", yes_style)
	var yes_hover := StyleBoxFlat.new()
	yes_hover.bg_color = Color(0.8, 0.25, 0.25, 0.9)
	yes_hover.set_corner_radius_all(8)
	yes_hover.set_content_margin_all(8)
	btn_yes.add_theme_stylebox_override("hover", yes_hover)
	btn_yes.add_theme_color_override("font_color", Color(1, 0.9, 0.9))
	btn_yes.pressed.connect(_do_quit)
	row.add_child(btn_yes)

	# Non button
	var btn_no := Button.new()
	btn_no.text = "  Non  "
	btn_no.add_theme_font_size_override("font_size", 13)
	var no_style := StyleBoxFlat.new()
	no_style.bg_color = Color(0.15, 0.2, 0.35, 0.8)
	no_style.set_corner_radius_all(8)
	no_style.set_content_margin_all(8)
	btn_no.add_theme_stylebox_override("normal", no_style)
	var no_hover := StyleBoxFlat.new()
	no_hover.bg_color = Color(0.25, 0.35, 0.55, 0.9)
	no_hover.set_corner_radius_all(8)
	no_hover.set_content_margin_all(8)
	btn_no.add_theme_stylebox_override("hover", no_hover)
	btn_no.add_theme_color_override("font_color", Color(0.85, 0.9, 1.0))
	btn_no.pressed.connect(_hide_quit_confirmation)
	row.add_child(btn_no)

func _hide_quit_confirmation() -> void:
	if _quit_layer:
		_quit_layer.queue_free()
		_quit_layer = null
	_safe_restore_passthrough()
	# Tell Python to re-enable click-through via WinAPI
	if ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		ws.send_text(JSON.stringify({"command": "HIDE_RADIAL"}))

func _do_quit() -> void:
	_hide_quit_confirmation()
	if ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		ws.send_text(JSON.stringify({"command": "MENU_ACTION", "action": "quit"}))

func _on_mic_selected(mic_index: int) -> void:
	print("🎤 Micro sélectionné: " + str(mic_index))
	if ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		ws.send_text(JSON.stringify({"command": "SELECT_MIC", "index": mic_index}))

func _on_settings_panel_closed() -> void:
	_apply_tama_scale_full()
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

func _on_tama_scale_changed(scale_pct: int) -> void:
	_tama_scale_pct = scale_pct
	_apply_camera_zoom()  # Live preview for <= 100% (camera zoom), reset for > 100%
	# Window resize for > 100% happens on settings close (_apply_tama_scale_full)
	print("📐 Tama scale: %d%%" % scale_pct)
	if ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		ws.send_text(JSON.stringify({"command": "SET_TAMA_SCALE", "scale": scale_pct}))

func _on_screen_share_toggled(enabled: bool) -> void:
	var status = "ON" if enabled else "OFF"
	print("🖥️ Screen share toggled: " + status)
	if ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		ws.send_text(JSON.stringify({"command": "SET_SCREEN_SHARE", "enabled": enabled}))

func _on_mic_toggled(enabled: bool) -> void:
	var status = "ON" if enabled else "OFF"
	print("🎤 Microphone toggled: " + status)
	if ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		ws.send_text(JSON.stringify({"command": "SET_MIC_ALLOWED", "enabled": enabled}))

func _safe_restore_passthrough() -> void:
	if radial_menu and radial_menu.is_open:
		return
	if settings_panel and settings_panel.is_open:
		return
	if _quit_layer:
		return
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_MOUSE_PASSTHROUGH, true)

func _position_window() -> void:
	_reposition_bottom_right()
	call_deferred("_apply_passthrough")

func _reposition_bottom_right() -> void:
	## Anchor window to bottom-right of usable screen area (excludes taskbar)
	var usable := DisplayServer.screen_get_usable_rect()
	var win_size := DisplayServer.window_get_size()
	var x := usable.position.x + usable.size.x - win_size.x
	var y := usable.position.y + usable.size.y - win_size.y
	DisplayServer.window_set_position(Vector2i(x, y))

func _apply_camera_zoom() -> void:
	## Live preview: zoom camera while slider is dragged (CanvasLayers unaffected)
	if _camera == null or _base_cam_size <= 0:
		return
	var factor := float(_tama_scale_pct) / 100.0
	if factor >= 1.0:
		# Above 100%: keep camera at default (window resize happens on close)
		_camera.size = _base_cam_size
		_camera.position.y = _base_cam_y
		_camera.position.x = _base_cam_x
		return
	# Below 100%: zoom out camera for live preview
	var new_size := _base_cam_size / factor
	_camera.size = new_size
	var base_bottom := _base_cam_y - _base_cam_size / 2.0
	_camera.position.y = base_bottom + new_size / 2.0
	var aspect := float(_BASE_WIN_SIZE.x) / float(_BASE_WIN_SIZE.y)
	var base_right := _base_cam_x + _base_cam_size / 2.0 * aspect
	_camera.position.x = base_right - new_size / 2.0 * aspect

func _apply_tama_scale_full() -> void:
	## Apply final scale: camera zoom for ≤100%, window resize for >100%
	if _camera == null or _base_cam_size <= 0:
		return
	var factor := float(_tama_scale_pct) / 100.0
	if factor > 1.0:
		# Bigger Tama: enlarge window, reset camera to default
		var new_w := int(_BASE_WIN_SIZE.x * factor)
		var new_h := int(_BASE_WIN_SIZE.y * factor)
		DisplayServer.window_set_size(Vector2i(new_w, new_h))
		_camera.size = _base_cam_size
		_camera.position.y = _base_cam_y
	else:
		# Smaller/default Tama: window stays 400×500, camera zoomed out
		DisplayServer.window_set_size(_BASE_WIN_SIZE)
		if factor < 1.0:
			var new_size := _base_cam_size / factor
			_camera.size = new_size
			var base_bottom := _base_cam_y - _base_cam_size / 2.0
			_camera.position.y = base_bottom + new_size / 2.0
			var aspect := float(_BASE_WIN_SIZE.x) / float(_BASE_WIN_SIZE.y)
			var base_right := _base_cam_x + _base_cam_size / 2.0 * aspect
			_camera.position.x = base_right - new_size / 2.0 * aspect
		else:
			_camera.size = _base_cam_size
			_camera.position.y = _base_cam_y
			_camera.position.x = _base_cam_x
	call_deferred("_reposition_bottom_right")

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

	# UI overlays (status indicator + session arc)
	if _tama_ui:
		_tama_ui.update(delta)

	# Ack eye timer — restore eyes after acknowledgment
	if _ack_eye_timer > 0:
		_ack_eye_timer -= delta
		if _ack_eye_timer <= 0:
			# Restore to current mood eyes
			var mood_eye = MOOD_EYES.get(_current_mood, "E0")
			_set_expression_slot("eyes", mood_eye)
			# Also return eye follow to center
			_eye_follow_active = false

	# Ack gaze timer — return head to reading pose after acknowledgment
	if _ack_gaze_timer > 0:
		_ack_gaze_timer -= delta
		if _ack_gaze_timer <= 0:
			set_gaze(GazeTarget.NEUTRAL, 6.0)  # Snappy return to book

	# Scan glance timer — auto-return after glance duration
	if _scan_glance_cooldown > 0:
		_scan_glance_cooldown -= delta
	if _scan_glance_timer > 0:
		_scan_glance_timer -= delta
		if _scan_glance_timer <= 0 and not _suspicion_staring:
			# Glance over — smoothly return to book + eyes to center
			set_gaze(GazeTarget.NEUTRAL, 2.0)
			_set_eye_look(0.0, 0.0)
			_scan_eye_active = false

	# Sync gaze targets to modifier BEFORE it processes (modifier runs after AnimationPlayer)
	_sync_gaze_to_modifier()

	# ─── Strike Fire ──────────────────────────────────────────
	# Handled by AnimTree module (strike_fire_point signal → _on_tree_strike_fire)

	# Gaze + Spring bones delta stored for post-animation processing
	_last_delta = delta


func _notification(what: int) -> void:
	# INTERNAL_PROCESS: only eye follow (blend shapes — no bone conflict).
	# Gaze bone rotation + spring bones are now in gaze_modifier.gd (SkeletonModifier3D)
	# which processes AFTER AnimationPlayer automatically.
	if what == NOTIFICATION_INTERNAL_PROCESS:
		var delta = _last_delta

		# Eye follow — blend shape based eye movement
		if _debug_eye_follow and _eye_follow_active:
			var mouse_pos = DisplayServer.mouse_get_position()
			_set_eye_target_from_screen(float(mouse_pos.x), float(mouse_pos.y))
		_update_eye_follow(delta)

		# Enforce IMBA blend shape so AnimationTree doesn't clear it
		if _imba_level > 0:
			_set_imba_blend(_imba_blend)

		# Gaze debug mouse tracking — compute targets (actual bone write is in modifier)
		if _debug_gaze_mouse and _gaze_active:
			var mouse_pos2 = DisplayServer.mouse_get_position()
			var target_3d = _screen_to_world(float(mouse_pos2.x), float(mouse_pos2.y))
			_gaze_world_target = target_3d
			_look_at_world_point(target_3d, 8.0)
			# Immediate sync for mouse tracking (targets just computed)
			_sync_gaze_to_modifier()

# ─── Eye Follow (saccadic blend-shape eye movement) ──────
func _set_eye_target_from_screen(screen_x: float, screen_y: float) -> void:
	"""Convert screen mouse position to eye target direction (-1..+1)."""
	var win_pos := DisplayServer.window_get_position()
	var win_size := DisplayServer.window_get_size()
	# Tama's eye center on screen (approximate: center-top of Godot window)
	var eye_sx: float = float(win_pos.x) + float(win_size.x) * 0.5
	var eye_sy: float = float(win_pos.y) + float(win_size.y) * 0.35
	var dx: float = screen_x - eye_sx
	var dy: float = screen_y - eye_sy
	var screen_w: float = float(DisplayServer.screen_get_size().x)
	var ref: float = screen_w * 0.4
	_eye_target_h = clampf(dx / ref, -1.0, 1.0)
	_eye_target_v = clampf(dy / ref, -1.0, 1.0)

func _set_eye_look(h: float, v: float) -> void:
	"""Public API: set eye direction. h: -1=left +1=right, v: -1=up +1=down."""
	_eye_target_h = clampf(h, -1.0, 1.0)
	_eye_target_v = clampf(v, -1.0, 1.0)
	_eye_follow_active = true

func _update_eye_follow(delta: float) -> void:
	"""Smooth eye movement via blend shapes."""
	if _body_mesh == null:
		return
	if _eye_follow_active:
		# Smooth interpolation toward target (no saccade snapping)
		var t: float = clampf(8.0 * delta, 0.0, 1.0)
		_eye_follow_h = lerpf(_eye_follow_h, _eye_target_h, t)
		_eye_follow_v = lerpf(_eye_follow_v, _eye_target_v, t)
	else:
		var t: float = clampf(EYE_RETURN_SPEED * delta, 0.0, 1.0)
		_eye_follow_h = lerpf(_eye_follow_h, 0.0, t)
		_eye_follow_v = lerpf(_eye_follow_v, 0.0, t)
	# Compensate for head gaze: reduce eye movement as head turns
	# BUT during scan glance, bypass: we want the side-eye to stay crisp
	var head_comp: float = 1.0 if _scan_eye_active else (1.0 - (_gaze_blend * 0.5))
	var h: float = _eye_follow_h * head_comp
	var v: float = _eye_follow_v * head_comp
	# Horizontal: swapped because Tama faces the user (mirrored)
	if _bs_look_left >= 0:
		_body_mesh.set_blend_shape_value(_bs_look_left, clampf(h, 0.0, 1.0))
	if _bs_look_right >= 0:
		_body_mesh.set_blend_shape_value(_bs_look_right, clampf(-h, 0.0, 1.0))
	if _bs_look_up >= 0:
		_body_mesh.set_blend_shape_value(_bs_look_up, clampf(-v, 0.0, 1.0))
	if _bs_look_down >= 0:
		_body_mesh.set_blend_shape_value(_bs_look_down, clampf(v, 0.0, 1.0))

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
			# Tama walks in when session starts
			if _anim_tree_module and _anim_tree_module.is_off_screen():
				_anim_tree_module.walk_in()
		return
	elif command == "START_CONVERSATION":
		if not session_active and not conversation_active:
			conversation_active = true
			_convo_engagement = 0  # Reset engagement counter
			print("💬 Mode conversation — Tama arrive !")
			# Tama walks in for conversation
			if _anim_tree_module and _anim_tree_module.is_off_screen():
				_anim_tree_module.walk_in()
		return
	elif command == "END_CONVERSATION":
		if conversation_active:
			conversation_active = false
			set_gaze(GazeTarget.NEUTRAL, 2.0)  # Stop looking at user
			print("💬 Fin de conversation — Tama s'en va")
			if _anim_tree_module:
				_anim_tree_module.go_away()
		return
	elif command == "SHOW_RADIAL":
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
		var key_hint = data.get("key_hint", "")
		var lang = data.get("language", "fr")
		var tama_vol = data.get("tama_volume", 1.0)
		var session_duration = int(data.get("session_duration", 50))
		var api_usage = data.get("api_usage", {})
		var screen_share = data.get("screen_share_allowed", true)
		var mic_on = data.get("mic_allowed", true)
		var tama_scale = int(data.get("tama_scale", 100))
		print("⚙️ Settings: %d micros, selected: %d, API key: %s, valid: %s, lang: %s, duration: %d" % [mics.size(), selected, str(has_api_key), str(key_valid), lang, session_duration])
		if settings_panel:
			if radial_menu and radial_menu.is_open:
				radial_menu.close()
			settings_panel.show_settings(mics, selected, has_api_key, key_valid, lang, tama_vol, session_duration, api_usage, screen_share, mic_on, tama_scale, key_hint)
		return
	elif command == "API_KEY_UPDATED":
		var valid = data.get("valid", false)
		print("🔑 API key validation result: %s" % str(valid))
		if settings_panel:
			settings_panel.update_key_valid(valid)
		return
	elif command == "USER_SPEAKING":
		# Subtle acknowledgment — Tama looks at user
		if conversation_active:
			_convo_engagement += 1
			print("👀 User speaking — engagement #%d" % _convo_engagement)
		_on_user_speaking_ack()  # Always ack (conversation + deep work)
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
	elif command == "STRIKE_TARGET":
		# Python sends target coordinates (tab/window close button)
		var tx := int(data.get("x", -1))
		var ty := int(data.get("y", -1))
		_strike_target = Vector2i(tx, ty)
		print("🎯 STRIKE_TARGET received: (%d, %d)" % [tx, ty])
		return
	elif command == "TAMA_ANIM":
		var anim_name = data.get("anim", "")
		_last_anim_command_time = Time.get_unix_time_from_system()
		print("🎬 [ANIM CMD] " + anim_name)
		if _anim_tree_module:
			var key: String = str(anim_name).to_lower()
			if key in ["go_away", "bye"]:
				_anim_tree_module.go_away()
			elif key in ["idle_wall"]:
				_anim_tree_module.return_to_wall()
			elif key in ["walk_in"]:
				_anim_tree_module.walk_in()
			elif key in ["strike", "strike_base"]:
				_anim_tree_module.play_strike()
				_activate_imba(1)
			elif key in ["idle_wall_talk"]:
				if _anim_tree_module.is_on_wall():
					_anim_tree_module.play_wall_talk()
				else:
					# Already standing — can't wall_talk, fallback to idle
					_anim_tree_module.set_standing_anim("idle")
			elif key == "suspicious":
				_anim_tree_module.set_standing_anim("suspicious")
			elif key == "angry":
				_anim_tree_module.set_standing_anim("angry")
			else:
				_anim_tree_module.set_standing_anim("idle")
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
			# Stage 2: Confirmed contact — Tama looks at user fully (head turn)
			if not _is_speaking and conversation_active:
				set_gaze(GazeTarget.USER, 5.0)  # Full head turn toward user
				_ack_gaze_timer = 0.0  # Cancel ack timer — stay looking while talking
		if shape == "REST":
			_is_speaking = false
			# Return to mood-based mouth expression
			_set_mouth(_current_mouth_slot)
			_set_jaw_open(0.0)
			if conversation_active:
				# In conversation: return gaze to book after a short pause
				_ack_gaze_timer = 2.0  # Look at user 2s more, then back to book
			elif _anim_tree_module and _anim_tree_module.current_state == 2: # WALL_TALK
				# En mode WALL_TALK (sur le mur mais parle), elle maintient son regard !
				# Ne pas relâcher le regard dans le vide entre chaque mot de la phrase.
				pass
			else:
				set_gaze(GazeTarget.NEUTRAL, 2.0)
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
	elif command == "SCREEN_SCAN":
		# Tama just analyzed the screen — visually show she's looking
		var scan_s: float = data.get("suspicion", 0.0)
		# Only glance when on wall and not already engaged
		if _anim_tree_module and _anim_tree_module.is_on_wall() \
				and not _is_speaking:
			# Three look styles based on suspicion:
			# Eyes ALWAYS at full intensity — the primary visual cue
			# Only HEAD movement scales with suspicion level
			# ──────────────────────────────────────────────────────
			# SIDE-EYE (S<3): eyes dart to screen, head barely moves
			# APPUYÉ (S 3-5): eyes full + head turns noticeably
			# FULL STARE (S≥6): eyes locked + head fully turned
			# ──────────────────────────────────────────────────────
			var head_blend: float
			var look_duration: float
			var head_speed: float
			if scan_s < 3.0:
				# SIDE-EYE: eyes do ALL the work, head barely moves
				head_blend = 0.15
				look_duration = 1.5
				head_speed = 1.5
			elif scan_s < 6.0:
				# APPUYÉ: eyes full + head follows
				head_blend = 0.5
				look_duration = 2.2
				head_speed = 3.0
			else:
				# FULL STARE: everything maxed
				head_blend = 1.0
				look_duration = 2.8
				head_speed = 4.0
			# Head turn (subtle to full)
			set_gaze_subtle(GazeTarget.SCREEN_CENTER, head_speed, head_blend)
			# Eyes ALWAYS at full intensity toward screen
			_set_eye_look(-1.0, -0.3)
			_scan_eye_active = true
			_scan_glance_timer = look_duration
			# Reset cooldown so periodic glance doesn't fight
			_scan_glance_cooldown = SCAN_GLANCE_MAX_CD
		return
	elif command == "PLAY_STRIKE":
		if _anim_tree_module:
			print("🥊 PYTHON TRIGGERED STRIKE!")
			_anim_tree_module.play_strike()
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

	# ── Screen scan glance — periodic "I'm watching" head turn ──
	_try_scan_glance()


# ─── Screen Scan Glance ──────────────────────────────────
func _try_scan_glance() -> void:
	"""Periodically glance at the screen during deep work.
	Makes Tama feel alive — she 'checks' what you're doing."""
	if _scan_glance_cooldown > 0:
		return
	# Only glance when on the wall, idle, not talking, not already looking
	if not _anim_tree_module:
		return
	if not _anim_tree_module.is_on_wall():
		return
	if _anim_tree_module.current_state != 1:  # 1 = ON_WALL (not WALL_TALK etc)
		return
	if _gaze_blend > 0.1:  # Already gazing somewhere (ack, conversation, etc)
		return
	if _is_speaking:
		return

	# Trigger glance: head subtle + eyes full side-eye
	set_gaze_subtle(GazeTarget.SCREEN_CENTER, 2.0, 0.15)
	_set_eye_look(-1.0, -0.3)
	_scan_eye_active = true
	_scan_glance_timer = SCAN_GLANCE_DURATION
	# Reset cooldown so periodic glance doesn't fight
	_scan_glance_cooldown = randf_range(SCAN_GLANCE_MIN_CD, SCAN_GLANCE_MAX_CD)


func _get_tier() -> int:
	if suspicion_index >= 6.0: return 2  # ANGRY
	if suspicion_index >= 3.0: return 1  # SUSPICIOUS
	return 0                             # CALM → HIDDEN

# ─── Logique Normale (Post-Intro) ─────────────────────────
func _update_suspicion_anim() -> void:
	if not session_active or not _anim_tree_module:
		return
	if _anim_tree_module.is_transitioning():
		return
	var tier := _get_tier()
	if tier == _prev_suspicion_tier:
		return
	_prev_suspicion_tier = tier
	match tier:
		0:
			# CALM — back to book
			_suspicion_staring = false
			_pending_leave_wall = false
			if _anim_tree_module.current_state == 2:  # WALL_TALK
				_anim_tree_module.end_wall_talk()
			else:
				_anim_tree_module.return_to_wall()
		1:
			# SUSPICIOUS — lean in and STARE from wall (don't leave)
			if _anim_tree_module.current_state == 1:  # ON_WALL
				_suspicion_staring = true
				_anim_tree_module.play_wall_talk()
				# Gaze is set by _on_tree_state_changed when WALL_TALK fires
			elif _anim_tree_module.current_state == 4:  # STANDING (de-escalating)
				_suspicion_staring = false
				_anim_tree_module.return_to_wall()
		2:
			# ANGRY — leave wall for real
			if _anim_tree_module.current_state == 2:  # WALL_TALK (was staring)
				# Reverse wall_talk first, then leave
				_pending_leave_wall = true
				_anim_tree_module.end_wall_talk()
			elif _anim_tree_module.is_on_wall():
				_suspicion_staring = false
				_anim_tree_module.set_standing_anim("angry")
			else:
				_anim_tree_module.set_standing_anim("angry")

# ─── Callback quand une anim "play once" se termine ──────
# (Legacy — kept for F7 debug. AnimTree handles transitions internally.)
func _on_animation_finished(_anim_name: StringName) -> void:
	pass

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
	# Deactivate arm IK when leaving Strike animations
	if _gaze_modifier and not "strike" in real_name.to_lower():
		_gaze_modifier.arm_ik_blend_target = 0.0

# ─── Jouer une animation en reverse ──────────────────────
func _play_reverse(anim_name: String) -> void:
	_ensure_anim_player()
	if _anim_player == null:
		return
	var anims := _anim_player.get_animation_list()
	var real_name := _find_best_anim(anims, [anim_name])
	if real_name == "":
		push_warning("⚠️ Animation introuvable (reverse): " + anim_name)
		return
	current_anim = real_name
	var anim := _anim_player.get_animation(real_name)
	if anim:
		anim.loop_mode = Animation.LOOP_NONE
	# Play from end → start (negative speed)
	_anim_player.play(real_name, 0.2, -1.0, true)
	print("⏪ Playing reverse: " + real_name)

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
	# Pass 1: exact match (case-insensitive)
	for p in priorities:
		var p_lower := String(p).to_lower()
		for a in available_anims:
			if String(a).to_lower() == p_lower:
				return String(a)
	# Pass 2: substring match — handles GLB names like "F Strike_Base"
	for p in priorities:
		var p_lower := String(p).to_lower()
		for a in available_anims:
			var a_lower := String(a).to_lower()
			if a_lower != "eeee" and p_lower in a_lower:
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
			# ── Auto-override: duplicate + Unshaded for ALL materials ──
			var dup: StandardMaterial3D = std_mat.duplicate() as StandardMaterial3D
			dup.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			# Hair & glasses → Alpha Scissor for clean transparency
			var needs_alpha_scissor: bool = (
				"hair" in name_lower or "cheveux" in name_lower
				or "glass" in name_lower or "lunette" in name_lower
			)
			if needs_alpha_scissor:
				dup.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
				dup.alpha_scissor_threshold = 0.5
				print("  🔧 [%d] '%s' → Unshaded + Alpha Scissor" % [i, original_name])
			else:
				print("  🔧 [%d] '%s' → Unshaded" % [i, original_name])
			mesh_inst.set_surface_override_material(i, dup)
			# ── Identify special materials for expression system ──
			if "eye" in name_lower or "yeux" in name_lower:
				_eyes_material = dup
				print("  ✅ → EYES material (index %d)" % i)
			elif "mouth" in name_lower or "bouche" in name_lower:
				_mouth_material = dup
				print("  ✅ → MOUTH material (index %d)" % i)
		# Find blend shapes for pupil hiding + jaw
		if mesh_inst.mesh and mesh_inst.mesh is ArrayMesh:
			var arr_mesh: ArrayMesh = mesh_inst.mesh as ArrayMesh
			var bs_count: int = arr_mesh.get_blend_shape_count()
			if bs_count > 0:
				var all_names: Array = []
				for scan_i in range(bs_count):
					all_names.append(arr_mesh.get_blend_shape_name(scan_i))
				print("  🦴 ALL blend shapes (%d): %s" % [bs_count, str(all_names)])
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
				# Eye gaze blend shapes
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
				# IMBA mode
				elif bs_name == "BS_WhiteGlasses":
					_bs_white_glasses = bs_i
					_body_mesh = mesh_inst
					print("  🔥 BS_WhiteGlasses found (index %d) — IMBA ready!" % bs_i)
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
				# Restore pupil hide to match current expression (not always visible!)
				var hide_val: float = PUPIL_HIDE_AMOUNT.get(_current_eye_slot, 0.0)
				_set_pupil_hide(hide_val)
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
	# Only block the ack SOUND when Tama is speaking (avoid audio clash)
	# But ALWAYS set the gaze — user must see Tama react even during barge-in
	if _ack_audio_player and _ack_audio_player.stream and not _is_speaking:
		_ack_audio_player.play()
	# Change eyes to curious/attentive (E0 = wide eyes)
	_set_expression_slot("eyes", "E0")
	_ack_eye_timer = 2.5  # Restore eyes after 2.5 seconds
	# Stage 1: Eyes look toward user via blend shapes
	_set_eye_look(-0.5, -0.1)  # Look left + slightly up
	# Stage 1b: Subtle head glance toward user (bone-based)
	set_gaze_subtle(GazeTarget.USER, 5.0, 0.5)
	_ack_gaze_timer = 2.5  # Return head to reading pose after 2.5s
	print("👀 Ack: subtle glance → blend_target=%.2f" % _gaze_blend_target)

func set_gaze_subtle(target: GazeTarget, speed: float = 3.0, max_blend: float = 0.4) -> void:
	"""Like set_gaze but with limited blend — subtle glance instead of full head turn."""
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
		# Override blend target to partial (subtle glance)
		_gaze_blend_target = max_blend
	# Immediate sync to modifier (don't wait for next _process)
	_sync_gaze_to_modifier()

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
		# Store base values for Tama scale zoom
		_base_cam_size = _camera.size
		_base_cam_y = _camera.position.y
		_base_cam_x = _camera.position.x

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

	# Find Head, Neck, and Right Hand bones
	for i in range(_skeleton.get_bone_count()):
		var bname = _skeleton.get_bone_name(i).to_lower()
		if bname == "head":
			_head_bone_idx = i
		elif bname == "neck":
			_neck_bone_idx = i
		elif bname == "jnt_r_hand":
			_strike_hand_bone_idx = i

	# Also find arm bones for IK
	for i in range(_skeleton.get_bone_count()):
		var bname = _skeleton.get_bone_name(i).to_lower()
		if bname == "jnt_r_arm1":
			_arm1_bone_idx = i
		elif bname == "jnt_r_arm2":
			_arm2_bone_idx = i

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
	if _strike_hand_bone_idx < 0:
		for i in range(_skeleton.get_bone_count()):
			var bname = _skeleton.get_bone_name(i).to_lower()
			if "r_hand" in bname:
				_strike_hand_bone_idx = i
				break

	# Log bone discovery
	if _head_bone_idx >= 0:
		print("\ud83d\udc40 Gaze: Head bone [%d] '%s'" % [_head_bone_idx, _skeleton.get_bone_name(_head_bone_idx)])
	if _neck_bone_idx >= 0:
		print("\ud83d\udc40 Gaze: Neck bone [%d] '%s'" % [_neck_bone_idx, _skeleton.get_bone_name(_neck_bone_idx)])
	if _strike_hand_bone_idx >= 0:
		print("🎯 Strike hand bone [%d] '%s' — Strike Fire sync active!" % [_strike_hand_bone_idx, _skeleton.get_bone_name(_strike_hand_bone_idx)])
	else:
		print("⚠️ Jnt_R_Hand bone NOT FOUND — Strike Fire will use timeout fallback")
	if _arm1_bone_idx >= 0 and _arm2_bone_idx >= 0:
		print("💪 Arm IK bones: Arm1[%d] Arm2[%d] — procedural pointing ready!" % [_arm1_bone_idx, _arm2_bone_idx])
	else:
		print("⚠️ Arm IK bones NOT FOUND — pointing disabled")

	_gaze_active = _head_bone_idx >= 0 and _camera != null
	if _gaze_active:
		print("\u2705 Gaze system ready (SkeletonModifier3D post-process)!")
		# Create SkeletonModifier3D for post-animation bone modifications
		_setup_gaze_modifier()
	elif _camera == null:
		print("\u26a0\ufe0f Gaze: Camera3D not found — gaze disabled")

func _setup_gaze_modifier() -> void:
	"""Create a SkeletonModifier3D child of Skeleton3D for gaze bone mods.
	This runs AFTER AnimationPlayer — the official Godot 4.4+ solution."""
	var GazeModScript = load("res://gaze_modifier.gd")
	_gaze_modifier = GazeModScript.new()
	_gaze_modifier.name = "GazeModifier"
	_gaze_modifier.head_bone_idx = _head_bone_idx
	_gaze_modifier.neck_bone_idx = _neck_bone_idx
	# Arm IK bones
	_gaze_modifier.arm1_bone_idx = _arm1_bone_idx
	_gaze_modifier.arm2_bone_idx = _arm2_bone_idx
	_gaze_modifier.hand_bone_idx = _strike_hand_bone_idx
	# Attach debug viz callback
	_gaze_modifier.debug_callback = Callable(self, "_update_debug_viz")
	# Must be child of Skeleton3D for SkeletonModifier3D to work
	_skeleton.add_child(_gaze_modifier)
	print("✅ GazeModifier attached to Skeleton3D (post-animation bone mods)")

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
	GazeTarget.USER: Vector3(0, 1.5, 2.0),            # Up toward user (4th wall — head is down in Idle_wall)
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
	# Immediate sync to modifier (don't wait for next _process)
	_sync_gaze_to_modifier()

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

# ─── Screen → 3D Arm Target (for procedural pointing) ────────
func _screen_to_arm_target(screen_x: float, screen_y: float) -> Vector3:
	"""Convert screen coords to a 3D target for arm IK.
	Uses a simple direction approach: compute the direction on screen from
	Tama's center to the target, then map it to a 3D offset from the arm."""
	var win_pos := DisplayServer.window_get_position()
	var win_size := DisplayServer.window_get_size()

	# Use the arm bone's projected screen position as origin (not window center!)
	# This way "same level" = pointing horizontal, not upward
	var arm_screen_x: float = float(win_pos.x) + float(win_size.x) * 0.5
	var arm_screen_y: float = float(win_pos.y) + float(win_size.y) * 0.65  # Arm is ~65% down
	if _arm1_bone_idx >= 0 and _skeleton != null and _camera != null:
		var arm_world := (_skeleton.global_transform * _skeleton.get_bone_global_pose(_arm1_bone_idx)).origin
		var arm_viewport := _camera.unproject_position(arm_world)
		arm_screen_x = float(win_pos.x) + arm_viewport.x
		arm_screen_y = float(win_pos.y) + arm_viewport.y

	var dx: float = screen_x - arm_screen_x  # positive = right on screen
	var dy: float = -(screen_y - arm_screen_y)  # positive = up (screen Y inverted)

	# Normalize by PHYSICAL screen size (cm) using DPI
	# This makes pointing physically accurate regardless of screen size/resolution
	var dpi: int = DisplayServer.screen_get_dpi()
	if dpi <= 0:
		dpi = 96  # Fallback
	var px_per_cm: float = float(dpi) / 2.54  # DPI → pixels per cm
	var norm_dx: float = dx / px_per_cm  # Distance in real-world cm
	var norm_dy: float = dy / px_per_cm

	# Get right arm bone position in world space
	var arm_pos := Vector3(0, 1.2, 0)  # Fallback
	if _arm1_bone_idx >= 0 and _skeleton != null:
		arm_pos = (_skeleton.global_transform * _skeleton.get_bone_global_pose(_arm1_bone_idx)).origin

	# Map physical direction to world direction:
	# Ortho camera faces -Z. Screen-right = +X, Screen-left = -X
	# norm_dx/dy are now in CM — scale to reasonable 3D reach
	var scale: float = 0.1  # 1 cm on screen ≈ 0.1 world units of offset
	var reach_z: float = 1.5  # Forward depth component
	var target := arm_pos + Vector3(
		norm_dx * scale,    # Physical horizontal offset
		norm_dy * scale,    # Physical vertical offset
		-reach_z            # Slightly forward (into the screen)
	)

	print("💪 arm_target: %.1fcm × %.1fcm (dpi=%d) → %s" % [norm_dx, norm_dy, dpi, str(target)])
	return target

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
	"""Update debug sphere + lines whenever gaze is active (not just F3)."""
	if _debug_sphere == null:
		return

	# Auto-show/hide debug viz based on gaze activity
	var show_viz: bool = _gaze_blend > 0.01 or _debug_gaze_mouse
	if _debug_sphere:
		_debug_sphere.visible = show_viz
	if _debug_line_node:
		_debug_line_node.visible = show_viz
	if _debug_depth_node:
		_debug_depth_node.visible = show_viz
	if not show_viz:
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

	# ─── Console print (disabled — too noisy) ───
	_debug_print_timer += delta

# _post_animation_update() removed — SkeletonModifier3D handles this now.
# See gaze_modifier.gd → _process_modification_with_delta()

func _sync_gaze_to_modifier() -> void:
	"""Push gaze targets to the SkeletonModifier3D immediately.
	Called from set_gaze(), set_gaze_subtle(), and _process() so the modifier
	sees updated targets BEFORE it runs (modifier processes after AnimationPlayer)."""
	if not _gaze_active or _gaze_modifier == null:
		return

	# Push gaze state → modifier
	_gaze_modifier.gaze_active = _gaze_active
	_gaze_modifier.gaze_blend_target = _gaze_blend_target
	_gaze_modifier.gaze_target_head = _gaze_target_head
	_gaze_modifier.gaze_target_neck = _gaze_target_neck
	_gaze_modifier.gaze_lerp_speed = _gaze_lerp_speed

	# Read back blend state from modifier for eye compensation and debug
	_gaze_blend = _gaze_modifier.gaze_blend
	_gaze_delta_head = _gaze_modifier.gaze_delta_head
	_gaze_delta_neck = _gaze_modifier.gaze_delta_neck

# ─── Spring Bones Module Setup ─────────────────────────────
func _setup_spring_bones_module() -> void:
	if _skeleton == null:
		return
	var SpringBones = load("res://spring_bones.gd")
	_spring_bones_node = SpringBones.new()
	_spring_bones_node.name = "SpringBones"
	add_child(_spring_bones_node)
	_spring_bones_node.setup(_skeleton)
	# Register with the gaze modifier for post-animation timing
	if _gaze_modifier:
		_gaze_modifier.spring_bones_node = _spring_bones_node
		print("🌿 Spring bones registered with GazeModifier (post-anim timing)")


# ─── UI Module Setup ───────────────────────────────────
func _setup_tama_ui() -> void:
	var TamaUI = load("res://tama_ui.gd")
	_tama_ui = TamaUI.new()
	_tama_ui.name = "TamaUI"
	add_child(_tama_ui)
	_tama_ui.setup(self)

func _show_status_indicator(text: String, color: Color) -> void:
	if _tama_ui:
		_tama_ui.show_status(text, color)

func _hide_status_indicator() -> void:
	if _tama_ui:
		_tama_ui.hide_status()
