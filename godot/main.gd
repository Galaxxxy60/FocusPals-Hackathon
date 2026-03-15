extends Node3D

# ─── WebSocket ─────────────────────────────────────────────
var ws := WebSocketPeer.new()
var ws_connected := false
var reconnect_timer: float = 0.0

# ─── Tama State (miroir du Python agent) ───────────────────
var suspicion_index: float = 0.0
var state: String = "CALM"
var alignment: float = 1.0
var current_task: String = "travail"
var active_window: String = "Loading..."
var active_duration: int = 0

# ─── Session ───────────────────────────────────────────────
var session_active: bool = false
var session_elapsed_secs: int = 0
var session_duration_secs: int = 3000  # 50 min default
var _break_reminder_was_active: bool = false
var _was_on_break: bool = false
var _break_popup_container: Control = null  # Break decision popup (in _ui_window)
var _break_popup_visible: bool = false

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
var _book_bone_idx: int = -1         # Jnt_L_thumb — used as dynamic BOOK gaze target

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
var _strike_target: Vector2i = Vector2i(-99999, -99999)  # sentinel = use mouse fallback (NOT -1: left monitors have negative coords!)

# ─── Dynamic Subject Gaze ───
# Point of interest set by Python (e.g. a video playing, a browser tab).
# When >= 0, overrides SCREEN_CENTER gaze to look at this exact pixel.
var _subject_target: Vector2i = Vector2i(-99999, -99999)

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
var _bs_appear: int = -1  # BS_Appear: flat pancake at 1.0, normal at 0.0



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
	"E0": Vector3(0, 0.5, 0),         # A3: Neutral (swapped with wink)
	"E1": Vector3(0.5, 0, 0),         # C1: Plissés fort suspicieux
	"E2": Vector3(0.75, 0, 0),        # D1: Fermés
	"E3": Vector3(0.5, 0.25, 0),      # C2: Wide/grands ouverts
	"E4": Vector3(0.75, 0.25, 0),     # D2: Happy
	"E5": Vector3(0.5, 0.5, 0),       # C3: Angry
	"E6": Vector3(0.75, 0.5, 0),      # D3: Semi-closed (blink frame)
	"E7": Vector3(0.5, 0.75, 0),      # C4: Plissés léger malicieux
	"E8": Vector3(0.75, 0.75, 0),     # D4: Furieux
	"E9": Vector3(0, 0, 0),           # A1: Happy Wink (swapped — home position, fully opaque)
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
	# M12: REMOVED — offset y=0.875 causes UV to wrap past y=1.0 → lands on B1 (body texture) = grey mouth!
	# If you need a small "O", use M11 + low jaw instead.
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
var _last_viseme_time: float = 0.0  # Timestamp of last VISEME received (for safety timeout)
const VISEME_TIMEOUT: float = 3.0   # Force mouth reset if no VISEME for this long

# ─── Blink System ────────────────────────────────────────
var _blink_timer: float = 0.0
var _blink_next: float = 4.0  # seconds until next blink
var _blink_phase: int = 0     # 0=idle, 1=closing, 2=closed, 3=opening
var _blink_frame_timer: float = 0.0
const BLINK_FRAME_DURATION: float = 0.03

# ─── Wink System (ghost entrance + post-hello) ────────────
var _wink_active: bool = false           # True while winking
var _wink_delay_timer: float = -1.0      # Countdown before wink starts (<0 = inactive)
var _wink_hold_timer: float = 0.0        # How long to hold the wink
const WINK_GHOST_DELAY: float = 1.0      # Delay before wink during ghost freeze
const WINK_HOLD_DURATION: float = 1.5    # How long to hold wink after materialization

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
# (dead code removed: _eye_saccade_timer, EYE_SACCADE_INTERVAL, EYE_SACCADE_THRESHOLD — unused)
const EYE_RETURN_SPEED: float = 8.0       # Speed to return to center when deactivated

# ─── Micro-saccades (A1: subtle eye tremor — eyes are NEVER perfectly still) ───
var _microsaccade_timer: float = 0.0      # Countdown to next micro-saccade
var _microsaccade_offset_h: float = 0.0   # Current micro-offset horizontal
var _microsaccade_offset_v: float = 0.0   # Current micro-offset vertical
const MICROSACCADE_MIN_INTERVAL: float = 0.3   # Min time between saccades
const MICROSACCADE_MAX_INTERVAL: float = 1.2   # Max time between saccades
const MICROSACCADE_AMPLITUDE: float = 0.06     # Max offset per axis (subtle!)

# ─── Idle Gaze (A2: organic head movement — BOOK/USER only, NEVER screen) ───
# Looking at screen = "I see what you're doing" → only on SCREEN_SCAN from Python
var _idle_gaze_timer: float = 0.0         # Countdown to next idle gaze change
var _idle_gaze_active: bool = false       # True when idle gaze is currently directing the head
const IDLE_GAZE_MIN_INTERVAL: float = 6.0   # Min seconds between idle gaze shifts
const IDLE_GAZE_MAX_INTERVAL: float = 18.0  # Max seconds between idle gaze shifts
const IDLE_GAZE_DURATION_MIN: float = 1.0   # Min duration of an idle glance
const IDLE_GAZE_DURATION_MAX: float = 3.5   # Max duration of an idle glance
var _idle_glance_return_timer: float = 0.0  # Countdown before returning from glance

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
var head_screen_pos: Vector2 = Vector2(-1, -1)  # Head bone projected to 2D (for session timer)

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

# ─── Ghost Materialization Glitch (slower, more dramatic than teleport) ───
const GLITCH_MATERIALIZE_START: float = 3.5   # Higher starting intensity for drama
const GLITCH_MATERIALIZE_FADE_SPEED: float = 3.0  # Slower fade (∼1.2s) for visible transition
var _glitch_materializing_ghost: bool = false  # True during ghost→solid glitch (separate from teleport)

# ─── Ghost Silhouette (Tama appears as hologram, frozen, waiting for voice) ───
var _ghost_active: bool = false              # True while ghost hologram is showing
var _ghost_alpha: float = 0.0               # Current ghost opacity (0→TARGET during ghost, →1.0 during materialize)
var _ghost_materializing: bool = false       # True during ghost→solid fade
var _ghost_fade_in: float = 0.0             # 0→1 fade-in for ghost appearance (shader param)
var _ghost_materials: Array = []             # All StandardMaterial3D refs on Tama mesh
var _ghost_holo_quad: MeshInstance3D = null   # Full-screen quad for hologram shader
var _ghost_holo_material: ShaderMaterial = null  # Hologram shader material
const GHOST_ALPHA_TARGET: float = 0.5        # Hologram alpha (higher since shader provides visual)
const GHOST_FADE_IN_SPEED: float = 2.0       # Speed to fade ghost silhouette in (BS_Appear 1→0)
const GHOST_MATERIALIZE_SPEED: float = 3.0   # Speed to fade from ghost to solid
const GHOST_HOLO_FADE_SPEED: float = 1.2     # Slower hologram fade for smooth transition (∼0.8s)

# ─── User Speaking Acknowledgment ───
var _ack_audio_player: AudioStreamPlayer = null
var _session_ding_player: AudioStreamPlayer = null
var _strike_sfx_player: AudioStreamPlayer = null  # UfoStrike.ogg — synced to impact
var _glitch_sfx_player: AudioStreamPlayer = null  # gltich.ogg — API disconnect "interference"
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


# ─── Gaze Speed Presets (B2: named speeds, no more magic numbers) ───
# These replace raw float values throughout the gaze system
const GAZE_SPEED_SNAP: float = 12.0    # Instant snap (strike fire, suspicion lock)
const GAZE_SPEED_QUICK: float = 7.0    # Fast reaction (scan glance, acknowledgment)
const GAZE_SPEED_NATURAL: float = 4.0  # Normal conversational (talking, looking at user)
const GAZE_SPEED_DRIFT: float = 2.0    # Gentle drift (idle gaze, returning to neutral)
const GAZE_SPEED_LAZY: float = 1.0     # Ultra-slow (bored/tired, deep thought)

# ─── Eyes-Lead-Head (E1: eyes dart ~150ms before head follows) ───
# In real humans, eyes saccade to target in ~20ms, head follows ~100-200ms later
var _eyes_lead_timer: float = 0.0      # Countdown before head starts following
var _eyes_lead_target: GazeTarget = GazeTarget.NEUTRAL  # Deferred head target
var _eyes_lead_speed: float = 4.0      # Deferred head speed
var _eyes_lead_blend: float = 1.0      # Deferred head blend
var _eyes_lead_pending: bool = false    # True when eyes have moved but head hasn't
const EYES_LEAD_DELAY: float = 0.12    # ~120ms delay (natural saccade-head lag)

# ─── Strike Gaze Lock (F2: gaze locked during strike animations) ───
var _strike_gaze_locked: bool = false   # True during strike — blocks idle gaze, overrides
var _strike_gaze_target: GazeTarget = GazeTarget.SCREEN_CENTER

# ─── Conversation Gaze Patterns (C3: organic look patterns during chat) ───
# During conversation: 60% USER, 20% AWAY (thinking), 15% BOOK, 5% drift
var _conv_gaze_timer: float = 0.0       # Countdown to next conversation gaze shift
var _conv_gaze_active: bool = false     # True when conversation gaze is directing head
const CONV_GAZE_MIN_INTERVAL: float = 2.0  # Min seconds between gaze shifts
const CONV_GAZE_MAX_INTERVAL: float = 5.0  # Max seconds

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

# ─── Desktop Awareness (Python Radar) ───
# Python scans all visible OS windows and sends their positions via DESKTOP_MAP.
# Tama uses this to perch on windows, fall when they close/move, etc.
var _desktop_windows: Array = []            # Array of { title, x, y, w, h }
var _perched_on: String = ""                # Title of the window Tama is sitting on ("" = taskbar)
var _perch_check_timer: float = 0.0         # Timer for perch validity checks
const PERCH_CHECK_INTERVAL: float = 0.5     # How often to check if perched window moved/closed
const PERCH_MOVE_THRESHOLD: float = 50.0    # Pixels — if window moved more than this, Tama falls
var _perch_last_rect: Dictionary = {}       # {x, y, w, h} of the window when Tama perched

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
	_setup_strike_sfx()
	_setup_glitch_sfx()
	_setup_greeting_audio()
	call_deferred("_setup_gaze")
	call_deferred("_setup_glitch_effect")  # After _setup_gaze (needs _camera)
	call_deferred("_setup_ghost_hologram") # After _setup_glitch_effect (same camera)
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
	_setup_drone_window()  # Widget Sentinelle (remplace la Main Magique)
	_jarvis_hand = _init_pooled_emoji_window("TamaHand_Jarvis")
	_setup_confetti_window()
	print("🎱 Window pool ready: tama + ui + drone + confetti + jarvis")

func _setup_ui_window() -> void:
	"""Create a dedicated window for all UI menus (radial, settings, quit).
	Always visible but parked off-screen when no UI is open.
	Moving position is free (no DWM lag). Visible toggle only at entrance for z-order."""
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
	# Park off-screen (window stays visible to avoid DWM recreation on show)
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
	var usable := DisplayServer.screen_get_usable_rect(DisplayServer.get_primary_screen())  # Initial position — will be corrected on first reposition
	var x := usable.position.x + usable.size.x - _BASE_WIN_SIZE.x
	var y := usable.position.y + usable.size.y - _BASE_WIN_SIZE.y
	_tama_window.position = Vector2i(x, y)
	_tama_window.set_flag(Window.FLAG_MOUSE_PASSTHROUGH, true)  # Clicks go through to desktop
	_tama_window.visible = false  # Hidden at launch — revealed by START_SESSION/START_CONVERSATION

	# Hide main window — Tama renders in _tama_window now
	# Main window stays alive for script processing but is invisible
	DisplayServer.window_set_size(Vector2i(1, 1))
	DisplayServer.window_set_position(Vector2i(-100, -100))
	print("🪟 Tama window created — main window hidden")

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
		# F2: Release strike gaze lock
		_strike_gaze_locked = false
		# Fade out arm IK — AnimTree state changes don't auto-release IK
		# so we must explicitly release it here
		if _gaze_modifier:
			_gaze_modifier.arm_ik_blend_target = 0.0

	if new_state == "STRIKING":
		_activate_imba(1)
		# F2: Lock gaze on screen during strike animation
		_strike_gaze_locked = true
		set_gaze(GazeTarget.SCREEN_CENTER, GAZE_SPEED_SNAP)

	# ── Gaze follows animation state ──
	if new_state == "WALL_TALK":
		if _suspicion_staring:
			# Suspicion-triggered wall_talk — stare at screen with full side-eye
			set_gaze_with_lead(GazeTarget.SCREEN_CENTER, GAZE_SPEED_NATURAL)
			_look_eyes_at_screen_center()
			_scan_eye_active = true
		elif conversation_active:
			set_gaze_with_lead(GazeTarget.USER, GAZE_SPEED_NATURAL)
		else:
			set_gaze_with_lead(GazeTarget.SCREEN_CENTER, GAZE_SPEED_NATURAL)
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
	# Guard: if drone is already striking, don't fire again
	# (can happen if play_strike() forced restart → _strike_fired resets → re-emits)
	if _drone_state == "STRIKING":
		print("🎯 STRIKE_FIRE skipped — drone already striking")
		return
	# Spawn hand window + arm IK + notify Python (same as existing strike fire logic)
	if _gaze_modifier:
		var aim: Vector2i
		if _strike_target.x > -99990:
			aim = _strike_target
		else:
			aim = DisplayServer.mouse_get_position()
		var target_3d := _screen_to_arm_target(float(aim.x), float(aim.y))
		_gaze_modifier.arm_ik_target = target_3d
		_gaze_modifier.arm_ik_active = true
		_gaze_modifier.arm_ik_blend_target = 1.0
	_spawn_drone_strike()
	print("🎯 STRIKE_FIRE (via AnimTree) — drone strike + arm IK + close signal")
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
	# All UI menus are children of _ui_window
	var ui_parent: Node = _ui_window if _ui_window else self
	radial_menu = RadialMenuScript.new()
	ui_parent.add_child(radial_menu)
	radial_menu.action_triggered.connect(_on_radial_action)
	radial_menu.request_hide.connect(_on_radial_hide)
	settings_panel = SettingsPanelScript.new()
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
	debug_tweaks = DebugTweaksScript.new()
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
				radial_menu.tama_active = session_active or conversation_active
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
	# F7 = Debug Strike: trigger strike via AnimTree + drone strike
	if event is InputEventKey and event.pressed and event.keycode == KEY_F7:
		print("🎯 [DEBUG] F7 → Debug Strike")
		if _anim_tree_module and _anim_tree_module._ready_ok:
			_anim_tree_module.play_strike()
			_show_status_indicator("🎯 Debug Strike (F7)", Color(1, 0.3, 0.3))
	# F10 = Force pause Pomodoro (même effet que cliquer sur le drone ☕)
	if event is InputEventKey and event.pressed and event.keycode == KEY_F10:
		print("⏸️ F10 → Pause Pomodoro manuelle !")
		
		# Activer le drone en mode BREAK_TIMER (feedback visuel immédiat)
		if _drone_window and is_instance_valid(_drone_window):
			_drone_state = "BREAK_TIMER"
			_break_timer_start = Time.get_unix_time_from_system()
			_drone_window.set_flag(Window.FLAG_MOUSE_PASSTHROUGH, false)
			_drone_window.size = Vector2i(180, 140)
			_drone_window.visible = true
			if _drone_screen_label:
				_drone_screen_label.add_theme_font_size_override("font_size", 48)
				_drone_screen_label.add_theme_color_override("font_color", Color(0.5, 1.0, 0.7))
			if _drone_screen_mat:
				_drone_screen_mat.emission = Color(0.1, 0.5, 0.3)
				_drone_screen_mat.emission_energy_multiplier = 1.2
			_drone_play("idle")
		if _confetti_window:
			_confetti_window.visible = false
		
		# 🍅 Envoyer prepare_break — Tama va dire au revoir AVANT de disparaître
		# (Python enverra BREAK_STARTED quand elle aura fini de parler)
		if ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
			ws.send_text(JSON.stringify({"command": "MENU_ACTION", "action": "prepare_break"}))

