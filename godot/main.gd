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
var _break_reminder_was_active: bool = false

# ─── Tama Scale (camera zoom + window resize) ─────────
const _BASE_WIN_SIZE := Vector2i(400, 500)
var _tama_scale_pct: int = 100
var _base_cam_size: float = 0.0   # Stored from Camera3D at startup
var _base_cam_y: float = 0.0      # Camera Y position at startup
var _base_cam_x: float = 0.0      # Camera X position at startup

# ─── Animation State Machine ──────────────────────────────
# Tama is ALWAYS visible. At rest she loops Idle_wall (on the wall).
# All animation states are managed by tama_anim_tree.gd's StateMachine.
var _started: bool = false  # True after first Idle_wall is played
var conversation_active: bool = false  # True during casual chat (no deep work)
var _convo_engagement: int = 0  # Number of speech exchanges — triggers OffTheWall at threshold
const CONVO_ENGAGE_THRESHOLD: int = 3  # Back-and-forths before Tama gets off the wall
var _anim_player: AnimationPlayer = null
var _prev_suspicion_tier: int = 0  # Start at 0 (CALM) — prevents false tier-change at startup
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
var _strike_hand_bone_idx: int = -1  # Jnt_R_Hand, auto-discovered in _setup_gaze

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

# ─── Dynamic Subject Gaze ───
# Point of interest set by Python (e.g. a video playing, a browser tab).
# When >= 0, overrides SCREEN_CENTER gaze to look at this exact pixel.
var _subject_target: Vector2i = Vector2i(-1, -1)

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
	"E9": Vector3(0, 0.5, 0),         # A3: Happy Wink (clin d'œil complice)
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
	"happy_wink": "E9",
}
const MOOD_MOUTH = {
	"calm": "M0", "curious": "M0", "amused": "M4", "proud": "M4",
	"suspicious": "M7", "surprised": "M1", "disappointed": "M5", "sarcastic": "M6",
	"annoyed": "M5", "angry": "M5", "furious": "M8",
	"happy_wink": "M4",
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
	"happy_wink": {},
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

# ─── UI Window + Menus ───────────────────────────────────────
var _ui_window: Window = null           # Dedicated window for all UI menus
var radial_menu = null
const RadialMenuScript = preload("res://settings_radial.gd")
var settings_panel = null
const SettingsPanelScript = preload("res://settings_panel.gd")
var debug_tweaks = null
const DebugTweaksScript = preload("res://debug_tweaks.gd")


# ─── UI Module (separate script) ───────────────────────
var _tama_ui: Node = null  # tama_ui.gd instance
var _gemini_status: String = "disconnected"

# ─── Headphones (visible when Tama can't hear/respond) ───
var _headphones_node: Node3D = null

# ─── Glitch Effect (visual indicator when API is disconnected) ───
var _glitch_quad: MeshInstance3D = null   # Full-screen quad in front of camera
var _glitch_material: ShaderMaterial = null
var _glitch_intensity: float = 0.0       # Current intensity (smoothed)
var _glitch_target: float = 0.0          # Target intensity (0 or 1)
const GLITCH_FADE_IN_SPEED: float = 2.0  # How fast glitch appears
const GLITCH_FADE_OUT_SPEED: float = 4.0 # How fast glitch disappears
var _glitch_quitting: bool = false        # True during quit glitch sequence
const GLITCH_QUIT_MAX: float = 8.0        # Max intensity before closing
const GLITCH_QUIT_RAMP: float = 4.0       # Ramp speed (accelerates)

# ─── Teleport Arrival Glitch ───
const GLITCH_TELEPORT_START: float = 2.5      # Starting intensity (snappy, not heavy)
const GLITCH_TELEPORT_FADE_SPEED: float = 8.0  # Fast fade to 0 (~0.3s — DBZ instant transmission)
var _glitch_teleporting: bool = false        # True during teleport-in sequence

# ─── User Speaking Acknowledgment ───
var _ack_audio_player: AudioStreamPlayer = null
var _session_ding_player: AudioStreamPlayer = null
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

# ─── Attente synchronisation IA (entrée synchronisée au premier mot) ────
var _waiting_for_voice: bool = false
var _voice_timeout_timer: float = 0.0

# ─── Local Greeting Audio (instant "Salut !" fallback) ────
var _local_greeting_player: AudioStreamPlayer = null
var _has_local_greeting: bool = false  # True if tama_hello.wav was found

# (Post-animation delta removed — using get_process_delta_time() directly)

# ─── Mouse Dodge (move tama window when hovered) ───
const DODGE_HOVER_RADIUS: float = 200.0    # Distance (px) from Tama center to trigger dodge
const DODGE_COOLDOWN: float = 0.5          # Seconds before she can dodge/return again
var _dodge_active: bool = false             # True when Tama window is at dodge position
var _dodge_cooldown_timer: float = 3.0     # Start with grace period so Tama doesn't dodge on launch
var _dodge_departing: bool = false          # True during departure animation (glitch playing)
var _dodge_armed: bool = false             # Must be true before dodge can trigger (armed when mouse LEAVES area)

# ─── Tama Window (separate rendering window) ───
var _tama_window: Window = null
var _tama_cam: Camera3D = null              # Clone camera inside _tama_window
const TAMA_LAYER_BIT: int = 2              # Render layer 2 bitmask
var _init_done: bool = false                # True after all deferred setups complete

func _ready() -> void:
	# Prevent V-Sync stacking across multiple windows (kills FPS otherwise)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 60
	_setup_tama_layers()   # Set Tama meshes to layer 2 (before anything visual)
	_setup_window_pool()   # Pre-create tama + UI + hand windows
	_position_window()
	_connect_ws()
	_setup_radial_menu()
	_setup_expression_system()
	_setup_tama_ui()
	call_deferred("_setup_headphones")
	_setup_ack_audio()
	_setup_session_ding()
	_setup_greeting_audio()
	call_deferred("_setup_gaze")
	call_deferred("_setup_glitch_effect")  # After _setup_gaze (needs _camera)
	call_deferred("_sync_tama_camera")    # After _setup_gaze finds _camera
	call_deferred("_setup_gaze_debug")
	call_deferred("_setup_spring_bones_module")
	call_deferred("_setup_anim_tree")
	# Tama stays hidden at launch — _start_idle_wall() is called
	# only when Python sends START_SESSION or START_CONVERSATION
	# call_deferred("_start_idle_wall")
	# Mark init complete AFTER all deferred setups (prevents race condition
	# where Python sends START_SESSION before AnimTree is ready)
	call_deferred("_mark_init_done")
	# Enable internal processing for eye follow blend shapes (not bone mods — those use SkeletonModifier3D)
	# process_priority=100: run AFTER AnimTree (default 0) so our blend shape writes override animation data.
	# Without this, AnimTree overwrites BS_LookLeft/Right every frame and eye follow is invisible.
	process_priority = 100
	set_process_internal(true)
	print("🥷 FocusPals Godot — En attente de connexion...")

func _mark_init_done() -> void:
	_init_done = true
	print("✅ Init async terminée — prêt à écouter Python.")

# ─── Window Pool Setup ─────────────────────────────────────
func _setup_window_pool() -> void:
	"""Pre-create all floating windows at startup."""
	_setup_tama_window()
	_setup_ui_window()
	_hand_window = _init_pooled_emoji_window("TamaHand_Strike")
	_jarvis_hand = _init_pooled_emoji_window("TamaHand_Jarvis")
	print("🎱 Window pool ready: tama + ui + hand + jarvis")

func _setup_ui_window() -> void:
	"""Create a dedicated window for all UI menus (radial, settings, quit).
	Always visible but parked off-screen when inactive (avoids taskbar icon flash)."""
	_ui_window = Window.new()
	_ui_window.title = "TamaUI"
	_ui_window.size = _BASE_WIN_SIZE
	_ui_window.borderless = true
	_ui_window.transparent_bg = true
	_ui_window.transparent = true
	_ui_window.always_on_top = true
	_ui_window.unfocusable = false  # Must accept input for settings typing
	_ui_window.gui_embed_subwindows = false
	# Forward input so F1/F2 work even when UI window has focus
	_ui_window.window_input.connect(func(event: InputEvent):
		_unhandled_input(event)
	)
	add_child(_ui_window)
	# Park off-screen (always visible to avoid taskbar icon flash)
	_ui_window.position = Vector2i(-5000, -5000)
	print("🧱 UI Window created (parked off-screen)")

func _init_pooled_emoji_window(win_title: String) -> Window:
	"""Create a pooled transparent emoji window, parked off-screen."""
	var win := Window.new()
	win.title = win_title
	win.borderless = true
	win.transparent_bg = true
	win.always_on_top = true
	win.unfocusable = true
	win.transparent = true
	win.gui_embed_subwindows = false

	var label := Label.new()
	label.name = "EmojiLabel"
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.set_anchors_preset(Control.PRESET_FULL_RECT)
	win.add_child(label)

	add_child(win)
	win.set_flag(Window.FLAG_MOUSE_PASSTHROUGH, true)  # Clicks go through to desktop
	win.visible = false  # Hidden until needed (saves DWM compositing cost)
	return win

func _setup_tama_window() -> void:
	"""Create Tama's dedicated rendering window with SubViewport.
	Tama stays in the main scene tree (no reparent = no broken paths).
	The SubViewport shares the same world_3d and a clone camera renders Tama."""
	# ── Window ──
	_tama_window = Window.new()
	_tama_window.title = "TamaMain"
	_tama_window.size = _BASE_WIN_SIZE
	_tama_window.borderless = true
	_tama_window.transparent_bg = true
	_tama_window.transparent = true
	_tama_window.always_on_top = true
	_tama_window.unfocusable = true
	_tama_window.gui_embed_subwindows = false

	# Window IS a Viewport in Godot 4 — no need for SubViewport!
	if get_viewport():
		_tama_window.world_3d = get_viewport().world_3d

	# ── Camera clone (settings synced later via _sync_tama_camera) ──
	_tama_cam = Camera3D.new()
	_tama_cam.cull_mask = TAMA_LAYER_BIT  # Only see Tama (layer 2)
	_tama_window.add_child(_tama_cam)

	add_child(_tama_window)

	# Position at bottom-right BEFORE showing (avoid flash at 0,0)
	var usable := DisplayServer.screen_get_usable_rect()
	var x := usable.position.x + usable.size.x - _BASE_WIN_SIZE.x
	var y := usable.position.y + usable.size.y - _BASE_WIN_SIZE.y
	_tama_window.position = Vector2i(x, y)
	_tama_window.set_flag(Window.FLAG_MOUSE_PASSTHROUGH, true)  # Clicks go through to desktop
	_tama_window.visible = false  # Hidden at launch — revealed by START_SESSION/START_CONVERSATION

	# Hide main window — Tama renders in _tama_window now
	# Main window stays alive for script processing but is invisible
	DisplayServer.window_set_size(Vector2i(1, 1))
	DisplayServer.window_set_position(Vector2i(-100, -100))
	print("🪟 Tama window created (always visible) — main window hidden")

func _sync_tama_camera() -> void:
	"""Sync tama camera with main camera settings. Called deferred after _setup_gaze."""
	if not _camera or not _tama_cam:
		return
	_tama_cam.projection = _camera.projection
	_tama_cam.size = _camera.size
	_tama_cam.position = _camera.position
	_tama_cam.rotation = _camera.rotation
	_tama_cam.near = _camera.near
	_tama_cam.far = _camera.far
	# Also hide Tama from the main camera (she's only in _tama_window)
	_camera.cull_mask &= ~TAMA_LAYER_BIT
	print("🎥 Tama camera synced (projection=%d, size=%.2f)" % [_camera.projection, _camera.size])

func _setup_tama_layers() -> void:
	"""Set all Tama MeshInstance3D nodes to render layer 2 only.
	This allows the main camera to hide/show Tama via cull_mask toggle."""
	var tama_node = get_node_or_null("Tama")
	if not tama_node:
		push_warning("⚠️ Tama layers: Tama node not found")
		return
	_set_layers_recursive(tama_node, TAMA_LAYER_BIT)
	print("🎭 Tama render layers → layer 2 only")

func _set_layers_recursive(node: Node, layer_mask: int) -> void:
	"""Recursively set VisualInstance3D.layers on a node tree."""
	if node is VisualInstance3D:
		node.layers = layer_mask
	for child in node.get_children():
		_set_layers_recursive(child, layer_mask)

func _start_idle_wall() -> void:
	_ensure_anim_player()
	# AnimTree handles entrance via Hello → idle → idle_wall
	if _anim_tree_module and _anim_tree_module._ready_ok:
		_started = true
		_anim_tree_module.walk_in()  # Plays Hello (or WalkIn) → idle → idle_wall
		_last_anim_command_time = Time.get_unix_time_from_system()  # Protect Hello from suspicion override
		_dodge_cooldown_timer = 5.0  # Generous grace period for Hello anim
		_dodge_armed = false         # Force mouse to leave area first
		print("🧱 Tama entrance started (via AnimTree)")
		return
	# Fallback: direct AnimationPlayer (should rarely happen)
	if _anim_player:
		_anim_player.play("Idle_wall", 0.2)
	# Ensure Tama node is visible (AnimTree normally does this in walk_in/teleport_in
	# but the legacy fallback skipped it → Tama stayed invisible)
	var tama_node = get_node_or_null("Tama")
	if tama_node:
		tama_node.visible = true
	_started = true
	_last_anim_command_time = Time.get_unix_time_from_system()  # Protect from suspicion override
	_dodge_cooldown_timer = 5.0
	_dodge_armed = false
	print("🧱 Tama démarre en Idle_wall (legacy fallback)")


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
		# Fade out arm IK — AnimTree state changes don't auto-release IK
		# so we must explicitly release it here
		if _gaze_modifier:
			_gaze_modifier.arm_ik_blend_target = 0.0

	if new_state == "STRIKING":
		_activate_imba(1)

	# ── Gaze follows animation state ──
	if new_state == "WALL_TALK":
		if _suspicion_staring:
			# Suspicion-triggered wall_talk — stare at screen with full side-eye
			set_gaze(GazeTarget.SCREEN_CENTER, 3.0)
			_look_eyes_at_screen_center()
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
			_eye_follow_active = false
			set_gaze(GazeTarget.NEUTRAL, 2.0)
	elif new_state == "ON_WALL" and old_state == "WALL_TALK":
		_suspicion_staring = false
		_scan_eye_active = false
		_eye_follow_active = false
		set_gaze(GazeTarget.NEUTRAL, 2.0)
	# ── Ground sitting equivalents ──
	elif new_state == "GROUND_TALK":
		if _suspicion_staring:
			# Suspicion-triggered ground_talk — stare at screen
			set_gaze(GazeTarget.SCREEN_CENTER, 3.0)
			_look_eyes_at_screen_center()
			_scan_eye_active = true
		elif conversation_active:
			set_gaze(GazeTarget.USER, 4.0)
		else:
			set_gaze(GazeTarget.SCREEN_CENTER, 3.0)
	elif new_state == "ON_GROUND" and old_state == "SITTING_GROUND":
		# Just sat down OR returned from ground_talk (end_ground_talk → SITTING_GROUND → ON_GROUND)
		# Check if we need to stand up (anger queued during ground_talk)
		if _pending_leave_wall:
			_pending_leave_wall = false
			_suspicion_staring = false
			var tier := _get_tier()
			if tier >= 2:
				_anim_tree_module.set_standing_anim("angry")
			# If tier dropped below 2, just stay sitting
		else:
			_suspicion_staring = false
			_scan_eye_active = false
			_eye_follow_active = false
			set_gaze(GazeTarget.NEUTRAL, 2.0)
	elif new_state == "OFF_SCREEN":
		# Tama left the screen — reset all gaze
		_suspicion_staring = false
		_scan_eye_active = false
		_eye_follow_active = false
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
	print("🎬 Off wall/ground complete — Tama is now standing")
	if not _anim_tree_module or not _anim_tree_module.is_standing():
		return
	# If there's a queued action (go_away, strike, mood), DON'T override it
	# The queue will be processed by _on_sm_node_changed right after this signal
	if _anim_tree_module._queued_standing != "":
		print("🎬 Queued action '%s' — not overriding" % _anim_tree_module._queued_standing)
		return
	if _dodge_active:
		# Dodged → sit on ground UNLESS she stood up because angry/suspicious
		var mood = _anim_tree_module._current_standing
		if mood in ["angry", "suspicious"]:
			print("🎬 Dodge + %s → staying standing" % mood)
		else:
			_anim_tree_module.sit_ground()
	else:
		# Home → return to wall
		_anim_tree_module.return_to_wall()

func _setup_radial_menu() -> void:
	# All UI menus are children of _ui_window (not main window)
	var ui_parent: Node = _ui_window if _ui_window else self
	radial_menu = CanvasLayer.new()
	radial_menu.set_script(RadialMenuScript)
	ui_parent.add_child(radial_menu)
	radial_menu.action_triggered.connect(_on_radial_action)
	radial_menu.request_hide.connect(_on_radial_hide)
	settings_panel = CanvasLayer.new()
	settings_panel.set_script(SettingsPanelScript)
	ui_parent.add_child(settings_panel)
	settings_panel.mic_selected.connect(_on_mic_selected)
	settings_panel.panel_closed.connect(_on_settings_panel_closed)
	settings_panel.api_key_submitted.connect(_on_api_key_submitted)
	settings_panel.language_changed.connect(_on_language_changed)
	settings_panel.volume_changed.connect(_on_volume_changed)
	settings_panel.session_duration_changed.connect(_on_session_duration_changed)
	settings_panel.screen_share_toggled.connect(_on_screen_share_toggled)
	settings_panel.mic_toggled.connect(_on_mic_toggled)
	settings_panel.tama_scale_changed.connect(_on_tama_scale_changed)
	# Debug tweaks (hidden, F2)
	debug_tweaks = CanvasLayer.new()
	debug_tweaks.set_script(DebugTweaksScript)
	ui_parent.add_child(debug_tweaks)
	print("🎛️ Menus attachés à %s" % ui_parent.name)


func _unhandled_input(event: InputEvent) -> void:
	# F1 = debug toggle du menu radial (fonctionne même sans Python)
	if event is InputEventKey and event.pressed and event.keycode == KEY_F1:
		if radial_menu:
			if radial_menu.is_open:
				print("🎛️ [DEBUG] F1 → Fermeture du radial menu")
				radial_menu.close()
			else:
				print("🎛️ [DEBUG] F1 → Ouverture du radial menu")
				_sync_and_show_ui()
				radial_menu.open()
				_safe_restore_passthrough()
	# F2 = hidden debug tweaks panel
	if event is InputEventKey and event.pressed and event.keycode == KEY_F2:
		if debug_tweaks:
			if not debug_tweaks.is_open:
				_sync_and_show_ui()
			debug_tweaks.toggle()
			print("🔧 [DEBUG] F2 → Tweaks %s" % ("OPEN" if debug_tweaks.is_open else "CLOSED"))
			_safe_restore_passthrough()
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
	# F7 = Debug Strike: trigger strike via AnimTree + hand window →
# ─── Multi-Window Hand Animation (Pooled) ──────────────────
var _hand_window: Window = null

func _get_hand_bone_screen_pos() -> Vector2i:
	"""Get Tama's hand bone projected to screen coords, or center fallback."""
	if not _tama_window or not is_instance_valid(_tama_window):
		return Vector2i.ZERO
	var win_pos: Vector2i = _tama_window.position
	var win_size: Vector2i = _tama_window.size
	var active_cam: Camera3D = _tama_cam if _tama_cam else _camera
	var sx: int = win_pos.x + int(win_size.x * 0.5)
	var sy: int = win_pos.y + int(win_size.y * 0.45)
	if _strike_hand_bone_idx >= 0 and _skeleton != null and active_cam != null:
		var bone_global := _skeleton.global_transform * _skeleton.get_bone_global_pose(_strike_hand_bone_idx)
		var screen_pos := active_cam.unproject_position(bone_global.origin)
		sx = int(screen_pos.x) + win_pos.x
		sy = int(screen_pos.y) + win_pos.y
	return Vector2i(sx, sy)

func _animate_pooled_window(win: Window, target_pos: Vector2i, start_emoji: String,
		end_emoji: String, win_size: int, font_size: int,
		ease_type: Tween.EaseType, trans_type: Tween.TransitionType,
		duration: float, on_done: Callable) -> void:
	"""Animate a pre-created pooled window. No Window.new() or queue_free()!"""
	if not is_instance_valid(win):
		return

	# Kill any running animation on this window
	if win.has_meta("tween"):
		var old_tween = win.get_meta("tween") as Tween
		if is_instance_valid(old_tween) and old_tween.is_running():
			old_tween.kill()

	var start := _get_hand_bone_screen_pos()
	var half := win_size / 2

	# Position + show (window already pre-created, minimal DWM cost)
	win.size = Vector2i(win_size, win_size)
	win.position = Vector2i(start.x - half, start.y - half)
	win.visible = true

	var label := win.get_node("EmojiLabel") as Label
	if label:
		label.text = start_emoji
		label.add_theme_font_size_override("font_size", font_size)

	# Animate toward target
	var dest := Vector2i(target_pos.x - half, target_pos.y - half)
	var tween := create_tween().bind_node(win)
	win.set_meta("tween", tween)
	tween.set_ease(ease_type)
	tween.set_trans(trans_type)
	tween.tween_property(win, "position", dest, duration)
	tween.tween_callback(func():
		if is_instance_valid(label):
			label.text = end_emoji
	)
	tween.tween_interval(0.5)
	tween.tween_callback(func():
		# Hide instead of queue_free() (pooled window)
		if is_instance_valid(win):
			win.visible = false
		on_done.call()
	)

func _spawn_hand_window() -> void:
	"""Strike hand: aggressive punch toward target (pooled window)."""
	var aim: Vector2i = _strike_target if _strike_target.x >= 0 else DisplayServer.mouse_get_position()
	_animate_pooled_window(_hand_window, aim, "🖐️", "👆", 120, 64,
		Tween.EASE_IN_OUT, Tween.TRANS_CUBIC, 0.7, func():
			_deactivate_imba()
			_strike_target = Vector2i(-1, -1)
	)


# ─── Jarvis Hand (Gentle Tap Animation) ─────────────────────
var _jarvis_hand: Window = null

# Emoji per action — gives visual feedback about WHAT Tama is doing
const JARVIS_EMOJIS = {
	"open_app": "👆",
	"switch_window": "👆",
	"minimize": "👇",
	"maximize": "☝️",
	"shortcut": "⌨️",
	"type_text": "⌨️",
	"open_url": "🌐",
	"search_web": "🔍",
	"screenshot": "📸",
	"volume_up": "🔊",
	"volume_down": "🔉",
	"volume_mute": "🔇",
}

func _spawn_jarvis_hand(target: Vector2i, action: String) -> void:
	"""Jarvis: gentle tap toward target (pooled window)."""
	var emoji: String = JARVIS_EMOJIS.get(action, "☝️")
	_animate_pooled_window(_jarvis_hand, target, emoji, "✨", 100, 48,
		Tween.EASE_OUT, Tween.TRANS_BACK, 0.5, func():
			if _gaze_modifier:
				_gaze_modifier.arm_ik_blend_target = 0.0
			set_gaze(GazeTarget.NEUTRAL, 2.0)
	)
	print("🤖 Jarvis hand: %s → (%d, %d) [%s]" % [emoji, target.x, target.y, action])

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
	# ALWAYS send HIDE_RADIAL to Python to reset state["radial_shown"]
	# Otherwise the edge monitor thinks radial is still open and won't re-trigger it.
	if ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		ws.send_text(JSON.stringify({"command": "HIDE_RADIAL"}))
	# _safe_restore_passthrough() already checks all panel states internally
	_safe_restore_passthrough()

var _quit_layer: CanvasLayer = null

func _show_quit_confirmation() -> void:
	if _quit_layer:
		return  # Already visible
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_MOUSE_PASSTHROUGH, false)
	if ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		ws.send_text(JSON.stringify({"command": "SHOW_QUIT"}))

	_quit_layer = CanvasLayer.new()
	_quit_layer.layer = 200
	var quit_parent: Node = _ui_window if _ui_window else self
	_sync_and_show_ui()
	quit_parent.add_child(_quit_layer)

	# Full-screen click catcher (clicking outside = cancel)
	var bg := ColorRect.new()
	bg.color = Color(0, 0, 0, 0.01)
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

	var vp_size := _ui_window.size if _ui_window else Vector2i(get_viewport().get_visible_rect().size)
	panel.position = Vector2(vp_size.x / 2 - 110, vp_size.y / 2 - 50)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 14)
	panel.add_child(vbox)

	var lbl := Label.new()
	lbl.text = "Tu veux vraiment\npartir ? 😿"
	lbl.add_theme_font_size_override("font_size", 14)
	lbl.add_theme_color_override("font_color", Color(0.9, 0.92, 1.0))
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(lbl)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_child(row)

	row.add_child(_build_styled_button("  Oui  ",
		Color(0.6, 0.2, 0.2, 0.8), Color(0.8, 0.25, 0.25, 0.9),
		Color(1, 0.9, 0.9), _do_quit))
	row.add_child(_build_styled_button("  Non  ",
		Color(0.15, 0.2, 0.35, 0.8), Color(0.25, 0.35, 0.55, 0.9),
		Color(0.85, 0.9, 1.0), _hide_quit_confirmation))

func _build_styled_button(text: String, bg: Color, hover_bg: Color,
		font_color: Color, callback: Callable) -> Button:
	"""Create a styled button for modal dialogs."""
	var btn := Button.new()
	btn.text = text
	btn.add_theme_font_size_override("font_size", 13)
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.set_corner_radius_all(8)
	s.set_content_margin_all(8)
	btn.add_theme_stylebox_override("normal", s)
	var h := StyleBoxFlat.new()
	h.bg_color = hover_bg
	h.set_corner_radius_all(8)
	h.set_content_margin_all(8)
	btn.add_theme_stylebox_override("hover", h)
	btn.add_theme_color_override("font_color", font_color)
	btn.pressed.connect(callback)
	return btn

func _hide_quit_confirmation() -> void:
	if _quit_layer:
		_quit_layer.queue_free()
		_quit_layer = null
	_safe_restore_passthrough()
	if ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		ws.send_text(JSON.stringify({"command": "QUIT_CLOSED"}))

func _do_quit() -> void:
	_hide_quit_confirmation()
	# Start dramatic glitch sequence before actually quitting
	_start_quit_glitch()
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
		ws.send_text(JSON.stringify({"command": "SETTINGS_CLOSED"}))

func _on_api_key_submitted(key: String) -> void:
	print("🔑 API key submitted")
	if ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		ws.send_text(JSON.stringify({"command": "SET_API_KEY", "key": key}))