# ─── Widget Drone (Remplace la Main Magique) ──────────────────
var _drone_window: Window = null
var _drone_state: String = "HIDDEN"  # États : HIDDEN, WAITING_START, TIMER, STRIKING, WAITING_BREAK, BREAK_TIMER
var _break_timer_start: float = 0.0  # Timestamp when break started (for drone countdown)
var _break_timer_duration: float = 300.0  # Break duration in seconds
var _confetti_window: Window = null
var _confetti_rect: ColorRect = null
var _drone_panel: Panel = null        # Fallback 2D (if Wings.glb missing)
var _drone_mesh: MeshInstance3D = null # Wings 3D model
var _drone_model: Node3D = null       # Reference to the Wings 3D root (for scale tweening)
var _drone_screen_mat: StandardMaterial3D = null  # Screen material (slot 1)
var _drone_screen_vp: SubViewport = null          # SubViewport for screen text
var _drone_screen_label: Label = null             # Dynamic text on the screen
var _drone_anim: AnimationPlayer = null           # Wings AnimationPlayer (idle/dash/strike)
var _drone_anim_names: Dictionary = {}            # Resolved anim names
var _drone_glitch_mat: ShaderMaterial = null       # Glitch effect shader material
var _drone_glitch_quad: MeshInstance3D = null       # Glitch quad reference
var _celebration_sfx: AudioStreamPlayer = null      # celebration.ogg player

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
		if old_tween and old_tween.is_valid() and old_tween.is_running():
			old_tween.kill()

	var start := _get_hand_bone_screen_pos()
	var half := win_size / 2

	# Position + show (window already pre-created, minimal DWM cost)
	win.size = Vector2i(win_size, win_size)
	win.position = Vector2i(start.x - half, start.y - half)
	win.visible = true

	var label := win.find_child("EmojiLabel", true, false) as Label
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

func _drone_play(anim_key: String, crossfade: float = 0.2) -> void:
	"""Play a drone animation by key (idle/dash/strike)."""
	if _drone_anim and _drone_anim_names.has(anim_key):
		_drone_anim.play(_drone_anim_names[anim_key], crossfade)

func _spawn_drone_strike() -> void:
	"""Strike : Le drone charge son attaque et fonce sur l'onglet avec un mouvement d'ange !"""
	if _drone_state == "STRIKING":
		return
	_drone_state = "STRIKING"
	if not _drone_window or not is_instance_valid(_drone_window):
		return
	_drone_window.set_flag(Window.FLAG_MOUSE_PASSTHROUGH, true)

	var aim: Vector2i = _strike_target if _strike_target.x > -99990 else DisplayServer.mouse_get_position()

	# Agrandir le modèle 3D pour l'impact
	if _drone_model:
		create_tween().tween_property(_drone_model, "scale", Vector3(1.2, 1.2, 1.2), 0.3).set_trans(Tween.TRANS_SPRING)

	# Mode "Colère"
	if _drone_screen_label:
		_drone_screen_label.add_theme_color_override("font_color", Color(1.0, 0.3, 0.3))
		_drone_screen_label.text = "Ò_Ó"
		_drone_screen_label.add_theme_font_size_override("font_size", 48)
	if _drone_screen_mat:
		_drone_screen_mat.emission = Color(0.8, 0.1, 0.1)
		_drone_screen_mat.emission_energy_multiplier = 3.0
	if _drone_panel:
		var style = _drone_panel.get_theme_stylebox("panel") as StyleBoxFlat
		if style:
			style.border_color = Color(1.0, 0.2, 0.2, 0.9)
			style.shadow_color = Color(1.0, 0.0, 0.0, 0.5)

	_drone_play("idle", 0.1)  # Menacing idle hover

	# ── Strike SFX: end of sound = moment of impact ──
	const IMPACT_TIME: float = 1.6
	if _strike_sfx_player and _strike_sfx_player.stream:
		var sfx_duration: float = _strike_sfx_player.stream.get_length()
		if sfx_duration > IMPACT_TIME:
			_strike_sfx_player.play(sfx_duration - IMPACT_TIME)
		else:
			var sfx_tween := create_tween().bind_node(self)
			sfx_tween.tween_interval(IMPACT_TIME - sfx_duration)
			sfx_tween.tween_callback(func(): if _strike_sfx_player: _strike_sfx_player.play())

	# Couper les anciens tweens de mouvement
	if _drone_window.has_meta("strike_tween"):
		var old_tween = _drone_window.get_meta("strike_tween") as Tween
		if is_instance_valid(old_tween) and old_tween.is_running():
			old_tween.kill()

	var drone_tween := create_tween().bind_node(_drone_window)
	_drone_window.set_meta("strike_tween", drone_tween)

	var start_pos = _drone_window.position
	var half = _drone_window.size / 2
	var dest = Vector2i(aim.x - half.x, aim.y - half.y)

	# Phase 1: Anticipation (Recul vers le haut pour prendre de l'élan)
	var dir = Vector2(dest - start_pos).normalized()
	var recoil_pos = start_pos - Vector2i(dir * 50.0) + Vector2i(0, -60)
	drone_tween.tween_property(_drone_window, "position", recoil_pos, 0.5)\
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	drone_tween.tween_callback(func(): _drone_play("dash", 0.1))

	# Phase 2: Plongeon Foudroyant
	drone_tween.tween_property(_drone_window, "position", dest, 1.1)\
		.set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_IN)

	# Phase 3: Impact !
	drone_tween.tween_callback(func():
		_drone_play("strike", 0.0)
		_deactivate_imba()
		if _drone_screen_label:
			_drone_screen_label.text = "💥"
			_drone_screen_label.add_theme_font_size_override("font_size", 64)
		# Petit shake de l'écran local
		var shake_tw = create_tween()
		for i in range(3):
			shake_tw.tween_property(_drone_window, "position", dest + Vector2i(randi_range(-15, 15), randi_range(-15, 15)), 0.04)
		shake_tw.tween_property(_drone_window, "position", dest, 0.04)
	)

	# Phase 4: Pose de victoire puis retour doux
	drone_tween.tween_interval(1.2)
	drone_tween.tween_callback(func():
		_strike_target = Vector2i(-99999, -99999)
		if session_active:
			_show_drone_timer_mode()
		else:
			_drone_state = "HIDDEN"
			_reset_drone_style()
			_drone_window.visible = false
	)

func _reset_drone_style() -> void:
	"""Reset drone screen to friendly blue/cyan look + idle anim."""
	if _drone_screen_label:
		_drone_screen_label.add_theme_color_override("font_color", Color(0.4, 1.0, 0.7))
		if _drone_state == "TIMER":
			_drone_screen_label.add_theme_font_size_override("font_size", 56)
		else:
			_drone_screen_label.add_theme_font_size_override("font_size", 36)
	if _drone_screen_mat:
		_drone_screen_mat.emission = Color(0.1, 0.4, 0.8)
		_drone_screen_mat.emission_energy_multiplier = 1.5
	if _drone_panel:
		var style = _drone_panel.get_theme_stylebox("panel") as StyleBoxFlat
		if style:
			style.border_color = Color(0.2, 0.8, 1.0, 0.8)
			style.shadow_color = Color(0, 0.5, 1.0, 0.3)
	_drone_play("idle")

func _setup_drone_window() -> void:
	"""Create the Sentinel Drone widget — 3D Wings model with SubViewport screen."""
	_drone_window = Window.new()
	_drone_window.title = "TamaDrone"
	_drone_window.borderless = true
	_drone_window.transparent_bg = true
	_drone_window.always_on_top = true
	_drone_window.unfocusable = true
	_drone_window.transparent = true
	_drone_window.gui_embed_subwindows = false
	_drone_window.size = Vector2i(240, 180)
	_drone_window.process_mode = Node.PROCESS_MODE_ALWAYS  # Ne jamais stopper le processing

	# ── Load Wings.glb 3D model ──
	var wings_scene = load("res://Wings.glb") as PackedScene
	if not wings_scene:
		push_warning("⚠️ Wings.glb not found — drone will use fallback")
		_setup_drone_window_fallback()
		return

	var wings_instance = wings_scene.instantiate()
	_drone_model = wings_instance as Node3D  # Save reference for scale tweening

	# ── Own World3D (no sharing — everything is unshaded) ──
	var drone_world = World3D.new()
	_drone_window.world_3d = drone_world

	# Transparent environment
	var env = Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0, 0, 0, 0)
	var world_env = WorldEnvironment.new()
	world_env.environment = env
	_drone_window.add_child(world_env)

	# ── Camera ──
	var drone_cam = Camera3D.new()
	drone_cam.projection = Camera3D.PROJECTION_PERSPECTIVE
	drone_cam.fov = 50.0
	drone_cam.position = Vector3(0, 0.02, 0.8)
	drone_cam.current = true
	_drone_window.add_child(drone_cam)

	# ── Glitch entrance effect (same shader as Tama) ──
	var glitch_shader = load("res://glitch_effect.gdshader")
	if glitch_shader:
		_drone_glitch_quad = MeshInstance3D.new()
		_drone_glitch_quad.name = "DroneGlitch"
		var quad = QuadMesh.new()
		quad.size = Vector2(10.0, 10.0)
		_drone_glitch_quad.mesh = quad
		_drone_glitch_quad.position = Vector3(0.0, 0.0, -0.5)
		_drone_glitch_mat = ShaderMaterial.new()
		_drone_glitch_mat.shader = glitch_shader
		_drone_glitch_mat.set_shader_parameter("intensity", 0.0)
		_drone_glitch_mat.set_shader_parameter("shake_power", 0.03)
		_drone_glitch_mat.set_shader_parameter("shake_rate", 0.3)
		_drone_glitch_mat.set_shader_parameter("shake_speed", 5.0)
		_drone_glitch_mat.set_shader_parameter("shake_block_size", 30.5)
		_drone_glitch_mat.set_shader_parameter("shake_color_rate", 0.015)
		_drone_glitch_mat.render_priority = 100
		_drone_glitch_quad.material_override = _drone_glitch_mat
		_drone_glitch_quad.visible = false
		drone_cam.add_child(_drone_glitch_quad)
		print("📺 Drone glitch shader ready")

	_drone_window.add_child(wings_instance)

	# ── Resolve animations (dynamic, case-insensitive) ──
	_drone_anim = wings_instance.find_child("AnimationPlayer", true, false) as AnimationPlayer
	if _drone_anim:
		# Force l'AnimationPlayer à toujours processer (même Window non-focusée)
		_drone_anim.callback_mode_process = AnimationPlayer.ANIMATION_CALLBACK_MODE_PROCESS_IDLE
		_drone_anim.process_mode = Node.PROCESS_MODE_ALWAYS
		var anims = _drone_anim.get_animation_list()
		print("🛸 Wings animations (%d): %s" % [anims.size(), str(anims)])
		# Dynamic case-insensitive search for drone-specific anims
		_drone_anim_names.clear()
		for a in anims:
			var al = a.to_lower()
			if ("idle" in al or "hover" in al) and not "wall" in al and not "ground" in al and not "Idle" in a:
				# Lowercase "idle" = Wings idle, not Tama's "Idle"
				_drone_anim_names["idle"] = a
			elif "dash" in al or "fly" in al:
				_drone_anim_names["dash"] = a
			elif "strike" in al or "dab" in al:
				_drone_anim_names["strike"] = a
		# Fallback: if "idle" wasn't found with exact lowercase, try exact match
		if not _drone_anim_names.has("idle") and _drone_anim.has_animation("idle"):
			_drone_anim_names["idle"] = "idle"
		if not _drone_anim_names.has("dash") and _drone_anim.has_animation("Dash"):
			_drone_anim_names["dash"] = "Dash"
		if not _drone_anim_names.has("strike") and _drone_anim.has_animation("Strike_Dab"):
			_drone_anim_names["strike"] = "Strike_Dab"
		# Set idle to loop
		if _drone_anim_names.has("idle"):
			var idle_anim = _drone_anim.get_animation(_drone_anim_names["idle"])
			if idle_anim:
				idle_anim.loop_mode = Animation.LOOP_LINEAR
		_drone_play("idle")
		print("🛸 Anim mapping: %s" % str(_drone_anim_names))

	# ── Debug: print node tree of Wings.glb ──
	print("🛸 Wings.glb node tree:")
	_debug_print_tree(wings_instance, "  ")

	# ── Find the "wings" mesh and its screen material (slot 1) ──
	_drone_mesh = _find_mesh_instance(wings_instance, "wings")
	if not _drone_mesh:
		_drone_mesh = _find_first_mesh(wings_instance)

	if _drone_mesh and _drone_mesh.mesh:
		var surface_count = _drone_mesh.mesh.get_surface_count()
		var aabb = _drone_mesh.mesh.get_aabb()
		print("🛸 Wings mesh: %s | %d surfaces | AABB: %s | size: %s" % [
			_drone_mesh.name, surface_count, str(aabb.position), str(aabb.size)])
		if surface_count > 1:
			_drone_screen_mat = _drone_mesh.get_active_material(1)
			if not _drone_screen_mat:
				_drone_screen_mat = _drone_mesh.mesh.surface_get_material(1)
			if _drone_screen_mat:
				_drone_screen_mat = _drone_screen_mat.duplicate() as StandardMaterial3D
				_drone_mesh.set_surface_override_material(1, _drone_screen_mat)
				print("🛸 Screen material (slot 1): %s" % str(_drone_screen_mat))
			else:
				print("⚠️ No material found at slot 1")
		else:
			print("⚠️ Only %d surface(s) — expected 2+" % surface_count)
	else:
		print("⚠️ Wings mesh NOT found!")

	# ── SubViewport for the dynamic screen text ──
	_drone_screen_vp = SubViewport.new()
	_drone_screen_vp.size = Vector2i(256, 144)  # 16:9
	_drone_screen_vp.transparent_bg = true
	_drone_screen_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_drone_screen_vp.process_mode = Node.PROCESS_MODE_ALWAYS  # Refresh même sans focus

	var screen_bg = ColorRect.new()
	screen_bg.color = Color(0.02, 0.05, 0.08, 0.9)
	screen_bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_drone_screen_vp.add_child(screen_bg)

	_drone_screen_label = Label.new()
	_drone_screen_label.name = "EmojiLabel"
	_drone_screen_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	_drone_screen_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_drone_screen_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_drone_screen_label.add_theme_font_size_override("font_size", 36)
	_drone_screen_label.add_theme_color_override("font_color", Color(0.4, 1.0, 0.7))
	_drone_screen_vp.add_child(_drone_screen_label)

	_drone_window.add_child(_drone_screen_vp)

	# Apply ViewportTexture to the screen material
	if _drone_screen_mat:
		_drone_screen_mat.albedo_texture = _drone_screen_vp.get_texture()
		_drone_screen_mat.emission_enabled = true
		_drone_screen_mat.emission = Color(0.1, 0.4, 0.8)
		_drone_screen_mat.emission_energy_multiplier = 1.5
		_drone_screen_mat.emission_texture = _drone_screen_vp.get_texture()
		print("🛸 Screen material linked to SubViewport texture")

	# ── Click overlay ──
	var click_area = Control.new()
	click_area.set_anchors_preset(Control.PRESET_FULL_RECT)
	click_area.gui_input.connect(_on_drone_gui_input)
	click_area.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_drone_window.add_child(click_area)

	add_child(_drone_window)
	_drone_window.set_flag(Window.FLAG_MOUSE_PASSTHROUGH, true)
	_drone_window.visible = false
	print("🛸 Drone Sentinelle 3D créé (Wings.glb)")