func _on_language_changed(lang: String) -> void:
	print("🌐 Language changed: " + lang)
	if radial_menu and radial_menu.has_method("set_lang"):
		radial_menu.set_lang(lang)
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
	"""Smart UI visibility: show _ui_window when any UI is open, hide when all closed.
	Also manages Tama's always_on_top: dropped while UI is open so UI stays above."""
	var is_ui_active := false
	if radial_menu and radial_menu.is_open: is_ui_active = true
	if settings_panel and settings_panel.is_open: is_ui_active = true
	if debug_tweaks and debug_tweaks.is_open: is_ui_active = true
	if _quit_layer: is_ui_active = true

	if is_ui_active:
		if _ui_window and _ui_window.position.x < -1000:
			_sync_and_show_ui()
	else:
		if _ui_window and _ui_window.position.x > -1000:
			_ui_window.position = Vector2i(-5000, -5000)  # Park off-screen
		# Restore Tama to TOPMOST when all UI is closed
		if _tama_window and is_instance_valid(_tama_window):
			_tama_window.always_on_top = true

	# Main window (Tama 3D) always lets clicks through
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_MOUSE_PASSTHROUGH, true)

func _sync_and_show_ui() -> void:
	"""Position the UI window at home (bottom-right) and raise it above Tama.
	UI stays fixed — it does NOT follow Tama when she dodges.
	Z-order strategy: temporarily drop Tama from TOPMOST while UI is active.
	Since UI window stays TOPMOST, it's naturally above Tama.
	Tama's always_on_top is restored by _safe_restore_passthrough when all UI closes.
	No DWM surface recreation, no grab_focus, no visible toggle = smooth."""
	if _ui_window:
		var usable := DisplayServer.screen_get_usable_rect()
		var win_size := _tama_window.size if _tama_window else _BASE_WIN_SIZE
		var x := usable.position.x + usable.size.x - win_size.x
		var y := usable.position.y + usable.size.y - win_size.y
		_ui_window.size = win_size
		_ui_window.position = Vector2i(x, y)
		if not _ui_window.visible:
			_ui_window.visible = true
		# Drop Tama from TOPMOST so UI (still TOPMOST) is naturally above.
		# This is a single cheap SetWindowPos call — no lag, no flicker.
		# Tama stays above regular windows, just below TOPMOST ones.
		if _tama_window and is_instance_valid(_tama_window):
			_tama_window.always_on_top = false