func _debug_print_tree(node: Node, indent: String) -> void:
	"""Print node tree for debugging."""
	var info = "%s%s [%s]" % [indent, node.name, node.get_class()]
	if node is MeshInstance3D:
		var mi = node as MeshInstance3D
		if mi.mesh:
			info += " | %d surfaces | pos=%s" % [mi.mesh.get_surface_count(), str(mi.position)]
	elif node is Node3D:
		info += " | pos=%s" % str((node as Node3D).position)
	print(info)
	for child in node.get_children():
		_debug_print_tree(child, indent + "  ")

func _setup_drone_window_fallback() -> void:
	"""Fallback: 2D panel drone if Wings.glb is missing."""
	_drone_panel = Panel.new()
	_drone_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.05, 0.08, 0.12, 0.95)
	style.border_color = Color(0.2, 0.8, 1.0, 0.8)
	style.set_border_width_all(3)
	style.set_corner_radius_all(20)
	style.shadow_color = Color(0, 0.5, 1.0, 0.3)
	style.shadow_size = 15
	_drone_panel.add_theme_stylebox_override("panel", style)
	_drone_window.add_child(_drone_panel)

	_drone_screen_label = Label.new()
	_drone_screen_label.name = "EmojiLabel"
	_drone_screen_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	_drone_screen_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_drone_screen_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_drone_panel.add_child(_drone_screen_label)

	var click_area = Control.new()
	click_area.set_anchors_preset(Control.PRESET_FULL_RECT)
	click_area.gui_input.connect(_on_drone_gui_input)
	click_area.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_drone_window.add_child(click_area)

	add_child(_drone_window)
	_drone_window.set_flag(Window.FLAG_MOUSE_PASSTHROUGH, true)
	_drone_window.visible = false
	print("🛸 Drone Sentinelle (fallback 2D)")

func _find_mesh_instance(node: Node, mesh_name: String) -> MeshInstance3D:
	"""Recursively find a MeshInstance3D by name (case-insensitive)."""
	if node is MeshInstance3D and node.name.to_lower().contains(mesh_name.to_lower()):
		return node as MeshInstance3D
	for child in node.get_children():
		var found = _find_mesh_instance(child, mesh_name)
		if found:
			return found
	return null

func _find_first_mesh(node: Node) -> MeshInstance3D:
	"""Recursively find the first MeshInstance3D."""
	if node is MeshInstance3D:
		return node as MeshInstance3D
	for child in node.get_children():
		var found = _find_first_mesh(child)
		if found:
			return found
	return null

func _show_drone_start_widget() -> void:
	"""Affiche le widget START au-dessus de la tête de Tama."""
	if not _drone_window or not is_instance_valid(_drone_window):
		return
	_drone_state = "WAITING_START"
	_drone_window.size = Vector2i(240, 180)

	# Look amical (Bleu/Vert)
	_reset_drone_style()

	if _drone_screen_label:
		_drone_screen_label.text = "▶ START"
		_drone_screen_label.add_theme_font_size_override("font_size", 36)
		_drone_screen_label.add_theme_color_override("font_color", Color(0.4, 1.0, 0.7))

	# Positionner juste au-dessus de la tête de Tama
	var tama_center = _get_tama_screen_center()
	_drone_window.position = Vector2i(tama_center.x - 120, tama_center.y - 280)

	_drone_window.set_flag(Window.FLAG_MOUSE_PASSTHROUGH, false)
	# NE PAS toucher à unfocusable ! Le changer dynamiquement sous Windows
	# détruit/recrée la Window native, tuant le contexte de rendu.
	_drone_window.visible = true
	# Relancer l'anim idle (ne tourne pas quand la Window est invisible)
	_drone_play("idle")
	# Glitch d'entrée !
	_drone_entrance_glitch()
	print("🛸 Drone appelé ! En attente de clic...")

func _drone_entrance_glitch() -> void:
	"""Burst de glitch quand le drone apparaît — même shader que Tama."""
	if not _drone_glitch_quad or not _drone_glitch_mat:
		return
	_drone_glitch_quad.visible = true
	_drone_glitch_mat.set_shader_parameter("intensity", 0.0)
	var tw = create_tween().bind_node(self)
	tw.tween_method(func(v): _drone_glitch_mat.set_shader_parameter("intensity", v), 0.0, 1.2, 0.15)
	tw.tween_method(func(v): _drone_glitch_mat.set_shader_parameter("intensity", v), 1.2, 0.0, 0.4)
	tw.tween_callback(func():
		if _drone_glitch_quad:
			_drone_glitch_quad.visible = false
	)

func _drone_exit_glitch() -> void:
	"""Burst de glitch quand le drone disparaît."""
	if not _drone_glitch_quad or not _drone_glitch_mat:
		_drone_window.visible = false
		return
	_drone_glitch_quad.visible = true
	_drone_glitch_mat.set_shader_parameter("intensity", 0.0)
	var tw = create_tween().bind_node(self)
	tw.tween_method(func(v): _drone_glitch_mat.set_shader_parameter("intensity", v), 0.0, 1.5, 0.25)
	tw.tween_callback(func():
		_drone_window.visible = false
		_drone_glitch_mat.set_shader_parameter("intensity", 0.0)
		if _drone_glitch_quad:
			_drone_glitch_quad.visible = false
	)

func _setup_confetti_window() -> void:
	"""Création d'une fenêtre 800x800 pour la célébration de pause via shader de confettis."""
	_confetti_window = Window.new()
	_confetti_window.title = "TamaConfetti"
	_confetti_window.borderless = true
	_confetti_window.transparent_bg = true
	_confetti_window.always_on_top = true
	_confetti_window.unfocusable = true
	_confetti_window.transparent = true
	_confetti_window.gui_embed_subwindows = false
	
	_confetti_rect = ColorRect.new()
	_confetti_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	var shader = load("res://confetti.gdshader")
	if shader:
		var mat = ShaderMaterial.new()
		mat.shader = shader
		_confetti_rect.material = mat
	_confetti_window.add_child(_confetti_rect)
	# Add to tree FIRST — then set display-server-dependent properties
	add_child(_confetti_window)
	_confetti_window.set_flag(Window.FLAG_MOUSE_PASSTHROUGH, true)
	_confetti_window.size = Vector2i(350, 350)  # Zone limitée autour du drone
	_confetti_window.visible = false
	print("🎊 Confetti window setup complete")

func _show_drone_timer_mode() -> void:
	"""Affiche le drone en mode Timer (se réduit et affiche le temps)."""
	if not _drone_window or not is_instance_valid(_drone_window):
		return
	_drone_state = "TIMER"
	# NE PAS utiliser FLAG_MOUSE_PASSTHROUGH ici !
	# Sur Windows, DWM arrête de rafraîchir le contenu visuel d'une Window passthrough,
	# ce qui gèle l'animation ET le SubViewport texte.
	# Le handler _on_drone_gui_input ignore déjà les clics en mode TIMER.
	_drone_window.set_flag(Window.FLAG_MOUSE_PASSTHROUGH, false)
	# unfocusable reste true (valeur initiale) — ne JAMAIS le toggler dynamiquement
	_drone_window.size = Vector2i(180, 140)  # Assez grand pour bien voir le timer
	_drone_window.visible = true
	_reset_drone_style()
	_drone_play("idle")
	# Glitch d'entrée si on ne l'a pas déjà fait
	if not _drone_glitch_quad or not _drone_glitch_quad.visible:
		_drone_entrance_glitch()

func _on_drone_gui_input(event: InputEvent) -> void:
	"""Handle clicks on the drone widget."""
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if _drone_state == "WAITING_START":
			print("▶️ Drone cliqué ! Démarrage de la session...")

			if ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
				ws.send_text(JSON.stringify({"command": "MENU_ACTION", "action": "start_session"}))

			# ── Organic reaction: Tama looks at user + releases arm ──
			set_gaze(GazeTarget.USER, GAZE_SPEED_QUICK)
			_eye_follow_active = false
			if _gaze_modifier:
				_gaze_modifier.arm_ik_blend_target = 0.0

			# Switch to timer mode via new function
			_show_drone_timer_mode()
			if _drone_screen_label:
				_drone_screen_label.text = "--:--"
			print("🛸 Drone → mode TIMER (anims: %s)" % str(_drone_anim_names))
		elif _drone_state == "WAITING_BREAK":
			print("▶️ Drone cliqué ! Démarrage de la pause...")
			# Passer en mode BREAK_TIMER (feedback visuel immédiat)
			_drone_state = "BREAK_TIMER"
			_break_timer_start = Time.get_unix_time_from_system()
			# Garder passthrough=false pour que DWM continue le rendu
			_drone_window.set_flag(Window.FLAG_MOUSE_PASSTHROUGH, false)
			# unfocusable reste true — ne JAMAIS le toggler
			_drone_window.size = Vector2i(180, 140)  # Familier visible
			if _confetti_window:
				_confetti_window.visible = false
			# Style pause (vert/doré doux)
			if _drone_screen_label:
				_drone_screen_label.add_theme_font_size_override("font_size", 48)
				_drone_screen_label.add_theme_color_override("font_color", Color(0.5, 1.0, 0.7))
			if _drone_screen_mat:
				_drone_screen_mat.emission = Color(0.1, 0.5, 0.3)
				_drone_screen_mat.emission_energy_multiplier = 1.2
			# 🍅 Tama va dire au revoir AVANT de disparaître
			# Python enverra BREAK_STARTED quand elle aura fini
			if ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
				ws.send_text(JSON.stringify({"command": "MENU_ACTION", "action": "prepare_break"}))