func _position_window() -> void:
	_reposition_bottom_right()
	call_deferred("_apply_passthrough")

func _reposition_bottom_right() -> void:
	## Anchor Tama window to bottom-right of usable screen area (excludes taskbar)
	if not _tama_window or not is_instance_valid(_tama_window):
		return
	var usable := DisplayServer.screen_get_usable_rect()
	var win_size := _tama_window.size
	var x := usable.position.x + usable.size.x - win_size.x
	var y := usable.position.y + usable.size.y - win_size.y
	_tama_window.position = Vector2i(x, y)

func _get_tama_screen_center() -> Vector2i:
	"""Approximate screen position of Tama's body center."""
	if not _tama_window or not is_instance_valid(_tama_window):
		return Vector2i.ZERO
	var win_pos := _tama_window.position
	var win_size := _tama_window.size
	return Vector2i(win_pos.x + win_size.x / 2, win_pos.y + int(win_size.y * 0.55))

func _update_mouse_dodge(delta: float) -> void:
	"""Move Tama's window when mouse hovers her."""
	# Don't calculate dodge when Tama is invisible (prevents arming while hidden)
	if not _tama_window or not _tama_window.visible:
		return
	if _glitch_quitting or _glitch_teleporting or _dodge_departing:
		return
	if _quit_layer:
		return
	if (radial_menu and radial_menu.is_open) or (settings_panel and settings_panel.is_open):
		return
	if debug_tweaks and debug_tweaks.is_open:
		return

	if _dodge_cooldown_timer > 0:
		_dodge_cooldown_timer -= delta
		return

	var mouse := DisplayServer.mouse_get_position()
	var tama_center := _get_tama_screen_center()
	var dist := Vector2(mouse - tama_center).length()

	# Arming logic: dodge can only trigger AFTER mouse has left Tama's area once.
	# Prevents false dodge on entrance (mouse already near Tama) or after radial menu.
	if not _dodge_armed:
		if dist >= DODGE_HOVER_RADIUS:
			_dodge_armed = true
		return  # Don't dodge until armed

	if not _dodge_active:
		# Mouse near Tama → dodge to taskbar area
		if dist < DODGE_HOVER_RADIUS:
			_start_dodge_departure()
	else:
		# Mouse near Tama at dodge position → return home
		if dist < DODGE_HOVER_RADIUS:
			_start_dodge_return()

func _start_dodge_departure() -> void:
	"""Glitch dissolve → delay → move window → arrival glitch at new position."""
	_dodge_departing = true
	# Departure glitch: Tama dissolves at current position
	_glitch_intensity = GLITCH_TELEPORT_START
	_glitch_target = GLITCH_TELEPORT_START
	if _glitch_quad:
		_glitch_quad.visible = true
	if _glitch_material:
		_glitch_material.set_shader_parameter("intensity", _glitch_intensity)
	# Wait 300ms so user sees the dissolve, then teleport
	var tw := create_tween()
	tw.tween_interval(0.15)
	tw.tween_callback(func():
		_dodge_departing = false
		_dodge_to_taskbar()
	)

func _start_dodge_return() -> void:
	"""Glitch dissolve → delay → move window → arrival glitch at home."""
	_dodge_departing = true
	# Departure glitch at dodge position
	_glitch_intensity = GLITCH_TELEPORT_START
	_glitch_target = GLITCH_TELEPORT_START
	if _glitch_quad:
		_glitch_quad.visible = true
	if _glitch_material:
		_glitch_material.set_shader_parameter("intensity", _glitch_intensity)
	var tw := create_tween()
	tw.tween_interval(0.15)
	tw.tween_callback(func():
		_dodge_departing = false
		_dodge_return()
	)

func _dodge_to_taskbar() -> void:
	"""Move Tama's window to taskbar area (bottom-left) + arrival glitch."""
	_dodge_active = true
	_dodge_cooldown_timer = DODGE_COOLDOWN

	if not _tama_window or not is_instance_valid(_tama_window):
		return

	# FORCE pose BEFORE moving window (glitch is covering her)
	if _anim_tree_module and _anim_tree_module._playback:
		var is_angry_or_sus := false
		if _anim_tree_module.is_standing():
			# Check current mood or queued mood
			var mood = _anim_tree_module._current_standing
			var queued = _anim_tree_module._queued_standing
			if mood in ["angry", "suspicious"] or queued in ["angry", "suspicious"]:
				is_angry_or_sus = true
				# Process queued standing immediately before TP
				if queued != "":
					_anim_tree_module._queued_standing = ""
					_anim_tree_module._playback.start(queued)
					_anim_tree_module._tree.advance(0)
					_anim_tree_module._current_standing = queued
					_anim_tree_module._set_state(_anim_tree_module.State.STANDING)
		if not is_angry_or_sus:
			if _anim_tree_module._names.has("idle_ground"):
				_anim_tree_module._playback.start("idle_ground")
				_anim_tree_module._tree.advance(0)
				_anim_tree_module._set_state(_anim_tree_module.State.ON_GROUND)

	var usable := DisplayServer.screen_get_usable_rect()
	var win_size := _tama_window.size
	var x := usable.position.x + 20
	var y := usable.position.y + usable.size.y - win_size.y
	_tama_window.position = Vector2i(x, y)

	# Arrival glitch: fade from high intensity → 0 (materialization)
	_glitch_teleporting = true
	_glitch_intensity = GLITCH_TELEPORT_START
	_glitch_target = 0.0
	if _glitch_quad:
		_glitch_quad.visible = true
	if _glitch_material:
		_glitch_material.set_shader_parameter("intensity", _glitch_intensity)
	print("⚡ Dodge! Tama window → (%d, %d)" % [x, y])

func _dodge_return() -> void:
	"""Move Tama's window back to home (bottom-right) + arrival glitch."""
	_dodge_active = false
	_dodge_armed = false  # Require mouse to leave area again before re-dodge
	_dodge_cooldown_timer = DODGE_COOLDOWN

	# FORCE pose BEFORE moving window (glitch is covering her)
	if _anim_tree_module and _anim_tree_module._playback:
		if _anim_tree_module.is_standing():
			# Already standing (angry/suspicious) — keep standing pose
			pass
		elif _anim_tree_module._names.has("idle_wall"):
			_anim_tree_module._playback.start("idle_wall")
			_anim_tree_module._tree.advance(0)
			_anim_tree_module._set_state(_anim_tree_module.State.ON_WALL)

	_reposition_bottom_right()

	# Arrival glitch: fade from high intensity → 0 (materialization)
	_glitch_teleporting = true
	_glitch_intensity = GLITCH_TELEPORT_START
	_glitch_target = 0.0
	if _glitch_quad:
		_glitch_quad.visible = true
	if _glitch_material:
		_glitch_material.set_shader_parameter("intensity", _glitch_intensity)
	print("⚡ Return! Tama window → home")

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
		if _tama_cam:
			_tama_cam.size = _camera.size
			_tama_cam.position = _camera.position
		return
	# Below 100%: zoom out camera for live preview
	var new_size := _base_cam_size / factor
	_camera.size = new_size
	var base_bottom := _base_cam_y - _base_cam_size / 2.0
	_camera.position.y = base_bottom + new_size / 2.0
	var aspect := float(_BASE_WIN_SIZE.x) / float(_BASE_WIN_SIZE.y)
	var base_right := _base_cam_x + _base_cam_size / 2.0 * aspect
	_camera.position.x = base_right - new_size / 2.0 * aspect
	# Sync clone camera for live preview
	if _tama_cam:
		_tama_cam.size = _camera.size
		_tama_cam.position = _camera.position

func _apply_tama_scale_full() -> void:
	## Apply final scale: camera zoom for ≤100%, window resize for >100%
	if _camera == null or _base_cam_size <= 0:
		return
	var factor := float(_tama_scale_pct) / 100.0
	if factor > 1.0:
		# Bigger Tama: enlarge window, reset camera to default
		var new_w := int(_BASE_WIN_SIZE.x * factor)
		var new_h := int(_BASE_WIN_SIZE.y * factor)
		var new_size := Vector2i(new_w, new_h)
		if _tama_window and is_instance_valid(_tama_window):
			_tama_window.size = new_size
		_camera.size = _base_cam_size
		_camera.position.y = _base_cam_y
	else:
		# Smaller/default Tama: window stays 400×500, camera zoomed out
		if _tama_window and is_instance_valid(_tama_window):
			_tama_window.size = _BASE_WIN_SIZE
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
	# Sync clone camera with updated settings
	if _tama_cam:
		_tama_cam.size = _camera.size
		_tama_cam.position = _camera.position
	if _dodge_active:
		call_deferred("_dodge_to_taskbar")
	else:
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
	# Don't process WebSocket until all deferred setups are complete
	# (prevents race condition: Python sends START_SESSION before AnimTree is ready)
	if not _init_done:
		return

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

	# Glitch effect smooth fade
	_update_glitch(delta)

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
			_eye_follow_active = false
			_scan_eye_active = false

	# ─── Voice-Sync Entrance Timeout ──────────────────────────
	if _waiting_for_voice:
		_voice_timeout_timer -= delta
		if _voice_timeout_timer <= 0.0:
			print("⏳ Timeout vocal (10s) : Tama entre silencieusement.")
			_trigger_entrance()

	# Sync gaze targets to modifier BEFORE it processes (modifier runs after AnimationPlayer)
	_sync_gaze_to_modifier()

	# ─── Mouse Dodge ───────────────────────────────────────────
	_update_mouse_dodge(delta)

	# ─── Strike Fire ──────────────────────────────────────────
	# Handled by AnimTree module (strike_fire_point signal → _on_tree_strike_fire)


func _notification(what: int) -> void:
	# INTERNAL_PROCESS: only eye follow (blend shapes — no bone conflict).
	# Gaze bone rotation + spring bones are now in gaze_modifier.gd (SkeletonModifier3D)
	# which processes AFTER AnimationPlayer automatically.
	if what == NOTIFICATION_INTERNAL_PROCESS:
		var delta = get_process_delta_time()

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
	"""Convert screen pixel position to eye target direction (-1..+1).
	Multi-monitor aware: uses the screen Tama is currently on."""
	var win_pos := _tama_window.position if _tama_window else Vector2i.ZERO
	var win_size := _tama_window.size if _tama_window else _BASE_WIN_SIZE
	# Tama's eye center on screen (approximate: center-top of Godot window)
	var eye_sx: float = float(win_pos.x) + float(win_size.x) * 0.5
	var eye_sy: float = float(win_pos.y) + float(win_size.y) * 0.35
	var dx: float = screen_x - eye_sx
	var dy: float = screen_y - eye_sy
	# Use the correct screen (important for multi-monitors)
	var screen_idx = DisplayServer.window_get_current_screen()
	if _tama_window and is_instance_valid(_tama_window):
		screen_idx = DisplayServer.window_get_current_screen(_tama_window.get_window_id())
	var screen_w: float = float(DisplayServer.screen_get_size(screen_idx).x)
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
	if typeof(data) != TYPE_DICTIONARY:
		return

	# ── Commandes depuis Python ──
	var command = data.get("command", "")
	if command == "QUIT":
		print("👋 Signal QUIT reçu, glitch de fermeture...")
		_start_quit_glitch()
		return
	elif command == "START_SESSION":
		if not session_active:
			session_active = true
			conversation_active = false  # Session overrides conversation
			if _has_local_greeting:
				# ⚡ Instant entrance with local greeting audio (0ms latency)
				print("🚀 Session lancée ! (Greeting local)")
				_instant_entrance_with_greeting()
			else:
				# Fallback: wait for Gemini's first audio
				print("🚀 Session lancée ! (Attente de la voix...)")
				_waiting_for_voice = true
				_voice_timeout_timer = 15.0
				_show_status_indicator("Connexion neuronale...", Color(0.5, 0.2, 0.8, 0.9))
		return
	elif command == "START_CONVERSATION":
		if not session_active and not conversation_active:
			conversation_active = true
			_convo_engagement = 0  # Reset engagement counter
			if _has_local_greeting:
				# ⚡ Instant entrance with local greeting audio (0ms latency)
				print("💬 Mode conversation ! (Greeting local)")
				_instant_entrance_with_greeting()
			else:
				# Fallback: wait for Gemini's first audio
				print("💬 Mode conversation ! (Attente de la voix...)")
				_waiting_for_voice = true
				_voice_timeout_timer = 15.0
				_show_status_indicator("Appel de Tama...", Color(0.5, 0.7, 1.0, 0.9))
		return
	elif command == "SESSION_COMPLETE":
		print("🏁 Session complète — fin de session !")
		session_active = false
		if _anim_tree_module:
			if _anim_tree_module.is_standing():
				if _dodge_active:
					_anim_tree_module.sit_ground()
				else:
					_anim_tree_module.return_to_wall()
		return
	elif command == "END_CONVERSATION":
		if conversation_active:
			conversation_active = false
			set_gaze(GazeTarget.NEUTRAL, 2.0)
			print("💬 Fin de conversation")
			if _anim_tree_module:
				if _anim_tree_module.is_on_ground():
					if _anim_tree_module.current_state == 8:  # GROUND_TALK
						_anim_tree_module.end_ground_talk()
				elif _anim_tree_module.current_state == 2:  # WALL_TALK
					_anim_tree_module.end_wall_talk()
				elif _anim_tree_module.is_standing():
					if _dodge_active:
						_anim_tree_module.sit_ground()
					else:
						_anim_tree_module.return_to_wall()
				# else already on wall/ground — nothing to do
		return
	elif command == "SHOW_RADIAL":
		if settings_panel and settings_panel.is_open:
			settings_panel.close()
		if radial_menu:
			_sync_and_show_ui()
			radial_menu.open()
			_safe_restore_passthrough()
		return
	elif command == "HIDE_RADIAL":
		if radial_menu:
			radial_menu.close()
		_safe_restore_passthrough()
		return
	elif command == "SETTINGS_DATA":
		var mics = data.get("mics", [])
		var selected = int(data.get("selected", -1))
		var has_api_key = data.get("has_api_key", false)
		var key_valid = data.get("key_valid", false)
		var key_hint = data.get("key_hint", "")
		var lang = data.get("language", "en")
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
			if radial_menu and radial_menu.has_method("set_lang"):
				radial_menu.set_lang(lang)
			_sync_and_show_ui()
			settings_panel.show_settings(mics, selected, has_api_key, key_valid, lang, tama_vol, session_duration, api_usage, screen_share, mic_on, tama_scale, key_hint)
			_safe_restore_passthrough()
		return
	elif command == "API_KEY_UPDATED":
		var valid = data.get("valid", false)
		print("🔑 API key validation result: %s" % str(valid))
		if settings_panel:
			settings_panel.update_key_valid(valid)
		return
	elif command == "TWEAKS_DATA":
		var values = data.get("values", {})
		print("🔧 TWEAKS_DATA received: %s" % str(values))
		if debug_tweaks:
			debug_tweaks.update_values(values)
		return
	elif command == "USER_SPEAKING":
		# Subtle acknowledgment — Tama looks at user
		if conversation_active:
			_convo_engagement += 1
			print("👀 User speaking — engagement #%d" % _convo_engagement)
		_on_user_speaking_ack()  # Always ack (conversation + deep work)
		return
	elif command == "SET_SUBJECT":
		# Python registers a point of interest (e.g. video, browser tab)
		# Future gaze events (SCREEN_SCAN, GAZE_AT screen_center) will fixate here
		if data.has("x") and data.has("y"):
			_subject_target = Vector2i(int(data["x"]), int(data["y"]))
			print("🎯 Subject target set: (%d, %d)" % [_subject_target.x, _subject_target.y])
		else:
			_subject_target = Vector2i(-1, -1)
			print("🎯 Subject target cleared")
		return
	elif command == "GAZE_AT":
		# Python tells Tama where to look
		# Supports: {x, y} screen pixels OR {target: "user"/"screen"/"book"/etc}
		var spd = data.get("speed", 3.0)
		if data.has("x") and data.has("y"):
			# Screen pixel coordinates
			var px = float(data["x"])
			var py = float(data["y"])
			set_gaze_at_screen_point(px, py, spd)
			_look_eyes_at_screen_point(px, py)  # Force eyes to look at this pixel
			_scan_eye_active = true
			if data.has("duration"):
				_scan_glance_timer = float(data["duration"])
			else:
				_scan_glance_timer = 2.0
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
	elif command == "JARVIS_TAP":
		# Jarvis mode: Tama's hand gently taps the target (not a strike — an assist)
		var jtx := int(data.get("x", -1))
		var jty := int(data.get("y", -1))
		var jaction: String = data.get("action", "")
		print("🤖 JARVIS_TAP: (%d, %d) action=%s" % [jtx, jty, jaction])
		if jtx > 0 and jty > 0:
			_spawn_jarvis_hand(Vector2i(jtx, jty), jaction)
			# Arm IK: point toward the tap target (gentle, not aggressive)
			if _gaze_modifier:
				var target_3d := _screen_to_arm_target(float(jtx), float(jty))
				_gaze_modifier.arm_ik_target = target_3d
				_gaze_modifier.arm_ik_active = true
				_gaze_modifier.arm_ik_blend_target = 0.7  # Softer than Strike (which uses 1.0)
			# Brief gaze toward the target
			set_gaze_at_screen_point(float(jtx), float(jty), 4.0)
			_look_eyes_at_screen_point(float(jtx), float(jty))  # Eyes follow the tap
		return
	elif command == "TAMA_ANIM":
		var anim_name = data.get("anim", "")
		_last_anim_command_time = Time.get_unix_time_from_system()
		print("🎬 [ANIM CMD] %s (state=%s dodge=%s)" % [anim_name, _anim_tree_module.get_current_anim_key() if _anim_tree_module else "?", str(_dodge_active)])
		if _anim_tree_module:
			var key: String = str(anim_name).to_lower()
			if key in ["go_away", "bye"]:
				# go_away anim never plays — return to rest position instead
				if _anim_tree_module.is_on_ground():
					if _anim_tree_module.current_state == 8:  # GROUND_TALK
						_anim_tree_module.end_ground_talk()
				elif _anim_tree_module.current_state == 2:  # WALL_TALK
					_anim_tree_module.end_wall_talk()
				elif _anim_tree_module.is_standing():
					if _dodge_active:
						if _anim_tree_module._current_standing not in ["angry", "suspicious"]:
							_anim_tree_module.sit_ground()
					else:
						_anim_tree_module.return_to_wall()
			elif key in ["idle_wall"]:
				# "Go back to rest" — wall if home, ground if dodged
				if _anim_tree_module.is_on_ground():
					# Already on ground — end talk if active, stay sitting
					if _anim_tree_module.current_state == 8:  # GROUND_TALK
						_anim_tree_module.end_ground_talk()
					# else already idle_ground — nothing to do
				elif _dodge_active:
					# Standing while dodged — only sit if not angry/suspicious
					if _anim_tree_module.is_standing() and _anim_tree_module._current_standing not in ["angry", "suspicious"]:
						_anim_tree_module.sit_ground()
					# else angry/suspicious or transitioning — leave it
				else:
					_anim_tree_module.return_to_wall()
			elif key in ["walk_in"]:
				_anim_tree_module.walk_in()
			elif key in ["strike", "strike_base"]:
				_anim_tree_module.play_strike()
				_activate_imba(1)
			elif key in ["idle_wall_talk"]:
				if _anim_tree_module.is_on_wall():
					_anim_tree_module.play_wall_talk()
				elif _anim_tree_module.is_on_ground():
					# Ground equivalent: lean in and talk while sitting
					_anim_tree_module.play_ground_talk()
				elif _dodge_active and _anim_tree_module.is_standing():
					# Standing in dodge mode — only sit if not angry/suspicious
					if _anim_tree_module._current_standing not in ["angry", "suspicious"]:
						_anim_tree_module.sit_ground()
				else:
					# Already standing at home — stay idle
					pass
			elif key == "suspicious":
				if _anim_tree_module.is_on_ground():
					# On ground: lean in and talk (don't stand up for suspicious)
					_anim_tree_module.play_ground_talk()
				elif _anim_tree_module.is_on_wall():
					_anim_tree_module.play_wall_talk()
				else:
					_anim_tree_module.set_standing_anim("suspicious")
			elif key == "angry":
				_anim_tree_module.set_standing_anim("angry")
			else:
				# Unknown anim — only stand up if NOT on ground
				if _anim_tree_module.is_on_ground():
					_anim_tree_module.play_ground_talk()  # Safe ground fallback
				elif _anim_tree_module.is_on_wall():
					_anim_tree_module.play_wall_talk()  # Safe wall fallback
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
		_current_mouth_slot = mouth_key  # Always memorize mood mouth (even while speaking)
		if not _is_speaking:  # Only apply visually if not lip-syncing
			_set_mouth(mouth_key)
		_set_eyebrows(mood_name)
		return
	elif command == "TAMA_VOICE_READY":
		# 🎯 Primary entrance trigger: Gemini received first audio chunk
		# Arrives ~200ms before first VISEME (before audio playback starts)
		if _waiting_for_voice:
			print("🎙️ TAMA_VOICE_READY reçu — déclenchement entrée !")
			_trigger_entrance()
		return
	elif command == "VISEME":
		var shape = data.get("shape", "REST")
		var amp: float = data.get("amp", 0.5)
		# 🎯 DÉCLENCHEMENT SYNCHRONISÉ AU PREMIER MOT
		if _waiting_for_voice and shape != "REST":
			_trigger_entrance()
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
			elif _anim_tree_module and (_anim_tree_module.current_state == 2 or _anim_tree_module.current_state == 8): # WALL_TALK or GROUND_TALK
				# En mode WALL_TALK ou GROUND_TALK, elle maintient son regard !
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
		# Only glance when not already speaking
		if _anim_tree_module and not _is_speaking:
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
			# Use focus point from Python if available (active window center),
			# otherwise fall back to screen center (which may use _subject_target)
			if data.has("focus_x") and data.has("focus_y"):
				var fx: float = float(data["focus_x"])
				var fy: float = float(data["focus_y"])
				# Head: look at the actual suspicious content
				var target_3d = _screen_to_world(fx, fy)
				_gaze_world_target = target_3d
				if _gaze_active:
					_gaze_lerp_speed = head_speed
					_look_at_world_point(target_3d, head_speed, head_blend)
					_sync_gaze_to_modifier()
				# Eyes: follow the same spot
				_look_eyes_at_screen_point(fx, fy)
			else:
				set_gaze_subtle(GazeTarget.SCREEN_CENTER, head_speed, head_blend)
				# Eyes look dynamically toward screen center (or Python subject)
				_look_eyes_at_screen_center()
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
			_set_glitch_active(false)  # Initial connection — no glitch
		elif conn_status == "reconnecting":
			var attempt = data.get("attempt", 1)
			_show_status_indicator("Reconnexion (" + str(attempt) + ")", Color(0.9, 0.7, 0.3, 0.9))
			_set_headphones_visible(true)
			_set_glitch_active(true)   # API lost — glitch Tama!
		elif conn_status == "connected":
			if _waiting_for_voice:
				_show_status_indicator("Agent prêt, réflexion...", Color(0.2, 0.8, 0.4, 0.9))
			else:
				_hide_status_indicator()
			_set_headphones_visible(false)
			_set_glitch_active(false)  # Reconnected — clear glitch
		return

	# ── Auto-clear glitch on stealth reconnection ──
	# Stealth reconnects (1011) don't send CONNECTION_STATUS, but broadcast
	# includes gemini_connected=true once the API is back.
	if data.has("gemini_connected"):
		var gc: bool = data.get("gemini_connected", false)
		if gc and _glitch_intensity > 0.0 and not _glitch_quitting:
			_set_glitch_active(false)
			_hide_status_indicator()
			_set_headphones_visible(false)

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

	# ── Session ding: play chime when break reminder first activates ──
	var break_reminder: bool = data.get("break_reminder", false)
	if break_reminder and not _break_reminder_was_active:
		if _session_ding_player and _session_ding_player.stream:
			_session_ding_player.play()
			print("🔔 Session ding!")
	_break_reminder_was_active = break_reminder

	# Gaze is now driven exclusively by Python's SCREEN_SCAN command
	# (no more fake cosmetic glances)