func _update_drone_timer() -> void:
	"""Flottaison organique du drone (suit Tama) et affichage du Timer/Break."""
	if _drone_state not in ["WAITING_START", "TIMER", "WAITING_BREAK", "BREAK_TIMER"]:
		return
	if not _drone_window or not is_instance_valid(_drone_window):
		return

	var delta = get_process_delta_time()

	# ── Taille du drone ──
	if _drone_model:
		var target_scale: Vector3
		if _drone_state in ["TIMER", "BREAK_TIMER"]:
			target_scale = Vector3(0.75, 0.75, 0.75)  # Familier compact mais visible
		else:
			target_scale = Vector3(1.0, 1.0, 1.0)  # Taille normale
		_drone_model.scale = _drone_model.scale.lerp(target_scale, 5.0 * delta)

	# ── Calcul de la Cible (Au-dessus de la tête) ──
	var target_x: float = 0.0
	var target_y: float = 0.0

	if head_screen_pos.x > 0 and head_screen_pos.y > 0 and _tama_window:
		target_x = float(_tama_window.position.x) + head_screen_pos.x - _drone_window.size.x / 2.0
		target_y = float(_tama_window.position.y) + head_screen_pos.y - _drone_window.size.y - 60.0  # Bien au-dessus de la tête
	else:
		var tama_center = _get_tama_screen_center()
		target_x = float(tama_center.x - _drone_window.size.x / 2.0)
		target_y = float(tama_center.y - 280.0)

	# ── Flottement organique (Mouvement sinusoïdal d'ange) ──
	var time_sec = Time.get_ticks_msec() / 1000.0
	target_y += sin(time_sec * 2.5) * 12.0
	target_x += cos(time_sec * 1.5) * 4.0

	# ── Déplacement Lerp Fluide ──
	var current_pos = Vector2(_drone_window.position)
	var new_pos = current_pos.lerp(Vector2(target_x, target_y), 6.0 * delta)
	if current_pos.distance_to(Vector2(target_x, target_y)) > 600:
		new_pos = Vector2(target_x, target_y)  # Téléportation si Tama a fait un grand bond
	_drone_window.position = Vector2i(new_pos)

	# ── Mise à jour du Texte ──
	if _drone_state == "TIMER":
		# CORRECTION : int() pour éviter le crash du modulo % sur float
		var remaining = int(max(session_duration_secs - session_elapsed_secs, 0))
		var mins = remaining / 60
		var secs = remaining % 60
		if _drone_screen_label:
			_drone_screen_label.text = "%02d:%02d" % [mins, secs]
			if remaining <= 60:
				_drone_screen_label.add_theme_color_override("font_color", Color(1.0, 0.4, 0.4))
			else:
				_drone_screen_label.add_theme_color_override("font_color", Color(0.4, 0.8, 1.0))
		# 🎉 Célébration locale quand le timer atteint zéro !
		if remaining <= 0 and session_elapsed_secs > 0 and not _break_popup_visible:
			if _session_ding_player and _session_ding_player.stream:
				_session_ding_player.play()
			_show_break_popup()
	elif _drone_state == "BREAK_TIMER":
		# Afficher le temps de pause restant
		var elapsed = Time.get_unix_time_from_system() - _break_timer_start
		var remaining_f = maxf(_break_timer_duration - elapsed, 0.0)
		
		# 🛑 FIX POMODORO: Fin du chrono de pause → Retour au bouton START
		if remaining_f <= 0.0:
			if _session_ding_player and _session_ding_player.stream:
				_session_ding_player.play()
			print("⏰ Fin de la pause ! En attente du prochain lancement Pomodoro.")
			
			# Réafficher la fenêtre de Tama pour qu'elle attende avec nous
			_was_on_break = false
			if _tama_window:
				_tama_window.visible = true
			var tama_node = get_node_or_null("Tama")
			if tama_node:
				tama_node.visible = true
				_trigger_entrance()
				
			# Afficher ▶ START et sortir de la fonction
			_show_drone_start_widget()
			return
		
		var mins = int(remaining_f) / 60
		var secs = int(remaining_f) % 60
		if _drone_screen_label:
			_drone_screen_label.text = "☕ %02d:%02d" % [mins, secs]
			# Couleur verte qui évolue
			var progress = clampf(elapsed / _break_timer_duration, 0.0, 1.0)
			var col = Color(0.5, 1.0, 0.7).lerp(Color(0.3, 0.8, 1.0), progress)
			_drone_screen_label.add_theme_color_override("font_color", col)

func _hide_drone_timer() -> void:
	"""Masque le drone avec glitch de sortie (fin de session)."""
	if _drone_state == "HIDDEN":
		return
	_drone_state = "HIDDEN"
	_drone_exit_glitch()
	print("🛸 Drone timer masqué")


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

	# 🟢 Appeler Tama : elle et le drone apparaissent ensemble
	if action_id == "call_tama":
		# Déjà active ? Ignore
		if _drone_state == "WAITING_START" or _drone_state == "TIMER" or session_active or conversation_active:
			print("🛸 Tama déjà là — appel ignoré")
			if radial_menu:
				radial_menu.close()
			_safe_restore_passthrough()
			return
		# 1. Lancer la conversation → Tama arrive avec le glitch
		if ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
			ws.send_text(JSON.stringify({"command": "MENU_ACTION", "action": "talk"}))
		# 2. Drone START apparaît immédiatement
		_show_drone_start_widget()
		if radial_menu:
			radial_menu.close()
		_safe_restore_passthrough()
		return

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
	session_duration_secs = duration * 60  # Sync locally so timer shows correct value immediately
	print("⏱️ Session duration changed: " + str(duration) + " min (" + str(session_duration_secs) + "s)")
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
	"""Park _ui_window off-screen when all UI is closed. Move it on-screen when active.
	Position changes are free (no DWM lag, unlike visible toggle)."""
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

	# Main window always lets clicks through
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_MOUSE_PASSTHROUGH, true)

func _sync_and_show_ui() -> void:
	"""Move UI window to correct position (bottom-right of PRIMARY screen).
	UI always stays on the main monitor even when Tama dodges to another screen.
	No visible toggle (avoids DWM lag). Just position change = instant.
	Z-order was fixed once at entrance (see _trigger_entrance)."""
	if _ui_window:
		var scr_idx := DisplayServer.get_primary_screen()
		var usable := DisplayServer.screen_get_usable_rect(scr_idx)
		var win_size := _tama_window.size if _tama_window else _BASE_WIN_SIZE
		var x := usable.position.x + usable.size.x - win_size.x
		var y := usable.position.y + usable.size.y - win_size.y
		_ui_window.size = win_size
		_ui_window.position = Vector2i(x, y)

func _get_tama_screen_idx() -> int:
	"""Return the screen index where Tama's window currently lives.
	Uses DisplayServer (reliable) instead of Window.current_screen (can misreport on borderless windows)."""
	if _tama_window and is_instance_valid(_tama_window):
		return DisplayServer.window_get_current_screen(_tama_window.get_window_id())
	return DisplayServer.window_get_current_screen()

func _position_window() -> void:
	_reposition_bottom_right()
	call_deferred("_apply_passthrough")

func _reposition_bottom_right() -> void:
	## Anchor Tama window to bottom-right of usable screen area (excludes taskbar)
	if not _tama_window or not is_instance_valid(_tama_window):
		return
	var scr_idx := _get_tama_screen_idx()
	var usable := DisplayServer.screen_get_usable_rect(scr_idx)
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
	if _was_on_break:
		return
	# Don't calculate dodge when Tama is invisible (prevents arming while hidden)
	if not _tama_window or not _tama_window.visible:
		return
	if _glitch_quitting or _glitch_teleporting or _dodge_departing:
		return
	# 🛑 L'ASTUCE : Tama se laisse faire tant que le drone attend le clic !
	if _drone_state == "WAITING_START":
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
	var tw := create_tween().bind_node(self)
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
	var tw := create_tween().bind_node(self)
	tw.tween_interval(0.15)
	tw.tween_callback(func():
		_dodge_departing = false
		_dodge_return()
	)

func _dodge_to_taskbar() -> void:
	"""Move Tama's window to a perch (desktop window) or taskbar fallback + arrival glitch."""
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

	var scr_idx := _get_tama_screen_idx()
	var usable := DisplayServer.screen_get_usable_rect(scr_idx)
	var win_size := _tama_window.size

	var target_x: int
	var target_y: int
	var found_window := false

	# 🎯 PERCH ON A DESKTOP WINDOW
	# Only try if we have a desktop map from Python
	if _desktop_windows.size() > 0:
		# Collect valid perch candidates (non-maximized windows with enough room)
		var candidates: Array = []
		for dwin in _desktop_windows:
			var wx := float(dwin.get("x", 0))
			var wy := float(dwin.get("y", 0))
			var ww := float(dwin.get("w", 0))
			var wh := float(dwin.get("h", 0))
			var title := str(dwin.get("title", ""))

			# Skip: fullscreen/maximized windows (top touches screen edge)
			# These cover the whole screen — perching on top is off-screen
			if wy <= 5:
				continue
			# Skip: too narrow for Tama
			if ww < win_size.x:
				continue
			# Skip: too small vertically (tooltips, thin bars)
			if wh < 150:
				continue

			# Compute perch Y: Tama sits ON TOP of the window title bar
			# Her window bottom aligns with the window's top + a small offset
			# so her feet visually rest on the bar
			var perch_y := int(wy - win_size.y + 50)

			# Must be on-screen (above usable area = off-screen)
			if perch_y < usable.position.y - 30:
				continue

			candidates.append({"data": dwin, "perch_y": perch_y})

		if candidates.size() > 0:
			# Pick a random candidate
			var pick = candidates[randi() % candidates.size()]
			var chosen = pick["data"]
			var cx := float(chosen.get("x", 0))
			var cw := float(chosen.get("w", 0))

			# Center Tama horizontally on the chosen window
			target_x = int(cx + (cw / 2.0) - (win_size.x / 2.0))
			target_y = pick["perch_y"]

			found_window = true
			_perched_on = str(chosen.get("title", ""))
			_perch_last_rect = {
				"x": int(cx), "y": int(chosen.get("y", 0)),
				"w": int(chosen.get("w", 0)), "h": int(chosen.get("h", 0))
			}
			print("⚡ Dodge! Tama se perche sur '%s' → (%d, %d)" % [_perched_on, target_x, target_y])
		else:
			print("🖥️ Desktop map: %d fenêtres, mais aucune perchable" % _desktop_windows.size())
	else:
		print("🖥️ Desktop map vide — pas de radar Python ?")

	# 🏠 FALLBACK: Taskbar area (bottom-left of screen)
	if not found_window:
		target_x = usable.position.x + 20
		target_y = usable.position.y + usable.size.y - win_size.y
		_perched_on = ""
		_perch_last_rect = {}
		print("⚡ Dodge! Taskbar classique → (%d, %d)" % [target_x, target_y])

	# Safety clamp: never go off-screen
	target_x = clampi(target_x, usable.position.x, usable.position.x + usable.size.x - win_size.x)
	target_y = clampi(target_y, usable.position.y - 30, usable.position.y + usable.size.y - win_size.y)

	_tama_window.position = Vector2i(target_x, target_y)

	# Arrival glitch: fade from high intensity → 0 (materialization)
	_glitch_teleporting = true
	_glitch_intensity = GLITCH_TELEPORT_START
	_glitch_target = 0.0
	if _glitch_quad:
		_glitch_quad.visible = true
	if _glitch_material:
		_glitch_material.set_shader_parameter("intensity", _glitch_intensity)

func _update_perch_check(delta: float) -> void:
	"""Check if the window Tama is perched on still exists and hasn't moved.
	If it disappeared or moved, Tama 'falls' to the taskbar."""
	if not _dodge_active or _perched_on == "" or _perch_last_rect.is_empty():
		return
	if not _tama_window or not is_instance_valid(_tama_window):
		return

	_perch_check_timer -= delta
	if _perch_check_timer > 0:
		return
	_perch_check_timer = PERCH_CHECK_INTERVAL

	# Find the window Tama is sitting on in the current desktop map
	var found := false
	for dwin in _desktop_windows:
		if str(dwin.get("title", "")) == _perched_on:
			# Window still exists — check if it moved
			var dx := absf(float(dwin.get("x", 0)) - float(_perch_last_rect.get("x", 0)))
			var dy := absf(float(dwin.get("y", 0)) - float(_perch_last_rect.get("y", 0)))
			if dx > PERCH_MOVE_THRESHOLD or dy > PERCH_MOVE_THRESHOLD:
				# Window moved significantly — Tama falls!
				print("💨 Perch window '%s' moved! Tama tombe !" % _perched_on)
				_fall_to_taskbar()
				return
			else:
				# Window is stable — Tama stays. Update rect in case of small drift.
				_perch_last_rect = {
					"x": int(dwin.get("x", 0)), "y": int(dwin.get("y", 0)),
					"w": int(dwin.get("w", 0)), "h": int(dwin.get("h", 0))
				}
			found = true
			break

	if not found:
		# Window was closed or minimized — Tama falls!
		print("💨 Perch window '%s' disparue ! Tama tombe !" % _perched_on)
		_fall_to_taskbar()

func _fall_to_taskbar() -> void:
	"""Tama falls from her perch to the taskbar area (with glitch effect)."""
	_perched_on = ""
	_perch_last_rect = {}

	if not _tama_window or not is_instance_valid(_tama_window):
		return

	# Departure glitch
	_glitch_intensity = GLITCH_TELEPORT_START
	_glitch_target = GLITCH_TELEPORT_START
	if _glitch_quad:
		_glitch_quad.visible = true
	if _glitch_material:
		_glitch_material.set_shader_parameter("intensity", _glitch_intensity)

	# Brief delay for the glitch, then teleport to taskbar
	var tw := create_tween().bind_node(self)
	tw.tween_interval(0.15)
	tw.tween_callback(func():
		var scr_idx := _get_tama_screen_idx()
		var usable := DisplayServer.screen_get_usable_rect(scr_idx)
		var win_size := _tama_window.size
		var x := usable.position.x + 20
		var y := usable.position.y + usable.size.y - win_size.y
		_tama_window.position = Vector2i(x, y)
		# Arrival glitch
		_glitch_teleporting = true
		_glitch_intensity = GLITCH_TELEPORT_START
		_glitch_target = 0.0
		print("⚡ Fall! Tama atterrit à la taskbar (%d, %d)" % [x, y])
	)

func _dodge_return() -> void:
	"""Move Tama's window back to home (bottom-right) + arrival glitch."""
	_dodge_active = false
	_dodge_armed = false  # Require mouse to leave area again before re-dodge
	_dodge_cooldown_timer = DODGE_COOLDOWN
	_perched_on = ""       # Clear perch state on return
	_perch_last_rect = {}

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
	var factor := maxf(float(_tama_scale_pct) / 100.0, 0.01)
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
	var factor := maxf(float(_tama_scale_pct) / 100.0, 0.01)
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
	_update_ghost_fade(delta)

	# Blink system
	_update_blink(delta)
	# Wink system (ghost entrance + post-hello)
	_update_wink(delta)

	# ── Project head bone to 2D for session timer ──
	if _skeleton and _head_bone_idx >= 0 and _tama_cam:
		var bone_global := _skeleton.global_transform * _skeleton.get_bone_global_pose(_head_bone_idx)
		var screen_pos := _tama_cam.unproject_position(bone_global.origin)
		head_screen_pos = screen_pos

	# UI overlays (status indicator + session timer)
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
			set_gaze(GazeTarget.NEUTRAL, GAZE_SPEED_DRIFT)
			_eye_follow_active = false
			_scan_eye_active = false

	# ─── Eyes-Lead-Head (E1: deferred head follows eyes) ───
	_update_eyes_lead_head(delta)

	# ─── Conversation Gaze (C3: organic shifts during chat) ───
	_update_conversation_gaze(delta)

	# ─── Idle Gaze (A2: organic life — BOOK/USER only, NEVER screen) ───
	_update_idle_gaze(delta)

	# ─── Voice-Sync Entrance Timeout ──────────────────────────
	if _waiting_for_voice:
		_voice_timeout_timer -= delta
		if _voice_timeout_timer <= 0.0:
			print("⏳ Timeout vocal (10s) : Tama entre silencieusement.")
			_trigger_entrance()

	# Sync gaze targets to modifier BEFORE it processes (modifier runs after AnimationPlayer)
	_sync_gaze_to_modifier()

	# ─── Speaking Safety Timeout ──────────────────────────────
	# If _is_speaking is stuck (REST viseme never arrived — API crash, etc.),
	# force-reset the mouth to neutral after VISEME_TIMEOUT seconds.
	if _is_speaking and (Time.get_unix_time_from_system() - _last_viseme_time) > VISEME_TIMEOUT:
		print("⚠️ VISEME timeout (%.1fs) — forcing mouth reset" % VISEME_TIMEOUT)
		_is_speaking = false
		var _mood_mouth_slot = MOOD_MOUTH.get(_current_mood, "M0")
		_set_mouth(_mood_mouth_slot)
		_set_jaw_open(0.0)

	# ─── Mouse Dodge ───────────────────────────────────────────
	_update_mouse_dodge(delta)

	# ─── Perch Check (fall detection) ─────────────────────────
	_update_perch_check(delta)

	# ─── Drone Timer ──────────────────────────────────────────
	_update_drone_timer()

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
	var screen_idx = _get_tama_screen_idx()
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
	"""Smooth eye movement via blend shapes + micro-saccades."""
	if _body_mesh == null:
		return

	# ─── Micro-saccade update (A1: eyes are NEVER perfectly still) ───
	_microsaccade_timer -= delta
	if _microsaccade_timer <= 0:
		# New micro-saccade: tiny random offset
		_microsaccade_offset_h = randf_range(-MICROSACCADE_AMPLITUDE, MICROSACCADE_AMPLITUDE)
		_microsaccade_offset_v = randf_range(-MICROSACCADE_AMPLITUDE, MICROSACCADE_AMPLITUDE)
		_microsaccade_timer = randf_range(MICROSACCADE_MIN_INTERVAL, MICROSACCADE_MAX_INTERVAL)
	else:
		# Decay micro-saccade offset smoothly between pulses
		var decay_t: float = clampf(3.0 * delta, 0.0, 1.0)
		_microsaccade_offset_h = lerpf(_microsaccade_offset_h, 0.0, decay_t)
		_microsaccade_offset_v = lerpf(_microsaccade_offset_v, 0.0, decay_t)

	if _eye_follow_active:
		# Exponential smoothing — near-instant saccade-like dart (speed 15.0)
		var t: float = 1.0 - exp(-15.0 * delta)
		_eye_follow_h = lerpf(_eye_follow_h, _eye_target_h, t)
		_eye_follow_v = lerpf(_eye_follow_v, _eye_target_v, t)
	else:
		# Organic return to center (slower, more natural)
		var t: float = 1.0 - exp(-8.0 * delta)
		_eye_follow_h = lerpf(_eye_follow_h, 0.0, t)
		_eye_follow_v = lerpf(_eye_follow_v, 0.0, t)
	# Compensate for head gaze: reduce eye movement as head turns
	# Low factor (0.3) keeps eyes very expressive even during head turns
	var head_comp: float = 1.0 if _scan_eye_active else (1.0 - (_gaze_blend * 0.3))
	var h: float = _eye_follow_h * head_comp + _microsaccade_offset_h
	var v: float = _eye_follow_v * head_comp + _microsaccade_offset_v
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
	
	# 🛑 FIX: Ignorer les commandes d'action et de surveillance si Tama est en pause
	if _was_on_break and command in ["STRIKE_TARGET", "JARVIS_TAP", "TAMA_ANIM", "TAMA_MOOD", "SCREEN_SCAN", "GAZE_AT", "SET_SUBJECT", "USER_SPEAKING", "VISEME"]:
		return
	
	if command == "QUIT":
		print("👋 Signal QUIT reçu, glitch de fermeture...")
		_start_quit_glitch()
		return
	elif command == "START_SESSION":
		if not session_active:
			session_active = true
			conversation_active = false  # Session overrides conversation
			# Si Tama est déjà visible (mode conversation → upgrade to session),
			# pas besoin de la faire ré-entrer — juste activer la session
			if _started and _tama_window and _tama_window.visible:
				print("🚀 Session lancée ! (Tama déjà présente — upgrade conversation → session)")
				if _session_ding_player:
					_session_ding_player.play()
			else:
				# Silhouette fantôme — se matérialise au premier son de l'IA
				print("🚀 Session lancée ! (Silhouette fantôme — attente voix IA)")
				_show_ghost_silhouette()
		return
	elif command == "START_CONVERSATION":
		if not session_active and not conversation_active:
			conversation_active = true
			_convo_engagement = 0  # Reset engagement counter
			# Silhouette fantôme — se matérialise au premier son de l'IA
			print("💬 Mode conversation ! (Silhouette fantôme — attente voix IA)")
			_show_ghost_silhouette()
		return
	elif command == "BREAK_DEPARTURE":
		# 🍅 Glitch dissolve effect — Tama "teleports" out before the break
		print("🍅 BREAK_DEPARTURE — Glitch dissolve !")
		_glitch_intensity = GLITCH_TELEPORT_START * 1.5  # Extra dramatic
		_glitch_target = GLITCH_TELEPORT_START * 1.5
		if _glitch_quad:
			_glitch_quad.visible = true
		if _glitch_material:
			_glitch_material.set_shader_parameter("intensity", _glitch_intensity)
		# Ramp up glitch then fade Tama out
		var tw := create_tween().bind_node(self)
		tw.tween_interval(0.3)
		tw.tween_callback(func():
			_glitch_target = 0.0  # Start fading the glitch
			var tama_node = get_node_or_null("Tama")
			if tama_node:
				tama_node.visible = false
			if _tama_window:
				_tama_window.visible = false
			print("🍅 Tama disparue (glitch dissolve terminé)")
		)
		return
	elif command == "BREAK_STARTED":
		# 🍅 Python confirms Tama said goodbye + teleported — now set guards
		print("🍅 BREAK_STARTED — Pause activée, guards on !")
		_was_on_break = true
		# Safety: ensure Tama is hidden (in case BREAK_DEPARTURE missed)
		var tama_node = get_node_or_null("Tama")
		if tama_node:
			tama_node.visible = false
		if _tama_window:
			_tama_window.visible = false
		return
	elif command == "SESSION_COMPLETE":
		print("🏁 Session complète — fin de session !")
		session_active = false
		# 🛑 FIX POMODORO: Garder _was_on_break = true si le drone est en mode pause
		if _drone_state != "BREAK_TIMER":
			_was_on_break = false
		
		# 🛑 FIX POMODORO: On ne masque le drone QUE s'il n'est pas déjà en mode Pause ou Attente
		if _drone_state not in ["BREAK_TIMER", "WAITING_START"]:
			_hide_drone_timer()
			
		if _tama_ui:
			_tama_ui.hide_break_overlay()
		if _anim_tree_module:
			if _anim_tree_module.is_standing():
				if _dodge_active:
					_anim_tree_module.sit_ground()
				else:
					_anim_tree_module.return_to_wall()
					
		# Assurer la disparition totale de Tama pendant la pause
		if _drone_state == "BREAK_TIMER":
			var tama_node = get_node_or_null("Tama")
			if tama_node:
				tama_node.visible = false
			if _tama_window:
				_tama_window.visible = false
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
			radial_menu.tama_active = session_active or conversation_active
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
		session_duration_secs = session_duration * 60  # Sync from Python's authoritative value
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
			_subject_target = Vector2i(-99999, -99999)
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
		# Python sends target coordinates (tab/window close button) + window title
		var tx := int(data.get("x", -99999))
		var ty := int(data.get("y", -99999))
		var strike_title := str(data.get("title", ""))
		_strike_target = Vector2i(tx, ty)
		print("🎯 STRIKE_TARGET received: (%d, %d) title='%s'" % [tx, ty, strike_title.left(40)])

		# ── Multi-monitor diagnostic (Godot side) ──
		var scr_count := DisplayServer.get_screen_count()
		for si in range(scr_count):
			var sr := DisplayServer.screen_get_usable_rect(si)
			print("  📐 Godot screen %d: pos=(%d,%d) size=%dx%d" % [si, sr.position.x, sr.position.y, sr.size.x, sr.size.y])

		# ── Desktop Awareness: find the distraction window in our map ──
		# The desktop map gives us reliable coordinates that are consistent
		# with Godot's screen layout (same pygetwindow source as the radar).
		var map_window: Dictionary = {}
		if strike_title != "" and _desktop_windows.size() > 0:
			for dwin in _desktop_windows:
				var dtitle := str(dwin.get("title", ""))
				# Partial match: window titles can be slightly different
				if strike_title.left(30).to_lower() in dtitle.to_lower() or dtitle.to_lower() in strike_title.to_lower():
					map_window = dwin
					print("  🖥️ Found in desktop map: '%s' at (%d,%d) %dx%d" % [
						dtitle.left(30),
						int(dwin.get("x", 0)), int(dwin.get("y", 0)),
						int(dwin.get("w", 0)), int(dwin.get("h", 0))
					])
					break

		# If we found the window in the desktop map, clamp the strike target
		# to the window's actual bounds (prevents off-screen strikes)
		if not map_window.is_empty():
			var mx := int(map_window.get("x", 0))
			var my := int(map_window.get("y", 0))
			var mw := int(map_window.get("w", 0))
			var mh := int(map_window.get("h", 0))
			# Clamp strike target within the window bounds
			tx = clampi(tx, mx, mx + mw)
			ty = clampi(ty, my, my + mh)
			_strike_target = Vector2i(tx, ty)
			print("  🎯 Strike target clamped to window: (%d, %d)" % [tx, ty])

		# ── Teleport Tama to the screen where the distraction is ──
		# So the user sees her when she strikes (not stuck on another monitor)
		if _tama_window and is_instance_valid(_tama_window) and tx > -99990 and ty > -99990:
			var screen_count := DisplayServer.get_screen_count()
			var target_screen := -1

			# Strategy 1: Use desktop map window center to find screen
			if not map_window.is_empty():
				var wcx := int(map_window.get("x", 0)) + int(map_window.get("w", 0)) / 2
				var wcy := int(map_window.get("y", 0)) + int(map_window.get("h", 0)) / 2
				for i in range(screen_count):
					var screen_rect := DisplayServer.screen_get_usable_rect(i)
					if wcx >= screen_rect.position.x and wcx < screen_rect.position.x + screen_rect.size.x \
					   and wcy >= screen_rect.position.y and wcy < screen_rect.position.y + screen_rect.size.y:
						target_screen = i
						print("  📐 Desktop map → distraction on screen %d" % i)
						break

			# Strategy 2: Fall back to raw strike coordinates
			if target_screen < 0:
				for i in range(screen_count):
					var screen_rect := DisplayServer.screen_get_usable_rect(i)
					if tx >= screen_rect.position.x and tx < screen_rect.position.x + screen_rect.size.x \
					   and ty >= screen_rect.position.y and ty < screen_rect.position.y + screen_rect.size.y:
						target_screen = i
						print("  📐 Raw coords → distraction on screen %d" % i)
						break

			# Strategy 3: Ultimate fallback = primary screen
			if target_screen < 0:
				target_screen = DisplayServer.get_primary_screen()
				print("  ⚠️ Could not match any screen — fallback to primary (%d)" % target_screen)

			var target_rect := DisplayServer.screen_get_usable_rect(target_screen)
			var win_size := _tama_window.size
			# Bottom-right of the TARGET screen
			var new_x := target_rect.position.x + target_rect.size.x - win_size.x
			var new_y := target_rect.position.y + target_rect.size.y - win_size.y
			# Safety clamp
			new_x = clampi(new_x, target_rect.position.x, target_rect.position.x + target_rect.size.x - win_size.x)
			new_y = clampi(new_y, target_rect.position.y, target_rect.position.y + target_rect.size.y - win_size.y)

			var old_pos := _tama_window.position
			if old_pos != Vector2i(new_x, new_y):
				_tama_window.position = Vector2i(new_x, new_y)
				# Glitch effect for teleport
				_glitch_teleporting = true
				_glitch_intensity = GLITCH_TELEPORT_START
				_glitch_target = 0.0
				if _glitch_quad:
					_glitch_quad.visible = true
				if _glitch_material:
					_glitch_material.set_shader_parameter("intensity", _glitch_intensity)
				print("⚡ STRIKE TELEPORT! Tama → screen %d (%d, %d)" % [target_screen, new_x, new_y])
		return
	elif command == "JARVIS_TAP":
		# Jarvis mode: Tama's hand gently taps the target (not a strike — an assist)
		var jtx := int(data.get("x", -1))
		var jty := int(data.get("y", -1))
		var jaction: String = data.get("action", "")
		print("🤖 JARVIS_TAP: (%d, %d) action=%s" % [jtx, jty, jaction])
		if jtx >= 0 and jty >= 0:
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
		# ── Intensity-based expression fade ──
		# When mood is decaying (low intensity), fall back to neutral mouth
		# to prevent "stuck open mouth" bug (M6 Huh, M5 grimace lingering)
		if mood_intensity < 0.3 and mouth_key != "M0" and mouth_key != "M4":
			# Low intensity: expressive mouths (grimaces, Huh) → neutral
			# M4 (smile) is gentle enough to keep at low intensity
			mouth_key = "M0"
		# Eyes also soften at low intensity (except calm/curious which are already neutral)
		if mood_intensity < 0.25 and mood_name not in ["calm", "curious"]:
			eye_key = "E0"  # Return to neutral eyes during decay
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
		_last_viseme_time = Time.get_unix_time_from_system()  # Reset safety timeout
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
			# Safety: some mood mouths are "open" shapes (grimace, Huh, furious)
			# that look wrong when Tama isn't speaking. Fall back to neutral.
			var safe_mouth = _current_mouth_slot
			if safe_mouth in ["M5", "M6", "M8"]:
				# Open/grimace mouths → neutral when not speaking
				safe_mouth = "M0"
			_set_mouth(safe_mouth)
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
			# Amplitude-based mouth selection using painted texture slots
			# B3 (M9/M10) and B4 (M11) are valid. M12 removed (UV wraps to B1 body = grey)
			if shape == "AH":
				if amp > 0.6:
					mouth_slot = "M2"   # D1: A grand ouvert (loud)
				elif amp > 0.3:
					mouth_slot = "M9"   # B3 haut: A ouvert moyen
				else:
					mouth_slot = "M10"  # B3 bas: A ouvert petit (quiet)
			elif shape == "OH":
				if amp > 0.6:
					mouth_slot = "M1"   # C1: O grand ouvert (loud)
				else:
					mouth_slot = "M11"  # B4 haut: O moyen (covers medium+quiet)
			# EE_TEETH stays M3 (from VISEME_MAP)
			_set_mouth(mouth_slot)
			# Jaw open = base amount per viseme × amplitude
			var base_jaw: float = JAW_OPEN_MAP.get(shape, 0.3)
			_set_jaw_open(base_jaw * clampf(amp, 0.2, 1.0))
		return
	elif command == "DESKTOP_MAP":
		# Python sends a map of all visible OS windows
		_desktop_windows = data.get("windows", [])
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
	# NOTE: PLAY_STRIKE removed — Python sends TAMA_ANIM with anim="Strike" instead.
	# The old handler was dead code (never sent by Python) and risked double-triggers.
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

	# ── Session ding + break popup when timer hits zero ──
	var break_reminder: bool = data.get("break_reminder", false)
	if break_reminder and not _break_reminder_was_active:
		if _session_ding_player and _session_ding_player.stream:
			_session_ding_player.play()
			print("🔔 Session ding!")
		# Show break decision popup
		_show_break_popup()
	elif not break_reminder and _break_reminder_was_active:
		# Break reminder cleared (user accepted/refused via tray or popup)
		_hide_break_popup()
	_break_reminder_was_active = break_reminder

	# ── Break overlay: show/hide based on is_on_break state ──
	var on_break: bool = data.get("is_on_break", false)
	if on_break and not _was_on_break:
		# Break just started
		var next_break_at = data.get("next_break_at", null)
		var break_dur_min: float = 5.0
		var sess_dur := session_duration_secs / 60
		if sess_dur <= 30: break_dur_min = 5.0
		elif sess_dur <= 60: break_dur_min = 10.0
		elif sess_dur <= 120: break_dur_min = 15.0
		else: break_dur_min = 20.0
		
		# 🛑 FIX: Nettoyer l'ancien voile bleu de pause (ne JAMAIS l'afficher)
		if _tama_ui:
			_tama_ui.hide_break_overlay()
			
		# 🛑 FIX: S'assurer que le drone de pause s'affiche bien
		# (utile si la pause est déclenchée depuis le tray Python)
		if _drone_state != "BREAK_TIMER":
			_drone_state = "BREAK_TIMER"
			_break_timer_start = Time.get_unix_time_from_system()
			_break_timer_duration = break_dur_min * 60.0
			if _drone_window and is_instance_valid(_drone_window):
				_drone_window.set_flag(Window.FLAG_MOUSE_PASSTHROUGH, false)
				_drone_window.size = Vector2i(180, 140)
				_drone_window.visible = true
			if _confetti_window:
				_confetti_window.visible = false
			if _drone_screen_label:
				_drone_screen_label.add_theme_font_size_override("font_size", 48)
				_drone_screen_label.add_theme_color_override("font_color", Color(0.5, 1.0, 0.7))
			if _drone_screen_mat:
				_drone_screen_mat.emission = Color(0.1, 0.5, 0.3)
				_drone_screen_mat.emission_energy_multiplier = 1.2
			_drone_play("idle")
			
		if _session_ding_player and _session_ding_player.stream:
			_session_ding_player.play()
			
		# 🛑 FIX: Masquer la fenêtre de Tama TOUTE ENTIÈRE
		# Détruit le voile bleu + empêche les interactions souris résiduelles
		var tama_node = get_node_or_null("Tama")
		if tama_node:
			tama_node.visible = false
		if _tama_window:
			_tama_window.visible = false
			
		print("☕ Break started! (%.0f min), Tama est partie en pause" % break_dur_min)
		
	elif not on_break and _was_on_break:
		# Break ended — hide overlay
		if _tama_ui:
			_tama_ui.hide_break_overlay()
		if _session_ding_player and _session_ding_player.stream:
			_session_ding_player.play()
			
		# Hide the drone break timer
		if _drone_state == "BREAK_TIMER":
			_drone_state = "HIDDEN"
			_drone_exit_glitch()
			
		# Réafficher la fenêtre de Tama à son retour
		if _tama_window:
			_tama_window.visible = true
		var tama_node = get_node_or_null("Tama")
		if tama_node:
			tama_node.visible = true
			_trigger_entrance() # Replay WalkIn/Teleport if possible or just appear
			
		print("💪 Break ended — back to work!")
	_was_on_break = on_break

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
	if _was_on_break:
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
				elif bs_name == "BS_Appear":
					_bs_appear = bs_i
					_body_mesh = mesh_inst
					print("  ✨ BS_Appear found (index %d) — ghost unfold ready!" % bs_i)
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
	# Don't blink while winking
	if _wink_active:
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