# _try_scan_glance() REMOVED: gaze is now driven exclusively by
# Python's SCREEN_SCAN command (real scans only, no fake cosmetic glances).



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

	# ── Ground sitting (dodge mode) — mirror of wall logic ──
	if _anim_tree_module.is_on_ground():
		match tier:
			0:
				# CALM — stay sitting on ground, end talk if active
				_suspicion_staring = false
				if _anim_tree_module.current_state == 8:  # GROUND_TALK
					_anim_tree_module.end_ground_talk()
				# Already in idle_ground — nothing to do
			1:
				# SUSPICIOUS — lean in and talk from ground (don't stand up)
				if _anim_tree_module.current_state == 7:  # ON_GROUND
					_suspicion_staring = true
					_anim_tree_module.play_ground_talk()
				# If already GROUND_TALK, just stay there
			2:
				# ANGRY — NOW she stands up from ground for real
				if _anim_tree_module.current_state == 8:  # GROUND_TALK
					# End ground talk first, then stand up
					_pending_leave_wall = true  # Reuse flag to queue standup
					_anim_tree_module.end_ground_talk()
				else:
					_suspicion_staring = false
					# set_standing_anim queues "angry" + stand_from_ground
					# so _current_standing = "angry" when she's up
					_anim_tree_module.set_standing_anim("angry")
					print("🎬 Ground angry → standing up!")
		return

	# ── Wall sitting (normal home position) ──
	match tier:
		0:
			# CALM — back to book
			_suspicion_staring = false
			_pending_leave_wall = false
			if _anim_tree_module.current_state == 2:  # WALL_TALK
				_anim_tree_module.end_wall_talk()
			elif _anim_tree_module.is_standing():
				if _dodge_active:
					_anim_tree_module.sit_ground()  # Go back to sitting on ground
				else:
					_anim_tree_module.return_to_wall()
			elif not _anim_tree_module.is_on_wall():
				if _dodge_active:
					pass  # Already sitting or transitioning — leave it
				else:
					_anim_tree_module.return_to_wall()
		1:
			# SUSPICIOUS — lean in and STARE from wall (don't leave)
			if _anim_tree_module.current_state == 1:  # ON_WALL
				_suspicion_staring = true
				_anim_tree_module.play_wall_talk()
				# Gaze is set by _on_tree_state_changed when WALL_TALK fires
			elif _anim_tree_module.is_standing():
				# De-escalating from angry
				_suspicion_staring = false
				if _dodge_active:
					_anim_tree_module.sit_ground()  # Sit back down
				else:
					_anim_tree_module.return_to_wall()
		2:
			# ANGRY — leave wall for real
			if _anim_tree_module.current_state == 2:  # WALL_TALK
				# Reverse wall_talk first, then leave
				_pending_leave_wall = true
				_anim_tree_module.end_wall_talk()
			elif _anim_tree_module.is_on_wall():
				_suspicion_staring = false
				_anim_tree_module.set_standing_anim("angry")
			else:
				_anim_tree_module.set_standing_anim("angry")