func _update_wink(delta: float) -> void:
	"""Handles timed wink: delay → activate → hold → restore."""
	if not _expression_ready:
		return

	# Phase 1: Countdown delay before wink starts
	if _wink_delay_timer > 0.0:
		_wink_delay_timer -= delta
		if _wink_delay_timer <= 0.0:
			_wink_delay_timer = -1.0
			_wink_active = true
			_wink_hold_timer = 999.0  # Hold indefinitely until materialization resets it
			# Apply wink expression (E9 + hide left iris)
			_apply_eye_offset("E9")
			if _body_mesh:
				if _bs_hide_left_eye >= 0:
					_body_mesh.set_blend_shape_value(_bs_hide_left_eye, 1.0)   # Left: hidden (wink)
				if _bs_hide_right_eye >= 0:
					_body_mesh.set_blend_shape_value(_bs_hide_right_eye, 0.0)  # Right: visible
			if _mouth_material and MOUTH_OFFSETS.has("M4"):
				_mouth_material.uv1_offset = MOUTH_OFFSETS["M4"]
			print("😉 Clin d'œil (E9 + hide left iris)")
		return

	# Phase 2: Wink is active — count down hold timer
	if _wink_active:
		_wink_hold_timer -= delta
		if _wink_hold_timer <= 0.0:
			# Wink done — restore normal expression
			_wink_active = false
			_apply_eye_offset(_current_eye_slot)
			var hide_val: float = PUPIL_HIDE_AMOUNT.get(_current_eye_slot, 0.0)
			_set_pupil_hide(hide_val)
			if _mouth_material and MOUTH_OFFSETS.has(_current_mouth_slot):
				_mouth_material.uv1_offset = MOUTH_OFFSETS[_current_mouth_slot]
			print("😉 Clin d'œil terminé — retour expression normale")


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


func _setup_ghost_hologram() -> void:
	"""Create a second camera quad for the ghost hologram shader.
	Works like the glitch quad but with the hologram effect."""
	var target_cam: Camera3D = _tama_cam if _tama_cam else _camera
	if target_cam == null:
		push_warning("⚠️ Ghost hologram: No camera found")
		return

	var holo_shader = load("res://ghost_hologram.gdshader")
	if not holo_shader:
		push_warning("⚠️ ghost_hologram.gdshader not found")
		return

	_ghost_holo_quad = MeshInstance3D.new()
	_ghost_holo_quad.name = "HologramQuad"
	var quad := QuadMesh.new()
	quad.size = Vector2(10.0, 10.0)
	_ghost_holo_quad.mesh = quad
	# Slightly closer than glitch quad so hologram renders on top
	_ghost_holo_quad.position = Vector3(0.0, 0.0, -0.9)

	_ghost_holo_material = ShaderMaterial.new()
	_ghost_holo_material.shader = holo_shader
	_ghost_holo_material.set_shader_parameter("intensity", 0.0)
	_ghost_holo_material.set_shader_parameter("holo_color", Color(0.3, 0.9, 1.0, 1.0))
	_ghost_holo_material.set_shader_parameter("desaturation", 0.85)
	_ghost_holo_material.set_shader_parameter("scanline_count", 180.0)
	_ghost_holo_material.set_shader_parameter("scanline_strength", 0.25)
	_ghost_holo_material.set_shader_parameter("flicker_speed", 8.0)
	_ghost_holo_material.set_shader_parameter("flicker_amount", 0.08)
	_ghost_holo_material.set_shader_parameter("aberration", 0.002)
	_ghost_holo_material.set_shader_parameter("glitch_rate", 0.05)
	_ghost_holo_material.set_shader_parameter("glitch_strength", 0.02)
	_ghost_holo_material.set_shader_parameter("edge_glow", 1.2)
	_ghost_holo_material.set_shader_parameter("ghost_alpha", 0.35)
	_ghost_holo_material.set_shader_parameter("tint_strength", 0.5)
	_ghost_holo_material.set_shader_parameter("fade_in", 1.0)
	_ghost_holo_material.set_shader_parameter("scan_edge", 0.03)
	_ghost_holo_material.render_priority = 99  # Just below glitch quad
	_ghost_holo_quad.material_override = _ghost_holo_material

	_ghost_holo_quad.layers = TAMA_LAYER_BIT
	target_cam.add_child(_ghost_holo_quad)
	_ghost_holo_quad.visible = false
	print("👻 Ghost hologram shader ready on %s" % target_cam.name)