# ─── Utilitaires ─────────────────────────────────────────
func _ensure_anim_player() -> void:
	if _anim_player != null:
		return
	var tama = get_node_or_null("Tama")
	if tama == null:
		return
	_anim_player = _find_animation_player(tama)

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
	"E9": 0.5,   # Happy Wink — one eye closed, half hidden
	# E0, E3, E5, E8: pupils fully visible (not listed = 0.0)
}

func _set_eyes(slot: String) -> void:
	_current_eye_slot = slot
	if _blink_phase == 0:  # Don't interrupt a blink in progress
		_apply_eye_offset(slot)
		# Set pupil visibility based on how much the expression covers them
		var hide_val: float = PUPIL_HIDE_AMOUNT.get(slot, 0.0)
		_set_pupil_hide(hide_val)
	# If blinking, _update_blink() will restore _current_eye_slot when blink ends

# Apply UV offset without changing _current_eye_slot (used by blink)
func _apply_eye_offset(slot: String) -> void:
	if not _expressions_painted:
		return
	if _eyes_material and EYE_OFFSETS.has(slot):
		_eyes_material.uv1_offset = EYE_OFFSETS[slot]

func _set_mouth(slot: String) -> void:
	# _current_mouth_slot is now set directly by TAMA_MOOD handler
	# This function only applies the UV offset visually
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

# ─── Glitch Effect (API disconnection visual) ───────────────
func _setup_glitch_effect() -> void:
	# Need a camera to attach the quad — prefer _tama_cam (visible window)
	var target_cam: Camera3D = _tama_cam if _tama_cam else _camera
	if target_cam == null:
		push_warning("⚠️ Glitch: No camera found — glitch effect disabled")
		return

	# Create a full-screen quad as child of camera (moves with it)
	_glitch_quad = MeshInstance3D.new()
	_glitch_quad.name = "GlitchQuad"
	var quad := QuadMesh.new()
	# Oversized quad — orthogonal camera shows same size regardless of Z
	quad.size = Vector2(10.0, 10.0)
	_glitch_quad.mesh = quad
	# Place just in front of camera (Z = -1 in camera-local space)
	_glitch_quad.position = Vector3(0.0, 0.0, -1.0)

	# Load and apply the spatial shader
	var shader = load("res://glitch_effect.gdshader")
	if shader:
		_glitch_material = ShaderMaterial.new()
		_glitch_material.shader = shader
		_glitch_material.set_shader_parameter("intensity", 0.0)
		_glitch_material.set_shader_parameter("shake_power", 0.03)
		_glitch_material.set_shader_parameter("shake_rate", 0.3)
		_glitch_material.set_shader_parameter("shake_speed", 5.0)
		_glitch_material.set_shader_parameter("shake_block_size", 30.5)
		_glitch_material.set_shader_parameter("shake_color_rate", 0.015)
		# render_priority > 0 ensures the quad draws AFTER Tama's meshes
		_glitch_material.render_priority = 100
		_glitch_quad.material_override = _glitch_material
		print("📺 Glitch effect shader loaded (spatial quad)")
	else:
		push_warning("⚠️ glitch_effect.gdshader not found")

	# Glitch quad must be on layer 2 so _tama_cam (cull_mask=2) can see it
	_glitch_quad.layers = TAMA_LAYER_BIT
	target_cam.add_child(_glitch_quad)
	# Start hidden — no GPU cost when inactive
	_glitch_quad.visible = false
	print("📺 Glitch effect ready on %s (hidden)" % target_cam.name)

func _set_glitch_active(active: bool) -> void:
	if _glitch_quitting:
		return  # Don't interrupt quit sequence
	if _glitch_teleporting:
		return  # Don't interrupt teleport arrival sequence
	_glitch_target = 1.0 if active else 0.0
	if active and _glitch_quad:
		_glitch_quad.visible = true
		print("📺 Glitch ON — API disconnected")
	elif not active:
		print("📺 Glitch fading out — API reconnected")

func _start_quit_glitch() -> void:
	"""Dramatic glitch ramp before closing — Tama dissolves."""
	if _glitch_quitting:
		return  # Already quitting
	_glitch_quitting = true
	_glitch_target = GLITCH_QUIT_MAX
	if _glitch_quad:
		_glitch_quad.visible = true
	print("📺 QUIT GLITCH — Tama is dissolving...")

func _update_glitch(delta: float) -> void:
	if _glitch_material == null:
		return

	if _glitch_quitting:
		# Accelerating ramp: gets faster as intensity rises
		var ramp_speed := GLITCH_QUIT_RAMP * (1.0 + _glitch_intensity * 0.5)
		_glitch_intensity = minf(_glitch_intensity + ramp_speed * delta, GLITCH_QUIT_MAX)
		_glitch_material.set_shader_parameter("intensity", _glitch_intensity)
		# When max reached — goodbye
		if _glitch_intensity >= GLITCH_QUIT_MAX - 0.01:
			print("👋 Glitch max — fermeture.")
			get_tree().quit()
	elif _glitch_teleporting:
		# Teleport arrival: fade from high intensity → 0 (materialization)
		_glitch_intensity = maxf(_glitch_intensity - GLITCH_TELEPORT_FADE_SPEED * delta, 0.0)
		_glitch_material.set_shader_parameter("intensity", _glitch_intensity)
		if _glitch_intensity < 0.001:
			_glitch_teleporting = false
			_glitch_intensity = 0.0
			_glitch_target = 0.0
			if _glitch_quad:
				_glitch_quad.visible = false
			print("📺 Teleport glitch complete — Tama materialized")
	else:
		# Normal glitch fade in/out
		if _glitch_intensity < _glitch_target:
			_glitch_intensity = minf(_glitch_intensity + GLITCH_FADE_IN_SPEED * delta, _glitch_target)
		elif _glitch_intensity > _glitch_target:
			_glitch_intensity = maxf(_glitch_intensity - GLITCH_FADE_OUT_SPEED * delta, _glitch_target)
		_glitch_material.set_shader_parameter("intensity", _glitch_intensity)
		# Hide quad entirely when fully faded out (saves GPU)
		if _glitch_intensity < 0.001 and _glitch_quad:
			_glitch_quad.visible = false


func _trigger_entrance() -> void:
	"""Voice-synced entrance: called when first VISEME arrives or timeout expires.
	Makes Tama visible and triggers her entrance animation."""
	if not _waiting_for_voice:
		return
	_waiting_for_voice = false
	_hide_status_indicator()

	# 1. Force window visible + position
	if _tama_window:
		_tama_window.visible = true
		if not _dodge_active:
			_reposition_bottom_right()
	# 2. Force 3D model visible (safety net)
	var tama_node = get_node_or_null("Tama")
	if tama_node:
		tama_node.visible = true
	# 3. Animate arrival
	if _anim_tree_module and _anim_tree_module.is_off_screen():
		_teleport_glitch_in()
	elif not _started:
		_start_idle_wall()
	print("✨ Entrée synchronisée ! Tama apparaît avec sa voix.")


func _setup_greeting_audio() -> void:
	"""Load local greeting audio (tama_hello.wav or .mp3). If found, instant entrance is used."""
	_local_greeting_player = AudioStreamPlayer.new()
	var audio_file = load("res://tama_hello.wav")
	var file_name = "tama_hello.wav"
	if not audio_file:
		audio_file = load("res://tama_hello.mp3")
		file_name = "tama_hello.mp3"
	if audio_file:
		_local_greeting_player.stream = audio_file
		_local_greeting_player.volume_db = -6.0  # Clear but not overwhelming
		_has_local_greeting = true
		print("🔊 Greeting local chargé (%s)" % file_name)
	else:
		_has_local_greeting = false
		print("🔇 Pas de tama_hello.wav/mp3 — fallback sur voix IA")
	add_child(_local_greeting_player)


func _instant_entrance_with_greeting() -> void:
	"""Instant entrance with local greeting audio. No waiting for Gemini.
	Used when tama_hello.wav is available for 0ms latency."""
	_waiting_for_voice = false  # Don't wait for AI voice
	_hide_status_indicator()

	# 1. Force window visible + position
	if _tama_window:
		_tama_window.visible = true
		if not _dodge_active:
			_reposition_bottom_right()
	# 2. Force 3D model visible
	var tama_node = get_node_or_null("Tama")
	if tama_node:
		tama_node.visible = true
	# 3. Animate arrival
	if _anim_tree_module and _anim_tree_module.is_off_screen():
		_teleport_glitch_in()
	elif not _started:
		_start_idle_wall()

	# 4. Play local greeting + animate mouth
	if _local_greeting_player and _local_greeting_player.stream:
		_local_greeting_player.play()
		_is_speaking = true
		_set_mouth("M2")  # Open mouth ("A" shape for "Salut")
		# Mouth animation sequence: open → mid → close (simulates speech)
		var mouth_tween = create_tween()
		mouth_tween.tween_callback(func(): _set_mouth("M9")).set_delay(0.2)   # A moyen
		mouth_tween.tween_callback(func(): _set_mouth("M3")).set_delay(0.15)  # teeth "i"
		mouth_tween.tween_callback(func(): _set_mouth("M11")).set_delay(0.15) # O moyen
		mouth_tween.tween_callback(func(): _set_mouth("M3")).set_delay(0.15)  # teeth
		mouth_tween.tween_callback(func(): _set_mouth("M0")).set_delay(0.2)   # close
		mouth_tween.tween_callback(func():
			_is_speaking = false
			_set_mouth(_current_mouth_slot)  # Return to mood face
		).set_delay(0.3)
	print("⚡ Entrée instantanée avec greeting local !")

func _teleport_glitch_in() -> void:
	"""Primary arrival: Tama materializes with a glitch effect + Hello animation.
	The glitch starts at high intensity and fades to 0 as she appears."""
	if not _anim_tree_module:
		return
	if not _anim_tree_module.is_off_screen():
		return

	# Start glitch at max intensity BEFORE showing Tama
	if _glitch_material and _glitch_quad:
		_glitch_teleporting = true
		_glitch_intensity = GLITCH_TELEPORT_START
		_glitch_target = 0.0  # Will fade to 0
		_glitch_material.set_shader_parameter("intensity", _glitch_intensity)
		_glitch_quad.visible = true

	# Play Hello entrance animation (walk_in prefers Hello anim if available)
	_anim_tree_module.walk_in()
	_started = true
	_last_anim_command_time = Time.get_unix_time_from_system()  # Protect Hello from suspicion override
	# Grace period: don't dodge during Hello anim + disarm
	_dodge_cooldown_timer = 5.0
	_dodge_armed = false
	print("📺 Teleport glitch IN — Tama materializing with Hello anim (intensity: %.1f → 0)" % GLITCH_TELEPORT_START)

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

func _setup_session_ding() -> void:
	_session_ding_player = AudioStreamPlayer.new()
	var audio_file = load("res://session_ding.wav")
	if audio_file:
		_session_ding_player.stream = audio_file
		_session_ding_player.volume_db = -6.0  # Noticeable but not jarring
	else:
		push_warning("⚠️ session_ding.wav not found")
	add_child(_session_ding_player)

func _on_user_speaking_ack() -> void:
	# Only block the ack SOUND when Tama is speaking (avoid audio clash)
	# But ALWAYS set the gaze — user must see Tama react even during barge-in
	if _ack_audio_player and _ack_audio_player.stream and not _is_speaking:
		_ack_audio_player.play()
	# Change eyes to curious/attentive (E0 = wide eyes)
	_set_expression_slot("eyes", "E0")
	_ack_eye_timer = 2.5  # Restore eyes after 2.5 seconds
	# Stage 1: Eyes look toward user via blend shapes (dynamic webcam position)
	_look_eyes_at_webcam()
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
	elif target in [GazeTarget.SCREEN_CENTER, GazeTarget.SCREEN_TOP, GazeTarget.SCREEN_BOTTOM, GazeTarget.OTHER_MONITOR]:
		# Dynamic: compute actual screen pixel, then convert to 3D world point
		var pt = _get_dynamic_target_point(target)
		if target == GazeTarget.SCREEN_CENTER and _subject_target.x >= 0:
			pt = Vector2(float(_subject_target.x), float(_subject_target.y))
		var target_3d = _screen_to_world(pt.x, pt.y)
		_gaze_world_target = target_3d
		_look_at_world_point(target_3d, speed, max_blend)
	else:
		var head_pos = _get_head_world_pos()
		var offset = GAZE_PRESET_OFFSETS.get(target, Vector3(0, 0, 2))
		var target_point = head_pos + offset
		_gaze_world_target = target_point
		_look_at_world_point(target_point, speed, max_blend)
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
# Used ONLY for targets that don't map to a screen point (USER, BOOK, AWAY)
var GAZE_PRESET_OFFSETS = {
	GazeTarget.USER: Vector3(0, 1.5, 2.0),            # Up toward user (4th wall — head is down in Idle_wall)
	GazeTarget.BOOK: Vector3(-0.3, -0.8, 0.5),         # Down in front
	GazeTarget.AWAY: Vector3(2.0, 0.2, -0.5),          # Behind to the right
}

# ─── Dynamic Subject Gaze Helpers ───────────────────────────
func _get_dynamic_target_point(target: GazeTarget) -> Vector2:
	"""Compute the screen pixel for a gaze target based on Tama's actual screen."""
	var screen_idx = DisplayServer.window_get_current_screen()
	if _tama_window and is_instance_valid(_tama_window):
		screen_idx = DisplayServer.window_get_current_screen(_tama_window.get_window_id())
	var usable = DisplayServer.screen_get_usable_rect(screen_idx)
	var cx = float(usable.position.x) + float(usable.size.x) / 2.0
	var cy = float(usable.position.y) + float(usable.size.y) / 2.0

	match target:
		GazeTarget.SCREEN_CENTER:
			return Vector2(cx, cy)
		GazeTarget.SCREEN_TOP:
			return Vector2(cx, float(usable.position.y) + float(usable.size.y) * 0.25)
		GazeTarget.SCREEN_BOTTOM:
			return Vector2(cx, float(usable.position.y) + float(usable.size.y) * 0.75)
		GazeTarget.OTHER_MONITOR:
			var screens = DisplayServer.get_screen_count()
			if screens > 1:
				var other_idx = (screen_idx + 1) % screens
				var o_usable = DisplayServer.screen_get_usable_rect(other_idx)
				return Vector2(float(o_usable.position.x) + float(o_usable.size.x) / 2.0, float(o_usable.position.y) + float(o_usable.size.y) / 2.0)
			else:
				# Fake other monitor: look off the edge of the screen
				var my_x = float(_tama_window.position.x) if _tama_window else cx
				if my_x > cx:
					return Vector2(float(usable.position.x) - float(usable.size.x) / 2.0, cy)
				else:
					return Vector2(float(usable.position.x) + float(usable.size.x) * 1.5, cy)
		_:
			return Vector2(cx, cy)

func _look_eyes_at_screen_point(px: float, py: float) -> void:
	"""Orient pupils toward the given screen pixel and accentuate lateral movement."""
	_set_eye_target_from_screen(px, py)
	_eye_target_h = signf(_eye_target_h) * minf(absf(_eye_target_h) * 1.5, 1.0)
	_eye_follow_active = true

func _look_eyes_at_screen_center() -> void:
	"""Look at the dynamic screen center OR the Python-defined subject."""
	var pt = _get_dynamic_target_point(GazeTarget.SCREEN_CENTER)
	if _subject_target.x >= 0:
		pt = Vector2(float(_subject_target.x), float(_subject_target.y))
	_look_eyes_at_screen_point(pt.x, pt.y)

func _look_eyes_at_webcam() -> void:
	"""Look toward the webcam (top center of screen)."""
	var pt = _get_dynamic_target_point(GazeTarget.SCREEN_TOP)
	_look_eyes_at_screen_point(pt.x, pt.y)

func set_gaze(target: GazeTarget, speed: float = 5.0) -> void:
	"""Look at a named preset target. NEUTRAL = fade gaze out (pure animation).
	Screen-based targets (SCREEN_CENTER, TOP, BOTTOM, OTHER_MONITOR) are computed
	dynamically from actual screen resolution — no hardcoded offsets."""
	if not _gaze_active:
		return
	_gaze_lerp_speed = speed
	if target == GazeTarget.NEUTRAL:
		_gaze_target_head = Quaternion.IDENTITY
		_gaze_target_neck = Quaternion.IDENTITY
		_gaze_blend_target = 0.0
	elif target in [GazeTarget.SCREEN_CENTER, GazeTarget.SCREEN_TOP, GazeTarget.SCREEN_BOTTOM, GazeTarget.OTHER_MONITOR]:
		# Dynamic: compute actual screen pixel, then convert to 3D world point
		var pt = _get_dynamic_target_point(target)
		# Override with Python subject when looking at screen center
		if target == GazeTarget.SCREEN_CENTER and _subject_target.x >= 0:
			pt = Vector2(float(_subject_target.x), float(_subject_target.y))
		var target_3d = _screen_to_world(pt.x, pt.y)
		_gaze_world_target = target_3d
		_look_at_world_point(target_3d, speed)
	else:
		# Offset-based targets (USER, BOOK, AWAY)
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
	var win_pos := _tama_window.position if _tama_window else Vector2i.ZERO
	var win_size := _tama_window.size if _tama_window else _BASE_WIN_SIZE
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
	var win_pos := _tama_window.position if _tama_window else Vector2i.ZERO
	var win_size := _tama_window.size if _tama_window else _BASE_WIN_SIZE

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
func _look_at_world_point(target: Vector3, speed: float = 5.0, blend: float = 1.0) -> void:
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
	# Pitch: use proper XZ ground distance (not just Z) so lateral targets
	# don't cause exaggerated head tilt
	var distance_xz: float = Vector2(delta.x, delta.z).length()
	var pitch_rad: float = atan2(delta.y, distance_xz)
	var yaw_deg: float = rad_to_deg(yaw_rad)
	var pitch_deg: float = rad_to_deg(pitch_rad) + GAZE_PITCH_OFFSET_DEG

	# -pitch_deg is required: the bone's Z-FORWARD rotation axis is inverted
	# relative to the geometric pitch, so the negation corrects up/down direction.
	_set_gaze_from_angles(yaw_deg, -pitch_deg, speed, blend)

func set_gaze_at_screen_point(screen_x: float, screen_y: float, speed: float = 8.0) -> void:
	"""Map screen pixel coordinates to 3D world point and look there."""
	if not _gaze_active:
		return
	var target_3d = _screen_to_world(screen_x, screen_y)
	_gaze_world_target = target_3d
	_look_at_world_point(target_3d, speed)

func _set_gaze_from_angles(yaw_deg: float, pitch_deg: float, speed: float, blend: float = 1.0) -> void:
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
	_gaze_blend_target = blend

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

	# Only show debug viz when F3 debug mode is active
	var show_viz: bool = _debug_gaze_mouse
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