func _set_glitch_active(active: bool) -> void:
	if _glitch_quitting:
		return  # Don't interrupt quit sequence
	if _glitch_teleporting:
		return  # Don't interrupt teleport arrival sequence
	_glitch_target = 1.0 if active else 0.0
	if active and _glitch_quad:
		_glitch_quad.visible = true
		# 🔊 Play glitch SFX — masks the abrupt voice cutoff
		if _glitch_sfx_player and _glitch_sfx_player.stream:
			_glitch_sfx_player.play()
		print("📺 Glitch ON — API disconnected (SFX played)")
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
	elif _glitch_materializing_ghost:
		# Ghost materialization: slower, more dramatic fade from high→0
		_glitch_intensity = maxf(_glitch_intensity - GLITCH_MATERIALIZE_FADE_SPEED * delta, 0.0)
		_glitch_material.set_shader_parameter("intensity", _glitch_intensity)
		if _glitch_intensity < 0.001:
			_glitch_materializing_ghost = false
			_glitch_intensity = 0.0
			_glitch_target = 0.0
			if _glitch_quad:
				_glitch_quad.visible = false
			print("📺 Ghost glitch complete — Tama materialized")
	elif _glitch_teleporting:
		# Teleport arrival: fast fade from high intensity → 0
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
	If ghost is active, triggers materialization (ghost → solid + glitch + Hello play).
	Otherwise, does the classic instant entrance."""
	if not _waiting_for_voice:
		return
	_waiting_for_voice = false
	_hide_status_indicator()

	# ── Ghost materialization path ──
	if _ghost_active:
		_materialize_from_ghost()
		print("✨ Matérialisation ! Tama sort de sa silhouette fantôme.")
		return

	# ── Classic entrance (fallback if no ghost was shown) ──
	# 1. Force window visible + position
	if _tama_window:
		_tama_window.visible = true
		_tama_window.set_flag(Window.FLAG_MOUSE_PASSTHROUGH, true)
		if _ui_window:
			_ui_window.visible = false
			_ui_window.visible = true
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
	var audio_file = null
	var file_name = ""
	if FileAccess.file_exists("res://tama_hello.wav"):
		audio_file = load("res://tama_hello.wav")
		file_name = "tama_hello.wav"
	elif FileAccess.file_exists("res://tama_hello.mp3"):
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


func _show_ghost_silhouette() -> void:
	"""Show Tama as a holographic ghostly silhouette, frozen on Hello frame 0.
	Uses ALPHA_HASH on materials for noise dissolve + hologram shader for CRT look."""
	_waiting_for_voice = true
	_voice_timeout_timer = 15.0

	# 1. Force window visible + position
	if _tama_window:
		_tama_window.visible = true
		_tama_window.set_flag(Window.FLAG_MOUSE_PASSTHROUGH, true)
		if _ui_window:
			_ui_window.visible = false
			_ui_window.visible = true
		if not _dodge_active:
			_reposition_bottom_right()

	# 3. Tama visible but FLAT (BS_Appear=1.0) — hologram shader does ghostly look
	var tama_node = get_node_or_null("Tama")
	if tama_node:
		tama_node.visible = true
	if _body_mesh and _bs_appear >= 0:
		_body_mesh.set_blend_shape_value(_bs_appear, 1.0)  # Flat like a pancake
	_ghost_alpha = 0.0  # Tracks unfold progress (0=flat, 1=full 3D)

	# Freeze spring bones during ghost (conflict with flat geometry)
	if _gaze_modifier:
		_gaze_modifier.ghost_freeze = true

	# 4. Freeze AnimTree at Hello frame 0
	if _anim_tree_module and _anim_tree_module._ready_ok:
		_anim_tree_module.freeze_hello_pose()

	# 5. Activate hologram shader at full intensity
	if _ghost_holo_material and _ghost_holo_quad:
		_ghost_holo_material.set_shader_parameter("intensity", 1.0)
		_ghost_holo_material.set_shader_parameter("fade_in", 1.0)
		_ghost_holo_quad.visible = true

	# 6. Activate ghost mode — _update_ghost_fade will animate BS_Appear 1→0
	_ghost_active = true
	_ghost_materializing = false

	# 7. Show status indicator
	_show_status_indicator("Connexion neuronale...", Color(0.3, 0.9, 1.0, 0.9))

	# Grace period
	_dodge_cooldown_timer = 10.0
	_dodge_armed = false
	print("👻 Hologram ALPHA_HASH activé — dissolution progressive...")

	# 8. Wink immédiat (E9 + hide left iris)
	_wink_delay_timer = -1.0
	_wink_active = true
	_wink_hold_timer = 999.0
	_apply_eye_offset("E9")  # Wink (A1, home position)
	if _body_mesh:
		if _bs_hide_left_eye >= 0:
			_body_mesh.set_blend_shape_value(_bs_hide_left_eye, 1.0)   # Left iris: hidden (wink)
		if _bs_hide_right_eye >= 0:
			_body_mesh.set_blend_shape_value(_bs_hide_right_eye, 0.0)  # Right iris: visible
	if _mouth_material and MOUTH_OFFSETS.has("M4"):
		_mouth_material.uv1_offset = MOUTH_OFFSETS["M4"]  # Smile
	# Correct gaze: Hello anim rotates Tama, so push iris toward camera
	if _body_mesh and _bs_look_right >= 0:
		_body_mesh.set_blend_shape_value(_bs_look_right, 0.4)  # Adjust value as needed
	print("😉 Clin d'œil (E9 + hide left iris + look right)")


func _materialize_from_ghost() -> void:
	"""Transition from hologram ghost to full materialized Tama.
	Triggered by TAMA_VOICE_READY or first non-REST VISEME."""
	_ghost_active = false
	_ghost_materializing = true  # Hologram shader fades via _update_ghost_fade

	# 1. Ensure Tama is fully unfolded
	if _body_mesh and _bs_appear >= 0:
		_body_mesh.set_blend_shape_value(_bs_appear, 0.0)

	# Unfreeze spring bones + reset physics
	if _gaze_modifier:
		_gaze_modifier.ghost_freeze = false
	if _spring_bones_node and _spring_bones_node.has_method("reset_physics"):
		_spring_bones_node.reset_physics()

	# 2. Start glitch effect (fast teleport style)
	if _glitch_material and _glitch_quad:
		_glitch_teleporting = true
		_glitch_materializing_ghost = false
		_glitch_intensity = GLITCH_TELEPORT_START
		_glitch_target = 0.0
		_glitch_material.set_shader_parameter("intensity", _glitch_intensity)
		_glitch_quad.visible = true

	# 3. Unfreeze AnimTree and play Hello
	if _anim_tree_module and _anim_tree_module._ready_ok:
		_anim_tree_module.unfreeze_and_play_hello()
	_started = true
	_last_anim_command_time = Time.get_unix_time_from_system()

	# Grace period for Hello anim
	_dodge_cooldown_timer = 5.0
	_dodge_armed = false

	# Reset spring bone physics
	if _spring_bones_node and _spring_bones_node.has_method("reset_physics"):
		_spring_bones_node.reset_physics()

	print("✨ MATÉRIALISATION ! Glitch + hologram fade-out + Hello anim")

	# ── Onboarding: gaze + point at drone, nudge if no click ──
	# The drone is a separate Window but we convert its screen position
	# to 3D via _screen_to_world / _screen_to_arm_target (same as strikes)
	if _drone_state == "WAITING_START" and _drone_window and _drone_window.visible:
		var tw = create_tween().bind_node(self)
		tw.tween_interval(2.0)  # Beat after Hello anim
		tw.tween_callback(func():
			if _drone_state != "WAITING_START" or not _drone_window or not _drone_window.visible:
				return
			# Drone center in screen coords
			var dc = _drone_window.position + Vector2i(_drone_window.size.x / 2, _drone_window.size.y / 2)
			var sx: float = float(dc.x)
			var sy: float = float(dc.y)

			# Head gaze → drone screen position
			_look_at_world_point(_screen_to_world(sx, sy), GAZE_SPEED_NATURAL)
			_gaze_blend_target = 0.8

			# Arm IK → point at drone (same conversion as strikes)
			if _gaze_modifier:
				_gaze_modifier.arm_ik_target = _screen_to_arm_target(sx, sy)
				_gaze_modifier.arm_ik_active = true
				_gaze_modifier.arm_ik_blend_target = 0.7

			# Eyes → drone
			_look_eyes_at_screen_point(sx, sy)
			print("☝️ Tama montre le drone (screen→3D)")
		)
		# Gaze drifts back to user — arm stays up until click
		tw.tween_interval(3.0)
		tw.tween_callback(func():
			set_gaze(GazeTarget.USER, GAZE_SPEED_DRIFT)
			_eye_follow_active = false
		)
		# Nudge after 30s if user still hasn't clicked
		tw.tween_interval(25.0)  # 2 + 3 + 25 = 30s total
		tw.tween_callback(func():
			if _drone_state == "WAITING_START":
				if ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
					ws.send_text(JSON.stringify({
						"command": "ONBOARDING_NUDGE",
						"context": "user_not_clicked_start"
					}))
					print("⏰ Onboarding nudge — user hasn't clicked Start")
		)

	# Keep wink active during materialization, hold for WINK_HOLD_DURATION
	_wink_delay_timer = -1.0  # Cancel any pending delay
	_wink_active = true
	_wink_hold_timer = WINK_HOLD_DURATION


func _collect_tama_materials() -> void:
	"""Scan Tama's mesh hierarchy and collect all StandardMaterial3D refs.
	Also stores original transparency mode for correct restore after ghost."""
	_ghost_materials.clear()
	_ghost_original_transparency.clear()
	var tama = get_node_or_null("Tama")
	if not tama:
		return
	_scan_materials_recursive(tama)
	print("👻 Collected %d materials for ghost effect" % _ghost_materials.size())


var _ghost_original_transparency: Dictionary = {}  # Material → original BaseMaterial3D.Transparency


func _scan_materials_recursive(node: Node) -> void:
	"""Recursively find all StandardMaterial3D on MeshInstance3D nodes."""
	if node is MeshInstance3D:
		var mesh_inst: MeshInstance3D = node as MeshInstance3D
		for i in range(mesh_inst.get_surface_override_material_count()):
			var mat = mesh_inst.get_surface_override_material(i)
			if mat is StandardMaterial3D and mat not in _ghost_materials:
				_ghost_materials.append(mat)
				_ghost_original_transparency[mat] = (mat as StandardMaterial3D).transparency
		# Also check mesh materials (if no override)
		if mesh_inst.mesh:
			for i in range(mesh_inst.mesh.get_surface_count()):
				var mat = mesh_inst.mesh.surface_get_material(i)
				if mat is StandardMaterial3D and mat not in _ghost_materials:
					_ghost_materials.append(mat)
					_ghost_original_transparency[mat] = (mat as StandardMaterial3D).transparency
	for child in node.get_children():
		_scan_materials_recursive(child)


# _set_tama_alpha() REMOVED — dead code. Ghost alpha is managed by _update_ghost_fade() directly.


func _update_ghost_fade(delta: float) -> void:
	"""Handles:
	1. Ghost appearance: BS_Appear 1→0 (unfold from flat to 3D)
	2. Materialization: hologram intensity 1→0"""
	if _ghost_active:
		# Animate BS_Appear from 1→0 (unfold)
		if _ghost_alpha < 1.0 and _body_mesh and _bs_appear >= 0:
			_ghost_alpha = minf(_ghost_alpha + GHOST_FADE_IN_SPEED * delta, 1.0)
			_body_mesh.set_blend_shape_value(_bs_appear, 1.0 - _ghost_alpha)
	elif _ghost_materializing:
		# Fade hologram shader intensity from 1→0
		if _ghost_holo_material:
			var holo_intensity: float = _ghost_holo_material.get_shader_parameter("intensity")
			holo_intensity = maxf(holo_intensity - GHOST_HOLO_FADE_SPEED * delta, 0.0)
			_ghost_holo_material.set_shader_parameter("intensity", holo_intensity)
			if holo_intensity < 0.001:
				_ghost_materializing = false
				_ghost_holo_material.set_shader_parameter("intensity", 0.0)
				if _ghost_holo_quad:
					_ghost_holo_quad.visible = false
				print("👻 Hologram fade complete — Tama fully solid")
		else:
			_ghost_materializing = false

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
	# Reset spring bone physics to prevent velocity explosion from position discontinuity
	if _spring_bones_node and _spring_bones_node.has_method("reset_physics"):
		_spring_bones_node.reset_physics()
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

func _setup_strike_sfx() -> void:
	_strike_sfx_player = AudioStreamPlayer.new()
	var audio_file = load("res://UfoStrike.ogg")
	if audio_file:
		_strike_sfx_player.stream = audio_file
		_strike_sfx_player.volume_db = -3.0  # Prominent but not overwhelming
		print("🔊 UfoStrike.ogg loaded (%.1fs)" % audio_file.get_length())
	else:
		push_warning("⚠️ UfoStrike.ogg not found")
	add_child(_strike_sfx_player)

func _setup_glitch_sfx() -> void:
	_glitch_sfx_player = AudioStreamPlayer.new()
	var audio_file = load("res://gltich.ogg")
	if audio_file:
		_glitch_sfx_player.stream = audio_file
		_glitch_sfx_player.volume_db = -6.0  # Noticeable but not harsh
		print("🔊 gltich.ogg loaded (%.1fs)" % audio_file.get_length())
	else:
		push_warning("⚠️ gltich.ogg not found")
	add_child(_glitch_sfx_player)

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
		# ANTI-SNAP: Just fade the blend — no quaternion reset
		_gaze_blend_target = 0.0
		_eye_follow_active = false
	elif target in [GazeTarget.SCREEN_CENTER, GazeTarget.SCREEN_TOP, GazeTarget.SCREEN_BOTTOM, GazeTarget.OTHER_MONITOR]:
		# Dynamic: compute actual screen pixel, then convert to 3D world point
		var pt = _get_dynamic_target_point(target)
		if target == GazeTarget.SCREEN_CENTER and _subject_target.x > -99990:
			pt = Vector2(float(_subject_target.x), float(_subject_target.y))
		var target_3d = _screen_to_world(pt.x, pt.y)
		_gaze_world_target = target_3d
		_look_at_world_point(target_3d, speed, max_blend)
		_look_eyes_at_screen_point(pt.x, pt.y)  # Eyes dart instantly
	else:
		var target_point: Vector3
		if target == GazeTarget.BOOK:
			target_point = _get_book_world_pos()
		else:
			var head_pos = _get_head_world_pos()
			var offset = GAZE_PRESET_OFFSETS.get(target, Vector3(0, 0, 2))
			target_point = head_pos + offset
		_gaze_world_target = target_point
		_look_at_world_point(target_point, speed, max_blend)
	# Immediate sync to modifier (don't wait for next _process)
	_sync_gaze_to_modifier()

# ─── Idle Gaze System (A2) ──────────────────────────────────
# Makes Tama feel alive when nothing is happening.
# Rules:
#   - She looks at her BOOK (Jnt_L_thumb) most of the time → she's reading
#   - Occasionally glances at USER → she's aware you're there
#   - NEVER looks at the SCREEN during idle → that means "I see what you're doing"
#   - Screen gaze is EXCLUSIVELY driven by Python SCREEN_SCAN events

func _is_idle_gaze_eligible() -> bool:
	"""Check if idle gaze should be active (Tama is resting, not busy)."""
	if not _gaze_active or not _started:
		return false
	if _was_on_break:
		return false
	if _is_speaking or _suspicion_staring:
		return false
	if _strike_gaze_locked:         # F2: gaze locked during strike
		return false
	if _eyes_lead_pending:           # E1: eyes-lead-head in progress
		return false
	if conversation_active:
		return false
	if _scan_glance_timer > 0 or _scan_eye_active:
		return false
	if _ack_gaze_timer > 0:
		return false
	if _debug_gaze_mouse:
		return false
	# Only when on the wall or on the ground (idle poses)
	if _anim_tree_module:
		var st = _anim_tree_module.current_state
		# ON_WALL=0, ON_GROUND=6 are the idle states
		if st != 0 and st != 6:
			return false
	return true

func _update_idle_gaze(delta: float) -> void:
	"""Organic idle gaze: subtle head movements between BOOK and USER."""
	if not _is_idle_gaze_eligible():
		# Not eligible — reset timers so we start fresh when idle resumes
		if _idle_gaze_active:
			_idle_gaze_active = false
			_idle_glance_return_timer = 0.0
		return

	# Return timer: currently doing an idle glance, waiting to return
	if _idle_glance_return_timer > 0:
		_idle_glance_return_timer -= delta
		if _idle_glance_return_timer <= 0:
			_idle_gaze_active = false
			# Soft return to neutral (animation takes over)
			set_gaze(GazeTarget.NEUTRAL, 1.5)
		return

	# Countdown to next idle gaze shift
	_idle_gaze_timer -= delta
	if _idle_gaze_timer > 0:
		return

	# ─── Trigger new idle glance ───
	_idle_gaze_timer = randf_range(IDLE_GAZE_MIN_INTERVAL, IDLE_GAZE_MAX_INTERVAL)
	var duration: float = randf_range(IDLE_GAZE_DURATION_MIN, IDLE_GAZE_DURATION_MAX)
	_idle_glance_return_timer = duration
	_idle_gaze_active = true

	# Weighted random: BOOK 70%, USER 25%, micro-drift 5%
	var roll: float = randf()
	if roll < 0.70:
		# BOOK — she's reading, gentle downward look toward Jnt_L_thumb
		set_gaze_subtle(GazeTarget.BOOK, GAZE_SPEED_DRIFT, 0.35)
	elif roll < 0.95:
		# USER — eyes dart first, head follows (E1 eyes-lead-head)
		set_gaze_with_lead(GazeTarget.USER, GAZE_SPEED_DRIFT, 0.25)
	else:
		# MICRO-DRIFT — tiny random head offset (musculature noise)
		var tiny_yaw: float = randf_range(-3.0, 3.0)
		var tiny_pitch: float = randf_range(-2.0, 2.0)
		_set_gaze_from_angles(tiny_yaw, tiny_pitch, 1.0, 0.15)
	_sync_gaze_to_modifier()

# ─── Eyes-Lead-Head System (E1) ─────────────────────────────
# Human eyes saccade to target in ~20ms, head follows ~120ms later.
# This creates the "eyes dart, then head follows" look.

func _update_eyes_lead_head(delta: float) -> void:
	"""Process deferred head movement after eyes have already darted."""
	if not _eyes_lead_pending:
		return
	_eyes_lead_timer -= delta
	if _eyes_lead_timer > 0:
		return
	# Timer expired — fire the deferred head gaze
	_eyes_lead_pending = false
	if _eyes_lead_target == GazeTarget.NEUTRAL:
		_gaze_blend_target = 0.0
	else:
		# Replay the gaze command with head-only (eyes already there)
		if _eyes_lead_blend < 1.0:
			set_gaze_subtle(_eyes_lead_target, _eyes_lead_speed, _eyes_lead_blend)
		else:
			set_gaze(_eyes_lead_target, _eyes_lead_speed)
	_sync_gaze_to_modifier()

func set_gaze_with_lead(target: GazeTarget, speed: float = GAZE_SPEED_NATURAL, blend: float = 1.0) -> void:
	"""Eyes dart immediately, head follows after EYES_LEAD_DELAY.
	For screen targets, eyes saccade to the screen pixel instantly."""
	if not _gaze_active:
		return
	# 1. Eyes dart IMMEDIATELY
	if target in [GazeTarget.SCREEN_CENTER, GazeTarget.SCREEN_TOP, GazeTarget.SCREEN_BOTTOM, GazeTarget.OTHER_MONITOR]:
		var pt = _get_dynamic_target_point(target)
		if target == GazeTarget.SCREEN_CENTER and _subject_target.x > -99990:
			pt = Vector2(float(_subject_target.x), float(_subject_target.y))
		_look_eyes_at_screen_point(pt.x, pt.y)
	elif target == GazeTarget.USER:
		_look_eyes_at_webcam()
	elif target == GazeTarget.NEUTRAL:
		_eye_follow_active = false

	# 2. Queue head movement after delay
	_eyes_lead_target = target
	_eyes_lead_speed = speed
	_eyes_lead_blend = blend
	_eyes_lead_timer = EYES_LEAD_DELAY
	_eyes_lead_pending = true

# ─── Conversation Gaze Patterns (C3) ───────────────────────
# During conversation: organic shifts between USER/AWAY/BOOK
# Makes Tama feel engaged and thoughtful instead of staring blankly.

func _update_conversation_gaze(delta: float) -> void:
	"""Organic gaze shifts during active conversation."""
	if not conversation_active or not _gaze_active or not _started:
		_conv_gaze_active = false
		return
	if _strike_gaze_locked or _suspicion_staring:
		return  # Don't override strike/suspicion
	if not _is_speaking and not conversation_active:
		return

	_conv_gaze_timer -= delta
	if _conv_gaze_timer > 0:
		return

	# ─── New conversation gaze shift ───
	_conv_gaze_timer = randf_range(CONV_GAZE_MIN_INTERVAL, CONV_GAZE_MAX_INTERVAL)
	_conv_gaze_active = true

	# Weighted random: USER 60%, AWAY 20%, BOOK 15%, drift 5%
	var roll: float = randf()
	if roll < 0.60:
		# Look at user — active listening/speaking
		set_gaze_subtle(GazeTarget.USER, GAZE_SPEED_NATURAL, 0.5)
	elif roll < 0.80:
		# Look away — "thinking" (averts gaze while formulating thoughts)
		set_gaze_subtle(GazeTarget.AWAY, GAZE_SPEED_DRIFT, 0.3)
	elif roll < 0.95:
		# Glance at book — brief reference
		set_gaze_subtle(GazeTarget.BOOK, GAZE_SPEED_DRIFT, 0.25)
	else:
		# Micro-drift — processing
		var tiny_yaw: float = randf_range(-4.0, 4.0)
		var tiny_pitch: float = randf_range(-2.0, 2.0)
		_set_gaze_from_angles(tiny_yaw, tiny_pitch, GAZE_SPEED_LAZY, 0.2)
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

	# Find Head, Neck, Right Hand, and Book bones
	for i in range(_skeleton.get_bone_count()):
		var bname = _skeleton.get_bone_name(i).to_lower()
		if bname == "head":
			_head_bone_idx = i
		elif bname == "neck":
			_neck_bone_idx = i
		elif bname == "jnt_r_hand":
			_strike_hand_bone_idx = i
		elif bname == "jnt_l_thumb":
			_book_bone_idx = i

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
	if _book_bone_idx >= 0:
		print("📖 Book bone [%d] '%s' — dynamic BOOK gaze target!" % [_book_bone_idx, _skeleton.get_bone_name(_book_bone_idx)])
	else:
		print("⚠️ Jnt_L_thumb NOT FOUND — BOOK gaze uses static offset")

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
const GAZE_PITCH_OFFSET_DEG: float = -8.0

# Preset targets → 3D world offsets from head (X=right, Y=up, Z=toward camera)
# These are relative to the head bone position
# Used ONLY for targets that don't map to a screen point (USER, BOOK, AWAY)
# BOOK is dynamic when _book_bone_idx is found (uses Jnt_L_thumb world pos)
var GAZE_PRESET_OFFSETS = {
	GazeTarget.USER: Vector3(0, 0.3, 2.0),            # Slightly up toward user (webcam is above screen)
	GazeTarget.BOOK: Vector3(-0.3, -0.8, 0.5),         # Down in front (fallback if bone not found)
	GazeTarget.AWAY: Vector3(2.0, 0.2, -0.5),          # Behind to the right
}

func _get_book_world_pos() -> Vector3:
	"""Get the BOOK target position from Jnt_L_thumb bone, or fallback to offset."""
	if _book_bone_idx >= 0 and _skeleton != null:
		return (_skeleton.global_transform * _skeleton.get_bone_global_pose(_book_bone_idx)).origin
	# Fallback: offset from head
	var head_pos = _get_head_world_pos()
	return head_pos + GAZE_PRESET_OFFSETS.get(GazeTarget.BOOK, Vector3(-0.3, -0.8, 0.5))

# ─── Dynamic Subject Gaze Helpers ───────────────────────────
func _get_dynamic_target_point(target: GazeTarget) -> Vector2:
	"""Compute the screen pixel for a gaze target based on Tama's actual screen."""
	var screen_idx = _get_tama_screen_idx()
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
	"""Orient pupils toward the given screen pixel — accentuated for expressiveness."""
	_set_eye_target_from_screen(px, py)
	# Exaggerate eye movement (2x) so pupils visibly dart to corners
	_eye_target_h = signf(_eye_target_h) * minf(absf(_eye_target_h) * 2.0, 1.0)
	_eye_target_v = signf(_eye_target_v) * minf(absf(_eye_target_v) * 2.0, 1.0)
	_eye_follow_active = true

func _look_eyes_at_screen_center() -> void:
	"""Look at the dynamic screen center OR the Python-defined subject."""
	var pt = _get_dynamic_target_point(GazeTarget.SCREEN_CENTER)
	if _subject_target.x > -99990:
		pt = Vector2(float(_subject_target.x), float(_subject_target.y))
	_look_eyes_at_screen_point(pt.x, pt.y)

func _look_eyes_at_webcam() -> void:
	"""Look toward the webcam (top center of screen)."""
	var pt = _get_dynamic_target_point(GazeTarget.SCREEN_TOP)
	_look_eyes_at_screen_point(pt.x, pt.y)

func set_gaze(target: GazeTarget, speed: float = 5.0) -> void:
	"""Look at a named preset target. NEUTRAL = fade gaze out (pure animation).
	Screen-based targets use dynamic screen resolution. Anti-snap: NEUTRAL only
	fades blend instead of resetting target quaternions."""
	if not _gaze_active:
		return
	_gaze_lerp_speed = speed
	if target == GazeTarget.NEUTRAL:
		# ANTI-SNAP: Don't reset target quaternions to IDENTITY!
		# Just fade the blend — the head glides back to pure animation.
		_gaze_blend_target = 0.0
		_eye_follow_active = false
	elif target in [GazeTarget.SCREEN_CENTER, GazeTarget.SCREEN_TOP, GazeTarget.SCREEN_BOTTOM, GazeTarget.OTHER_MONITOR]:
		# Dynamic: compute actual screen pixel, then convert to 3D world point
		var pt = _get_dynamic_target_point(target)
		# Override with Python subject when looking at screen center
		if target == GazeTarget.SCREEN_CENTER and _subject_target.x > -99990:
			pt = Vector2(float(_subject_target.x), float(_subject_target.y))
		var target_3d = _screen_to_world(pt.x, pt.y)
		_gaze_world_target = target_3d
		_look_at_world_point(target_3d, speed)
		_look_eyes_at_screen_point(pt.x, pt.y)  # Eyes dart instantly to screen target
	else:
		# Offset-based targets (USER, BOOK, AWAY)
		var target_point: Vector3
		if target == GazeTarget.BOOK:
			target_point = _get_book_world_pos()
		else:
			var head_pos = _get_head_world_pos()
			var offset = GAZE_PRESET_OFFSETS.get(target, Vector3(0, 0, 2))
			target_point = head_pos + offset
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
	# Pass _tama_window as render target so CanvasLayers (arc, status, break)
	# are drawn on Tama's visible window, NOT the hidden main window (1x1 off-screen).
	_tama_ui.setup(self, _tama_window)

func _show_status_indicator(text: String, color: Color) -> void:
	if _tama_ui:
		_tama_ui.show_status(text, color)

func _hide_status_indicator() -> void:
	if _tama_ui:
		_tama_ui.hide_status()

# ─── Break Decision Popup ─────────────────────────────────────
# Shown on _ui_window when break_reminder activates (timer hits zero).
# Two buttons: Accept break / Continue working.

func _show_break_popup() -> void:
	if _break_popup_visible:
		return
	_break_popup_visible = true

	# Replace old UI popup with Sentinelle Drone + Confetti
	if not _drone_window or not is_instance_valid(_drone_window):
		return
	_drone_state = "WAITING_BREAK"
	_drone_window.size = Vector2i(240, 180)

	# Compute break duration for later countdown
	var sess_dur := session_duration_secs / 60
	if sess_dur <= 30:
		_break_timer_duration = 5.0 * 60.0
	elif sess_dur <= 60:
		_break_timer_duration = 10.0 * 60.0
	elif sess_dur <= 120:
		_break_timer_duration = 15.0 * 60.0
	else:
		_break_timer_duration = 20.0 * 60.0

	# Look amical orange/doré
	if _drone_screen_label:
		_drone_screen_label.text = "☕ PAUSE"
		_drone_screen_label.add_theme_font_size_override("font_size", 36)
		_drone_screen_label.add_theme_color_override("font_color", Color(1.0, 0.8, 0.4))
	if _drone_screen_mat:
		_drone_screen_mat.emission = Color(0.8, 0.5, 0.1)
		_drone_screen_mat.emission_energy_multiplier = 1.5

	# Positionner au-dessus de la tête de Tama
	var tama_center = _get_tama_screen_center()
	var dx = tama_center.x - 120
	var dy = tama_center.y - 280
	_drone_window.position = Vector2i(dx, dy)
	_drone_window.set_flag(Window.FLAG_MOUSE_PASSTHROUGH, false)
	# unfocusable reste true — ne JAMAIS le toggler sous Windows
	_drone_window.visible = true
	_drone_play("idle")
	_drone_entrance_glitch()

	# 🎉 Son de célébration
	if not _celebration_sfx:
		_celebration_sfx = AudioStreamPlayer.new()
		var sfx = load("res://celebration.ogg")
		if sfx:
			_celebration_sfx.stream = sfx
			_celebration_sfx.volume_db = -5.0
		add_child(_celebration_sfx)
	if _celebration_sfx and _celebration_sfx.stream:
		_celebration_sfx.play()

	# Confetti retardé de 1s pour sync avec le burst audio
	if _confetti_window and is_instance_valid(_confetti_window):
		_confetti_window.position = Vector2i(dx + 120 - 175, dy + 90 - 175)  # Centré sur le drone
		var confetti_tw = create_tween()
		confetti_tw.tween_interval(1.0)
		confetti_tw.tween_callback(func():
			if _confetti_window and is_instance_valid(_confetti_window):
				_confetti_window.visible = true
		)

	print("🎉 Célébration ! Son + Confetti (1s delay)")


func _hide_break_popup() -> void:
	if not _break_popup_visible:
		return
	_break_popup_visible = false

	# Masquer le drone si on ne l'a pas déjà cliqué
	if _drone_state in ["WAITING_BREAK", "BREAK_TIMER"]:
		_drone_state = "HIDDEN"
		_drone_exit_glitch()

	if _confetti_window and is_instance_valid(_confetti_window):
		_confetti_window.visible = false

	print("☕ Drone Pause hidden")


func _on_break_accept() -> void:
	# Called if fallback UI was still used, not used with drone currently
	print("☕ Break accepted!")
	_hide_break_popup()
	if ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		ws.send_text(JSON.stringify({"command": "ACCEPT_BREAK"}))


func _on_break_refuse() -> void:
	print("💪 Break refused — keep working!")
	_hide_break_popup()
	if ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		ws.send_text(JSON.stringify({"command": "REFUSE_BREAK"}))

