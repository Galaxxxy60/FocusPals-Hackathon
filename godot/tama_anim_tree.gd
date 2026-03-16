# tama_anim_tree.gd — Programmatic AnimationTree for Tama
#
# Replaces the Phase enum + _play()/_play_reverse() in main.gd.
# Uses Godot's native AnimationTree + AnimationNodeStateMachine,
# configured 100% from code (no editor needed).
#
# Usage from main.gd:
#   var tree = load("res://tama_anim_tree.gd").new()
#   add_child(tree)
#   tree.setup(tama_node, anim_player, skeleton)
#   tree.leave_wall()              # Wall → OffThewall → Standing
#   tree.set_standing_anim("suspicious")
#   tree.play_strike()             # Strike sequence
#   tree.return_to_wall()          # Reverse OffThewall → Wall

extends Node

# ─── Signals ──────────────────────────────────────────────────
signal state_changed(old_state: String, new_state: String)
signal strike_fire_point()        # Bone trigger detected → fire hand
signal off_wall_complete()        # OffThewall forward done → now standing
signal strike_sequence_started()  # Strike sequence just kicked off

# ─── States ───────────────────────────────────────────────────
enum State { OFF_SCREEN, ON_WALL, WALL_TALK, LEAVING_WALL, STANDING, RETURNING_WALL, STRIKING,
	ON_GROUND, GROUND_TALK, LEAVING_GROUND, SITTING_GROUND, STAND_TALK, LYING, LIE_TALK }
var current_state: int = State.OFF_SCREEN

# ─── Internals ────────────────────────────────────────────────
var _tree: AnimationTree = null
var _player: AnimationPlayer = null
var _playback = null  # AnimationNodeStateMachinePlayback
var _skeleton: Skeleton3D = null
var _tama_node: Node = null
var _ready_ok: bool = false

# Resolved GLB animation names (handles prefixes like "F ")
var _names: Dictionary = {}

# What we're looking for → what GLB might call it
const WANTED = {
	"idle_wall": "Idle_wall",
	"idle_wall_talk": "Idle_wall_Talk",
	"idle_wall_hair": "Idle_wall_HairAction",
	"off_wall": "OffThewall",
	"idle": "Idle",
	"suspicious": "Suspicious",
	"angry": "Angry",
	"strike_base": "Strike_Base",
	"walk_in": "WalkIn",
	"go_away": "GoAway",
	"idle_ground": "Idle_ground",
	"idle_ground_talk": "Idle_ground_talk",
	"idle_ground_standup": "Idle_ground_StandUp",
	"hello": "Hello",
	"stand_talk": "StandTalk",
	"idle_lie": "Idle_lie",
	"idle_lie_talk": "Idle_lie_talk",
	"idle_wall_thinks": "Idle_wall_Thinks",
	"idle_wall_write": "Idle_wall_write",
	"idle_ground_thinks": "Idle_ground_Thinks",
	"idle_ground_write": "Idle_ground_write",
}

# Which animations should loop
const LOOPS = ["idle_wall", "idle", "idle_ground", "idle_lie", "idle_wall_write", "idle_ground_write"]

# ─── Strike Sync (animation-position trigger) ─────────────────────
# Configure at which SECOND in the animation the hand should fire.
# Change these values to match your animation timing in Blender.
# Example: if the punch lands at frame 18 in a 30fps anim → 18/30 = 0.6
const STRIKE_FIRE_AT: Dictionary = {
	"strike_base": 0.7,   # ← CHANGE THIS to match your animation!
}
const STRIKE_FIRE_FALLBACK: float = 0.7  # Default if anim not in dict above
var _strike_fired: bool = false
var _strike_frames: int = 0
var _strike_time: float = 0.0

# Track SM node for change detection
var _prev_node: String = ""

# ─── Onboarding Hold ──────────────────────────────────────
# When true, Tama stays STANDING after Hello→idle instead of auto-returning to wall.
# Set by main.gd during onboarding flow, cleared by ONBOARDING_DONE.
var onboarding_hold: bool = false

# ─── Random Idle Hair Fix Timer ────────────────────────────
var _idle_hair_timer: float = 0.0
const IDLE_HAIR_MIN_CD: float = 20.0   # Min seconds between hair fixes
const IDLE_HAIR_MAX_CD: float = 60.0   # Max seconds between hair fixes

# ─── Random Thinks Timer (wall & ground) ────────────────
var _idle_thinks_timer: float = 0.0
const IDLE_THINKS_MIN_CD: float = 30.0  # Min seconds before random thinks
const IDLE_THINKS_MAX_CD: float = 90.0  # Max seconds before random thinks
var _thinks_write_timer: float = 0.0    # Timer for write phase inside thinks
const THINKS_WRITE_DELAY: float = 3.0   # Seconds in thinks pose before starting write
const THINKS_WRITE_DURATION: float = 8.0 # How long she writes before reversing out
var _in_thinks_chain: bool = false       # True during thinks/write sequence

# ─── Lying random chance ────────────────────────────────
const LIE_PROBABILITY: float = 0.3       # 30% chance to lie instead of sit

# ─── Crossfade durations per transition type ─────────────────
const XFADE_TRANSITION: float = 0.15   # Wall ↔ OffThewall
const XFADE_MOOD: float = 0.25         # Between standing anims
const XFADE_STRIKE: float = 0.1        # Into/out of strike
const XFADE_CHAIN: float = 0.05        # Strike_Base → Strike_Dab
const XFADE_WALL_TALK: float = 0.2     # idle_wall ↔ idle_wall_talk

# ═══════════════════════════════════════════════════════════════
#                         SETUP
# ═══════════════════════════════════════════════════════════════

func setup(tama_node: Node, anim_player: AnimationPlayer, skeleton: Skeleton3D = null) -> bool:
	_player = anim_player
	_skeleton = skeleton
	_tama_node = tama_node

	if not _player:
		push_warning("🎬 AnimTree: No AnimationPlayer!")
		return false

	# 1. Resolve real names from GLB
	var avail := _player.get_animation_list()
	var found := 0
	for key in WANTED:
		var real := _match_anim(avail, WANTED[key])
		if real != "":
			_names[key] = real
			found += 1
		else:
			push_warning("🎬 AnimTree: '%s' not found" % WANTED[key])
	if found < 3:
		push_warning("🎬 AnimTree: Only %d/9 anims found, aborting" % found)
		return false
	print("🎬 AnimTree: Resolved %d/%d anims: %s" % [found, WANTED.size(), str(_names)])

	# 2. Set loop modes on Animation resources
	for key in _names:
		var anim := _player.get_animation(_names[key])
		if anim:
			if key in LOOPS:
				anim.loop_mode = Animation.LOOP_LINEAR
			else:
				anim.loop_mode = Animation.LOOP_NONE

	# 3. Build the AnimationTree
	_build_tree()

	# 4. Strike fire — now uses animation position (see STRIKE_FIRE_AT)
	# No bone detection needed!

	_ready_ok = true
	print("🎬 AnimTree: ✅ Ready!")
	return true


func _match_anim(available, target: String) -> String:
	var t := target.to_lower()
	# Pass 1: exact
	for a in available:
		if String(a).to_lower() == t:
			return String(a)
	# Pass 2: substring
	for a in available:
		var al := String(a).to_lower()
		if al != "eeee" and t in al:
			return String(a)
	return ""


func _build_tree() -> void:
	# Create the StateMachine root
	var sm := AnimationNodeStateMachine.new()

	# ── Add animation nodes ──
	var positions := {
		"idle_wall": Vector2(0, 100),
		"idle_wall_talk": Vector2(0, -50),
		"idle_wall_talk_return": Vector2(0, -150),
		"idle_wall_hair": Vector2(-100, 200),
		"off_wall": Vector2(200, 100),
		"idle": Vector2(400, 0),
		"suspicious": Vector2(400, 100),
		"angry": Vector2(400, 200),
		"return_wall": Vector2(200, 250),
		"strike_base": Vector2(600, 100),
		"walk_in": Vector2(-200, 100),
		"go_away": Vector2(-200, -100),
		# Ground sitting (mirror of wall system)
		"idle_ground": Vector2(800, 100),
		"idle_ground_talk": Vector2(800, -50),
		"idle_ground_talk_return": Vector2(800, -150),
		"idle_ground_standup": Vector2(600, 0),
		"sit_ground": Vector2(600, 250),  # reverse standup
		# Hello (startup greeting)
		"hello": Vector2(-400, 0),
		# StandTalk (talking while standing)
		"stand_talk": Vector2(400, -100),
		"stand_talk_return": Vector2(400, -200),
		# Lying (alternative ground pose)
		"idle_lie": Vector2(1000, 100),
		"idle_lie_talk": Vector2(1000, -50),
		"idle_lie_talk_return": Vector2(1000, -150),
		# Wall Thinks/Write chain
		"idle_wall_thinks": Vector2(-100, -100),
		"idle_wall_thinks_return": Vector2(-100, -200),
		"idle_wall_write": Vector2(-200, -100),
		# Ground Thinks/Write chain
		"idle_ground_thinks": Vector2(800, -200),
		"idle_ground_thinks_return": Vector2(800, -300),
		"idle_ground_write": Vector2(900, -200),
	}

	for key in _names:
		var node := AnimationNodeAnimation.new()
		node.animation = _names[key]
		sm.add_node(key, node, positions.get(key, Vector2.ZERO))

	# Reverse OffThewall for return-to-wall
	if _names.has("off_wall"):
		var rev := AnimationNodeAnimation.new()
		rev.animation = _names["off_wall"]
		rev.play_mode = AnimationNodeAnimation.PLAY_MODE_BACKWARD
		sm.add_node("return_wall", rev, positions["return_wall"])

	# Reverse Idle_wall_Talk for return from talking pose
	if _names.has("idle_wall_talk"):
		var rev_talk := AnimationNodeAnimation.new()
		rev_talk.animation = _names["idle_wall_talk"]
		rev_talk.play_mode = AnimationNodeAnimation.PLAY_MODE_BACKWARD
		sm.add_node("idle_wall_talk_return", rev_talk, positions.get("idle_wall_talk_return", Vector2.ZERO))

	# ── Add transitions ──

	# Wall ↔ OffThewall
	_add_trans(sm, "idle_wall", "off_wall", XFADE_TRANSITION)
	_add_trans(sm, "off_wall", "idle_wall", XFADE_TRANSITION)

	# OffThewall → standing anims (auto-advance to idle by default)
	_add_trans(sm, "off_wall", "idle", XFADE_MOOD, true)  # auto after off_wall ends
	_add_trans(sm, "off_wall", "suspicious", XFADE_MOOD)
	_add_trans(sm, "off_wall", "angry", XFADE_MOOD)

	# Between standing anims (mood changes)
	for from_key in ["idle", "suspicious", "angry"]:
		for to_key in ["idle", "suspicious", "angry"]:
			if from_key != to_key:
				_add_trans(sm, from_key, to_key, XFADE_MOOD)

	# ── StandTalk (talking while standing — same pattern as wall_talk) ──
	if _names.has("stand_talk"):
		# Reverse StandTalk for return to idle
		var rev_st := AnimationNodeAnimation.new()
		rev_st.animation = _names["stand_talk"]
		rev_st.play_mode = AnimationNodeAnimation.PLAY_MODE_BACKWARD
		sm.add_node("stand_talk_return", rev_st, positions.get("stand_talk_return", Vector2.ZERO))
		# idle ↔ stand_talk
		_add_trans(sm, "idle", "stand_talk", XFADE_WALL_TALK)
		# NO auto-return! She holds the talking pose while speaking.
		_add_trans(sm, "stand_talk", "stand_talk_return", XFADE_WALL_TALK)
		_add_trans(sm, "stand_talk_return", "idle", XFADE_WALL_TALK, true)  # auto-advance
		# Allow direct transitions from stand_talk
		_add_trans(sm, "stand_talk", "return_wall", XFADE_TRANSITION)  # can return to wall
		_add_trans(sm, "stand_talk", "strike_base", XFADE_STRIKE)      # can strike

	# Standing → return to wall
	for key in ["idle", "suspicious", "angry"]:
		_add_trans(sm, key, "return_wall", XFADE_TRANSITION)
	# Return wall → idle_wall (auto-advance when reverse anim ends)
	_add_trans(sm, "return_wall", "idle_wall", XFADE_TRANSITION, true)

	# Any standing → strike
	for key in ["idle", "suspicious", "angry"]:
		_add_trans(sm, key, "strike_base", XFADE_STRIKE)
	# Strike → back to standing
	_add_trans(sm, "strike_base", "idle", XFADE_MOOD)
	_add_trans(sm, "strike_base", "suspicious", XFADE_MOOD)
	_add_trans(sm, "strike_base", "angry", XFADE_MOOD)
	_add_trans(sm, "strike_base", "return_wall", XFADE_TRANSITION)
	
	# Ground → strike
	if _names.has("idle_ground"):
		_add_trans(sm, "idle_ground", "strike_base", XFADE_STRIKE)
		_add_trans(sm, "strike_base", "idle_ground", XFADE_MOOD)
		if _names.has("idle_ground_talk"):
			_add_trans(sm, "idle_ground_talk", "strike_base", XFADE_STRIKE)


	# WalkIn (entrance from off-screen → idle → idle_wall)
	if _names.has("walk_in"):
		_add_trans(sm, "walk_in", "idle", XFADE_MOOD, true)  # auto-advance after WalkIn ends
		_add_trans(sm, "walk_in", "idle_wall", XFADE_TRANSITION)
		_add_trans(sm, "idle", "walk_in", XFADE_MOOD)

	# Hello (startup greeting → auto-advance to idle)
	if _names.has("hello"):
		_add_trans(sm, "hello", "idle", XFADE_MOOD, true)  # auto-advance after Hello ends
		_add_trans(sm, "hello", "idle_wall", XFADE_TRANSITION)

	# GoAway (exit — standing → GoAway → off-screen)
	if _names.has("go_away"):
		for key in ["idle", "suspicious", "angry"]:
			_add_trans(sm, key, "go_away", XFADE_MOOD)
		# NO idle_wall → go_away : she must leave the wall first (off_wall → idle → go_away)
		# GoAway ends → back to OFF_SCREEN (no auto-advance, handled in process)

	# Idle_wall_Talk — small remark while staying on wall
	# Forward plays once → HOLDS on last frame (talking pose)
	# Reverse plays when speech ends → back to idle_wall
	if _names.has("idle_wall_talk"):
		_add_trans(sm, "idle_wall", "idle_wall_talk", XFADE_WALL_TALK)
		# NO auto-return! She holds the talking pose while speaking.
		# When speech ends: travel("idle_wall_talk_return") → auto back to idle_wall
		_add_trans(sm, "idle_wall_talk", "idle_wall_talk_return", XFADE_WALL_TALK)
		_add_trans(sm, "idle_wall_talk_return", "idle_wall", XFADE_WALL_TALK, true)  # auto-advance
		# Also allow leaving wall from talk pose (if suspicion rises mid-remark)
		_add_trans(sm, "idle_wall_talk", "off_wall", XFADE_TRANSITION)

	# Idle_wall_Hair — random hair fix while sitting on wall
	# Plays once → auto-advance back to idle_wall
	if _names.has("idle_wall_hair"):
		_add_trans(sm, "idle_wall", "idle_wall_hair", XFADE_WALL_TALK)
		_add_trans(sm, "idle_wall_hair", "idle_wall", XFADE_WALL_TALK, true)  # auto-return
		# Interruption: allow leaving wall or starting talk during hair fix
		_add_trans(sm, "idle_wall_hair", "off_wall", XFADE_TRANSITION)
		if _names.has("idle_wall_talk"):
			_add_trans(sm, "idle_wall_hair", "idle_wall_talk", XFADE_WALL_TALK)
		# Initialize random timer
		_idle_hair_timer = randf_range(IDLE_HAIR_MIN_CD, IDLE_HAIR_MAX_CD)

	# ── Ground Sitting (mirrors wall system) ──────────────────────

	# Reverse idle_ground_standup for sitting down
	if _names.has("idle_ground_standup"):
		var rev_sit := AnimationNodeAnimation.new()
		rev_sit.animation = _names["idle_ground_standup"]
		rev_sit.play_mode = AnimationNodeAnimation.PLAY_MODE_BACKWARD
		sm.add_node("sit_ground", rev_sit, positions["sit_ground"])

	# Reverse idle_ground_talk for return from ground talking pose
	if _names.has("idle_ground_talk"):
		var rev_gtalk := AnimationNodeAnimation.new()
		rev_gtalk.animation = _names["idle_ground_talk"]
		rev_gtalk.play_mode = AnimationNodeAnimation.PLAY_MODE_BACKWARD
		sm.add_node("idle_ground_talk_return", rev_gtalk, positions.get("idle_ground_talk_return", Vector2.ZERO))

	# idle_ground ↔ standup ↔ standing
	if _names.has("idle_ground_standup"):
		_add_trans(sm, "idle_ground", "idle_ground_standup", XFADE_TRANSITION)
		_add_trans(sm, "idle_ground_standup", "idle", XFADE_MOOD, true)  # auto-advance to idle
		_add_trans(sm, "idle_ground_standup", "suspicious", XFADE_MOOD)
		_add_trans(sm, "idle_ground_standup", "angry", XFADE_MOOD)
		# Standing → sit back down
		for key in ["idle", "suspicious", "angry"]:
			_add_trans(sm, key, "sit_ground", XFADE_TRANSITION)
		_add_trans(sm, "sit_ground", "idle_ground", XFADE_TRANSITION, true)  # auto-advance

	# idle_ground_talk — same system as wall talk
	if _names.has("idle_ground_talk"):
		_add_trans(sm, "idle_ground", "idle_ground_talk", XFADE_WALL_TALK)
		_add_trans(sm, "idle_ground_talk", "idle_ground_talk_return", XFADE_WALL_TALK)
		_add_trans(sm, "idle_ground_talk_return", "idle_ground", XFADE_WALL_TALK, true)
		# Allow standing up from ground talk
		_add_trans(sm, "idle_ground_talk", "idle_ground_standup", XFADE_TRANSITION)

	# ── Lying System (alternative ground pose) ───────────────
	if _names.has("idle_lie"):
		# sit_ground can also lead to idle_lie (choice made in code)
		if _names.has("idle_ground_standup"):
			_add_trans(sm, "sit_ground", "idle_lie", XFADE_TRANSITION)
		# From lying → direct to idle (TP, no standup anim exists)
		_add_trans(sm, "idle_lie", "idle", XFADE_MOOD)
		# Lying → strike
		_add_trans(sm, "idle_lie", "strike_base", XFADE_STRIKE)
		_add_trans(sm, "strike_base", "idle_lie", XFADE_MOOD)

		# idle_lie_talk — same talk pattern
		if _names.has("idle_lie_talk"):
			var rev_lt := AnimationNodeAnimation.new()
			rev_lt.animation = _names["idle_lie_talk"]
			rev_lt.play_mode = AnimationNodeAnimation.PLAY_MODE_BACKWARD
			sm.add_node("idle_lie_talk_return", rev_lt, positions.get("idle_lie_talk_return", Vector2.ZERO))
			_add_trans(sm, "idle_lie", "idle_lie_talk", XFADE_WALL_TALK)
			_add_trans(sm, "idle_lie_talk", "idle_lie_talk_return", XFADE_WALL_TALK)
			_add_trans(sm, "idle_lie_talk_return", "idle_lie", XFADE_WALL_TALK, true)
			# Can TP out from lie talk too
			_add_trans(sm, "idle_lie_talk", "idle", XFADE_MOOD)
			_add_trans(sm, "idle_lie_talk", "strike_base", XFADE_STRIKE)

	# ── Wall Thinks/Write Chain ──────────────────────────
	if _names.has("idle_wall_thinks"):
		var rev_wt := AnimationNodeAnimation.new()
		rev_wt.animation = _names["idle_wall_thinks"]
		rev_wt.play_mode = AnimationNodeAnimation.PLAY_MODE_BACKWARD
		sm.add_node("idle_wall_thinks_return", rev_wt, positions.get("idle_wall_thinks_return", Vector2.ZERO))
		# idle_wall → thinks (forward, holds)
		_add_trans(sm, "idle_wall", "idle_wall_thinks", XFADE_WALL_TALK)
		# thinks → write (optional loop)
		if _names.has("idle_wall_write"):
			_add_trans(sm, "idle_wall_thinks", "idle_wall_write", XFADE_WALL_TALK)
			_add_trans(sm, "idle_wall_write", "idle_wall_thinks_return", XFADE_WALL_TALK)
		# thinks → return (skip write)
		_add_trans(sm, "idle_wall_thinks", "idle_wall_thinks_return", XFADE_WALL_TALK)
		# return → idle_wall (auto)
		_add_trans(sm, "idle_wall_thinks_return", "idle_wall", XFADE_WALL_TALK, true)
		# Interruptions
		_add_trans(sm, "idle_wall_thinks", "off_wall", XFADE_TRANSITION)
		if _names.has("idle_wall_write"):
			_add_trans(sm, "idle_wall_write", "off_wall", XFADE_TRANSITION)
		if _names.has("idle_wall_talk"):
			_add_trans(sm, "idle_wall_thinks", "idle_wall_talk", XFADE_WALL_TALK)

	# ── Ground Thinks/Write Chain ───────────────────────
	if _names.has("idle_ground_thinks"):
		var rev_gt := AnimationNodeAnimation.new()
		rev_gt.animation = _names["idle_ground_thinks"]
		rev_gt.play_mode = AnimationNodeAnimation.PLAY_MODE_BACKWARD
		sm.add_node("idle_ground_thinks_return", rev_gt, positions.get("idle_ground_thinks_return", Vector2.ZERO))
		# idle_ground → thinks
		_add_trans(sm, "idle_ground", "idle_ground_thinks", XFADE_WALL_TALK)
		# thinks → write (optional loop)
		if _names.has("idle_ground_write"):
			_add_trans(sm, "idle_ground_thinks", "idle_ground_write", XFADE_WALL_TALK)
			_add_trans(sm, "idle_ground_write", "idle_ground_thinks_return", XFADE_WALL_TALK)
		# thinks → return (skip write)
		_add_trans(sm, "idle_ground_thinks", "idle_ground_thinks_return", XFADE_WALL_TALK)
		# return → idle_ground (auto)
		_add_trans(sm, "idle_ground_thinks_return", "idle_ground", XFADE_WALL_TALK, true)
		# Interruptions
		if _names.has("idle_ground_standup"):
			_add_trans(sm, "idle_ground_thinks", "idle_ground_standup", XFADE_TRANSITION)
			if _names.has("idle_ground_write"):
				_add_trans(sm, "idle_ground_write", "idle_ground_standup", XFADE_TRANSITION)

	# ── Create AnimationTree node ──
	_tree = AnimationTree.new()
	_tree.name = "TamaAnimTree"
	_tree.tree_root = sm
	# Don't activate yet — we'll set anim_player after adding to tree
	_tree.active = false
	get_parent().add_child(_tree)

	# Set anim_player path (must be done after both are in the scene tree)
	_tree.anim_player = _tree.get_path_to(_player)
	_tree.active = true

	# Get playback controller
	_playback = _tree.get("parameters/playback")
	if _playback:
		# Start in idle_wall pose but HIDDEN — Tama is off-screen until walk_in()
		_playback.start("idle_wall")
		current_state = State.OFF_SCREEN
		if _tama_node:
			_tama_node.visible = false
		print("🎬 AnimTree: StateMachine built — starting OFF_SCREEN (hidden)")
	else:
		push_warning("🎬 AnimTree: Could not get playback!")


func _add_trans(sm: AnimationNodeStateMachine, from: String, to: String,
				xfade: float, auto_advance: bool = false) -> void:
	if not sm.has_node(from) or not sm.has_node(to):
		return
	var t := AnimationNodeStateMachineTransition.new()
	t.xfade_time = xfade
	t.switch_mode = AnimationNodeStateMachineTransition.SWITCH_MODE_AT_END if auto_advance \
		else AnimationNodeStateMachineTransition.SWITCH_MODE_IMMEDIATE
	if auto_advance:
		t.advance_mode = AnimationNodeStateMachineTransition.ADVANCE_MODE_AUTO
	sm.add_transition(from, to, t)


# ═══════════════════════════════════════════════════════════════
#                      PUBLIC API
# ═══════════════════════════════════════════════════════════════

func leave_wall() -> void:
	"""ON_WALL → OffThewall → STANDING. Auto-advances to idle after."""
	if not _ready_ok or not _playback:
		return
	if current_state != State.ON_WALL and current_state != State.WALL_TALK:
		return
	_set_state(State.LEAVING_WALL)
	_playback.travel("off_wall")
	print("🎬 → leave_wall()")


func walk_in() -> void:
	"""OFF_SCREEN → Hello → idle → idle_wall. Entrance animation."""
	if not _ready_ok or not _playback:
		return
	if current_state != State.OFF_SCREEN:
		print("🎬 walk_in() ignored — not off screen (state: %s)" % State.keys()[current_state])
		return

	# Prefer Hello as startup animation
	var start_anim := "hello" if _names.has("hello") else "walk_in"
	if not _names.has(start_anim):
		# Fallback: just go to idle_wall directly
		if _tama_node:
			_tama_node.visible = true
		_playback.travel("idle_wall")
		_set_state(State.ON_WALL)
		print("🎬 → walk_in() fallback (no Hello or WalkIn anim)")
		return
	_set_state(State.LEAVING_WALL)  # Reuse LEAVING_WALL for entrance transition
	_playback.start(start_anim)  # start() = hard jump
	_tree.advance(0)  # Force AnimTree to evaluate pose NOW
	# Defer visibility to next frame — skeleton needs 1 process tick to update
	if _tama_node:
		_tama_node.set_deferred("visible", true)
	print("🎬 → walk_in() — playing '%s'" % start_anim)


func teleport_in() -> void:
	"""OFF_SCREEN → idle instantly (teleportation arrival).
	Tama materializes standing (idle), ready to interact.
	The visual credibility is handled by main.gd's glitch effect
	(high → 0 fade) rather than a walk animation."""
	if not _ready_ok or not _playback:
		return
	if current_state != State.OFF_SCREEN:
		print("🎬 teleport_in() ignored — not off screen (state: %s)" % State.keys()[current_state])
		return
	# Jump directly to idle (standing) pose
	_playback.start("idle")
	_tree.advance(0)  # Force skeleton to evaluate idle pose NOW
	_set_state(State.STANDING)
	_current_standing = "idle"
	if _tama_node:
		_tama_node.set_deferred("visible", true)
	print("🎬 → teleport_in() — materialized standing (idle)")
	# Process any queued mood/strike that triggered the teleport
	if _queued_standing != "":
		var q := _queued_standing
		_queued_standing = ""
		if q == "strike":
			play_strike()
		elif q == "go_away":
			go_away()
		else:
			set_standing_anim(q)


func go_away() -> void:
	"""Any state → GoAway → OFF_SCREEN. Leaves wall first if needed."""
	if not _ready_ok or not _playback:
		return
	if current_state == State.OFF_SCREEN:
		return
	if not _names.has("go_away"):
		# Fallback: just return to wall then hide
		return_to_wall()
		return
	# If on wall, need to leave first → queue go_away
	if current_state == State.ON_WALL or current_state == State.WALL_TALK:
		_queued_standing = "go_away"
		leave_wall()
		print("🎬 → go_away() — leaving wall first, then GoAway")
		return
	# If on ground, need to stand first → queue go_away
	if current_state == State.ON_GROUND or current_state == State.GROUND_TALK:
		_queued_standing = "go_away"
		stand_from_ground()
		print("🎬 → go_away() — standing from ground first, then GoAway")
		return
	# If lying, TP to standing first → queue go_away
	if current_state == State.LYING or current_state == State.LIE_TALK:
		_queued_standing = "go_away"
		force_stand_from_lie()
		print("🎬 → go_away() — TP from lying to standing first, then GoAway")
		return
	if current_state == State.LEAVING_WALL or current_state == State.RETURNING_WALL \
		or current_state == State.LEAVING_GROUND or current_state == State.SITTING_GROUND:
		_queued_standing = "go_away"
		print("🎬 → go_away() queued — waiting for transition")
		return
	# Already standing → go directly
	_set_state(State.RETURNING_WALL)
	_playback.travel("go_away")
	print("🎬 → go_away() — leaving screen")


func return_to_wall() -> void:
	"""STANDING/STRIKING → reverse OffThewall → ON_WALL.
	WALL_TALK → reverse Idle_wall_Talk → ON_WALL.
	Ground states → gracefully ignored (already resting)."""
	if not _ready_ok or not _playback:
		return
	if current_state == State.ON_WALL or current_state == State.RETURNING_WALL:
		return
	# Ground states: she's already resting — nothing to "return" to
	if current_state == State.ON_GROUND or current_state == State.SITTING_GROUND:
		print("🎬 return_to_wall() ignored — already on ground (state: %s)" % State.keys()[current_state])
		return
	if current_state == State.GROUND_TALK:
		# End ground talk, stay sitting
		end_ground_talk()
		print("🎬 return_to_wall() → end_ground_talk() (ground equivalent)")
		return
	if current_state == State.LIE_TALK:
		end_lie_talk()
		print("🎬 return_to_wall() → end_lie_talk() (lying equivalent)")
		return
	if current_state == State.LYING:
		print("🎬 return_to_wall() ignored — lying on ground (state: LYING)")
		return
	if current_state == State.STAND_TALK:
		end_stand_talk()
		# After stand_talk_return → idle, then return_wall
		# This will need a queued action — but for now we let it go to idle
		print("🎬 return_to_wall() → end_stand_talk() first")
		return
	if current_state == State.LEAVING_GROUND:
		print("🎬 return_to_wall() ignored — currently leaving ground")
		return
	# If in wall talk pose, play reverse of Idle_wall_Talk (not OffThewall)
	if current_state == State.WALL_TALK:
		_set_state(State.RETURNING_WALL)
		_playback.travel("idle_wall_talk_return")
		print("🎬 → end_wall_talk() (reverse)")
		return
	_set_state(State.RETURNING_WALL)
	_playback.travel("return_wall")
	print("🎬 → return_to_wall()")


func set_standing_anim(key: String) -> void:
	"""Switch between standing animations: 'idle', 'suspicious', 'angry'.
	If currently on wall, triggers leave_wall() first.
	If currently off-screen, triggers walk_in() first."""
	if not _ready_ok or not _playback:
		return
	if not _names.has(key):
		push_warning("🎬 Unknown standing anim: " + key)
		return

	if current_state == State.OFF_SCREEN:
		# Need to arrive first — teleport in (primary) + queue the mood
		if _queued_standing not in ["strike", "go_away"]:
			_queued_standing = key
		teleport_in()
		return

	if current_state == State.ON_WALL:
		# Need to leave wall first — queue the mood
		if _queued_standing not in ["strike", "go_away"]:
			_queued_standing = key
		leave_wall()
		return

	if current_state == State.ON_GROUND or current_state == State.GROUND_TALK:
		# Need to stand from ground first — queue the mood
		if _queued_standing not in ["strike", "go_away"]:
			_queued_standing = key
		stand_from_ground()
		return

	if current_state == State.LYING or current_state == State.LIE_TALK:
		# No standup anim for lie — TP directly to standing + queue the mood
		if _queued_standing not in ["strike", "go_away"]:
			_queued_standing = key
		force_stand_from_lie()
		return

	if current_state == State.LEAVING_WALL or current_state == State.LEAVING_GROUND:
		# Still transitioning — queue it
		if _queued_standing not in ["strike", "go_away"]:
			_queued_standing = key
		return

	if current_state == State.SITTING_GROUND:
		# Sitting down animation in progress — queue it
		if _queued_standing not in ["strike", "go_away"]:
			_queued_standing = key
		return

	if current_state == State.STRIKING:
		# Don't interrupt a strike in progress, but queue the mood!
		print("🎬 Mood '%s' queued (currently STRIKING)" % key)
		if _queued_standing not in ["strike", "go_away"]:
			_queued_standing = key
		return

	# Already standing — travel directly
	_playback.travel(key)
	_current_standing = key
	_set_state(State.STANDING)

var _current_standing: String = "idle"
var _queued_standing: String = ""
var _was_on_ground_before_strike: bool = false


func play_wall_talk() -> void:
	"""Play Idle_wall_Talk — she leans in to talk, holds the pose.
	Only works when ON_WALL. Call end_wall_talk() when speech ends."""
	if not _ready_ok or not _playback:
		return
	if current_state != State.ON_WALL:
		print("🎬 wall_talk ignored — not on wall (state: %s)" % State.keys()[current_state])
		return
	if not _names.has("idle_wall_talk"):
		print("🎬 wall_talk ignored — animation not found in GLB")
		return
	_playback.travel("idle_wall_talk")
	print("🎬 → play_wall_talk()")


func end_wall_talk() -> void:
	"""End wall talk — plays Idle_wall_Talk in reverse back to idle_wall."""
	if not _ready_ok or not _playback:
		return
	if current_state != State.WALL_TALK:
		return
	_set_state(State.RETURNING_WALL)
	_playback.travel("idle_wall_talk_return")
	print("🎬 → end_wall_talk()")


# ─── Stand Talk API (talking while standing) ──────────────────

func play_stand_talk() -> void:
	"""Play StandTalk — she transitions into a talking gesture while standing.
	Only works when STANDING. Call end_stand_talk() when speech ends."""
	if not _ready_ok or not _playback:
		return
	if current_state != State.STANDING:
		print("🎬 stand_talk ignored — not standing (state: %s)" % State.keys()[current_state])
		return
	if not _names.has("stand_talk"):
		print("🎬 stand_talk ignored — animation not found in GLB")
		return
	_playback.travel("stand_talk")
	print("🎬 → play_stand_talk()")


func end_stand_talk() -> void:
	"""End stand talk — plays StandTalk in reverse back to idle."""
	if not _ready_ok or not _playback:
		return
	if current_state != State.STAND_TALK:
		return
	_set_state(State.STANDING)
	_playback.travel("stand_talk_return")
	print("🎬 → end_stand_talk()")


# ─── Ground Sitting API ───────────────────────────────────────

func sit_ground() -> void:
	"""STANDING → sit_ground (reverse StandUp) → idle_ground. Auto-advances."""
	if not _ready_ok or not _playback:
		return
	if not _names.has("idle_ground_standup"):
		return
	if not is_standing():
		print("🎬 sit_ground() ignored — not standing (state: %s)" % State.keys()[current_state])
		return
	_set_state(State.SITTING_GROUND)
	_playback.travel("sit_ground")
	print("🎬 → sit_ground()")


func stand_from_ground() -> void:
	"""ON_GROUND → idle_ground_standup → STANDING. Auto-advances to idle."""
	if not _ready_ok or not _playback:
		return
	if not _names.has("idle_ground_standup"):
		return
	if current_state != State.ON_GROUND and current_state != State.GROUND_TALK:
		print("🎬 stand_from_ground() ignored — not on ground (state: %s)" % State.keys()[current_state])
		return
	_set_state(State.LEAVING_GROUND)
	_playback.travel("idle_ground_standup")
	print("🎬 → stand_from_ground()")


func play_ground_talk() -> void:
	"""Play Idle_ground_talk — she talks while sitting on the ground."""
	if not _ready_ok or not _playback:
		return
	if current_state != State.ON_GROUND:
		print("🎬 ground_talk ignored — not on ground (state: %s)" % State.keys()[current_state])
		return
	if not _names.has("idle_ground_talk"):
		return
	_playback.travel("idle_ground_talk")
	print("🎬 → play_ground_talk()")


func end_ground_talk() -> void:
	"""End ground talk — plays reverse back to idle_ground."""
	if not _ready_ok or not _playback:
		return
	if current_state != State.GROUND_TALK:
		return
	_set_state(State.SITTING_GROUND)
	_playback.travel("idle_ground_talk_return")
	print("🎬 → end_ground_talk()")


# ─── Lying API (alternative ground pose) ──────────────────────

func play_lie_talk() -> void:
	"""Play Idle_lie_talk — she talks while lying down."""
	if not _ready_ok or not _playback:
		return
	if current_state != State.LYING:
		print("🎬 lie_talk ignored — not lying (state: %s)" % State.keys()[current_state])
		return
	if not _names.has("idle_lie_talk"):
		return
	_playback.travel("idle_lie_talk")
	print("🎬 → play_lie_talk()")


func end_lie_talk() -> void:
	"""End lie talk — plays reverse back to idle_lie."""
	if not _ready_ok or not _playback:
		return
	if current_state != State.LIE_TALK:
		return
	_set_state(State.LYING)
	_playback.travel("idle_lie_talk_return")
	print("🎬 → end_lie_talk()")


func force_stand_from_lie() -> void:
	"""LYING → direct TP to idle (STANDING). No standup animation exists for lying."""
	if not _ready_ok or not _playback:
		return
	if current_state != State.LYING and current_state != State.LIE_TALK:
		return
	_playback.travel("idle")
	_set_state(State.STANDING)
	_current_standing = "idle"
	print("🎬 → force_stand_from_lie() — TP to idle!")


# ─── Thinks/Write API (wall & ground) ────────────────────────

func trigger_wall_thinks() -> void:
	"""ON_WALL → idle_wall_thinks. Random cosmetic variation."""
	if not _ready_ok or not _playback:
		return
	if current_state != State.ON_WALL:
		return
	if not _names.has("idle_wall_thinks"):
		return
	_in_thinks_chain = true
	_thinks_write_timer = 0.0
	_playback.travel("idle_wall_thinks")
	print("🎬 → trigger_wall_thinks()")


func end_wall_thinks() -> void:
	"""End thinks/write chain on wall → reverse thinks → idle_wall."""
	if not _ready_ok or not _playback:
		return
	_in_thinks_chain = false
	_playback.travel("idle_wall_thinks_return")
	print("🎬 → end_wall_thinks()")


func trigger_ground_thinks() -> void:
	"""ON_GROUND → idle_ground_thinks. Random cosmetic variation."""
	if not _ready_ok or not _playback:
		return
	if current_state != State.ON_GROUND:
		return
	if not _names.has("idle_ground_thinks"):
		return
	_in_thinks_chain = true
	_thinks_write_timer = 0.0
	_playback.travel("idle_ground_thinks")
	print("🎬 → trigger_ground_thinks()")


func end_ground_thinks() -> void:
	"""End thinks/write chain on ground → reverse thinks → idle_ground."""
	if not _ready_ok or not _playback:
		return
	_in_thinks_chain = false
	_playback.travel("idle_ground_thinks_return")
	print("🎬 → end_ground_thinks()")


func play_strike() -> void:
	"""Enter strike sequence. Must be STANDING first."""
	if not _ready_ok or not _playback:
		return

	if current_state == State.STRIKING:
		print("🎬 play_strike() forced restart — already STRIKING")
		_strike_fired = false
		_strike_frames = 0
		_strike_time = 0.0
		_playback.start("strike_base")
		strike_sequence_started.emit()
		return

	_was_on_ground_before_strike = is_on_ground()

	if not is_standing() and not is_on_ground():
		print("🎬 play_strike() — currently %s, forcing exit for strike" % State.keys()[current_state])
		_queued_standing = "strike"
		if current_state == State.OFF_SCREEN:
			teleport_in()
		elif current_state == State.WALL_TALK:
			# Force end talk → leave wall → queue strike
			end_wall_talk()  # triggers talk_return → idle_wall
			# But that's slow. Queue will fire on LEAVING_WALL → STANDING transition.
			# Force leave_wall will be picked up when end_wall_talk completes.
		elif current_state == State.ON_WALL:
			leave_wall()
		elif current_state == State.GROUND_TALK:
			# Force end ground talk — strike will fire from queue when back to ON_GROUND
			end_ground_talk()
		# If LEAVING_WALL/LEAVING_GROUND/SITTING_GROUND, the queue will fire when done
		return

	_set_state(State.STRIKING)

	_strike_fired = false
	_strike_frames = 0
	_strike_time = 0.0
	_playback.travel("strike_base")
	strike_sequence_started.emit()
	print("🎬 → play_strike()")


func apply_mood(mood: String, intensity: float) -> void:
	"""Map mood+intensity to a standing animation (replaces _MOOD_ANIM_MAP)."""
	var key: String
	var is_sitting := is_on_wall() or is_on_ground()
	match mood:
		"calm", "amused", "proud":
			# If sitting (wall or ground), play talk instead of leaving
			if is_on_wall() and _names.has("idle_wall_talk"):
				play_wall_talk()
				return
			if current_state == State.ON_GROUND and _names.has("idle_ground_talk"):
				play_ground_talk()
				return
			if current_state == State.LYING and _names.has("idle_lie_talk"):
				play_lie_talk()
				return
			key = "idle"
		"curious":
			if intensity < 0.4:
				if is_on_wall() and _names.has("idle_wall_talk"):
					play_wall_talk()
					return
				if current_state == State.ON_GROUND and _names.has("idle_ground_talk"):
					play_ground_talk()
					return
				if current_state == State.LYING and _names.has("idle_lie_talk"):
					play_lie_talk()
					return
			key = "suspicious"
		"suspicious", "sarcastic", "disappointed":
			key = "angry" if intensity > 0.7 else "suspicious"
		"annoyed":
			key = "angry" if intensity > 0.4 else "suspicious"
		"angry":
			key = "angry"
		"furious":
			key = "angry"
		_:
			if is_on_wall() and _names.has("idle_wall_talk"):
				play_wall_talk()
				return
			if current_state == State.ON_GROUND and _names.has("idle_ground_talk"):
				play_ground_talk()
				return
			if current_state == State.LYING and _names.has("idle_lie_talk"):
				play_lie_talk()
				return
			key = "idle"
	set_standing_anim(key)


func is_off_screen() -> bool:
	return current_state == State.OFF_SCREEN

func is_on_wall() -> bool:
	return current_state == State.ON_WALL or current_state == State.WALL_TALK

func is_on_ground() -> bool:
	return current_state in [State.ON_GROUND, State.GROUND_TALK, State.LYING, State.LIE_TALK]

func is_standing() -> bool:
	return current_state == State.STANDING or current_state == State.STAND_TALK

func is_striking() -> bool:
	return current_state == State.STRIKING

func is_transitioning() -> bool:
	return current_state in [State.LEAVING_WALL, State.RETURNING_WALL, State.LEAVING_GROUND, State.SITTING_GROUND]

# ─── Ghost Silhouette (freeze at Hello frame 0) ──────────────
var _ghost_frozen: bool = false  # True when tree is paused for ghost pose

func freeze_hello_pose() -> void:
	"""Jump to Hello frame 0 and FREEZE the AnimTree.
	Tama holds the first pose as a ghostly silhouette until unfreeze_and_play_hello()."""
	if not _ready_ok or not _playback or not _tree:
		return
	var anim_key := "hello" if _names.has("hello") else "walk_in"
	if not _names.has(anim_key):
		# No entrance anim — just go to idle_wall frozen
		anim_key = "idle_wall"
	_playback.start(anim_key)
	_tree.advance(0)  # Evaluate first frame
	_tree.active = false  # FREEZE — no more processing
	_ghost_frozen = true
	if _tama_node:
		_tama_node.set_deferred("visible", true)
	print("🎬 Ghost pose: frozen at '%s' frame 0" % anim_key)

func unfreeze_and_play_hello() -> void:
	"""UNFREEZE the AnimTree and play Hello from the start.
	Called when Gemini's voice arrives — Tama materializes."""
	if not _ready_ok or not _tree:
		return
	_ghost_frozen = false
	_tree.active = true  # Resume processing
	# Re-start Hello from beginning for clean playback
	var anim_key := "hello" if _names.has("hello") else "walk_in"
	if _names.has(anim_key) and _playback:
		_playback.start(anim_key)
	_set_state(State.LEAVING_WALL)  # Same state as walk_in()
	print("🎬 Ghost → MATERIALIZED! Playing '%s'" % anim_key)


func get_current_anim_key() -> String:
	if not _playback:
		return ""
	return _playback.get_current_node()


# ═══════════════════════════════════════════════════════════════
#                      PROCESS LOOP
# ═══════════════════════════════════════════════════════════════

func _process(delta: float) -> void:
	if not _ready_ok or not _playback:
		return

	var cur_node: String = _playback.get_current_node()

	# ── Detect SM node changes for state tracking ──
	if cur_node != _prev_node:
		_on_sm_node_changed(_prev_node, cur_node)
		_prev_node = cur_node

	# ── Random idle hair fix trigger ──
	if current_state == State.ON_WALL and cur_node == "idle_wall" and _names.has("idle_wall_hair"):
		_idle_hair_timer -= delta
		if _idle_hair_timer <= 0:
			_playback.travel("idle_wall_hair")
			_idle_hair_timer = randf_range(IDLE_HAIR_MIN_CD, IDLE_HAIR_MAX_CD)
			print("🎬 → idle_wall_hair (random trigger, next in %.0fs)" % _idle_hair_timer)

	# ── Random thinks trigger (wall & ground) ──
	if not _in_thinks_chain:
		if (current_state == State.ON_WALL and cur_node == "idle_wall" and _names.has("idle_wall_thinks")) \
			or (current_state == State.ON_GROUND and cur_node == "idle_ground" and _names.has("idle_ground_thinks")):
			_idle_thinks_timer -= delta
			if _idle_thinks_timer <= 0:
				_idle_thinks_timer = randf_range(IDLE_THINKS_MIN_CD, IDLE_THINKS_MAX_CD)
				if current_state == State.ON_WALL:
					trigger_wall_thinks()
				else:
					trigger_ground_thinks()

	# ── Thinks chain management (write delay & duration) ──
	if _in_thinks_chain:
		_thinks_write_timer += delta
		# Phase 1: After delay, start writing (if write anim exists)
		if cur_node in ["idle_wall_thinks", "idle_ground_thinks"]:
			if _thinks_write_timer >= THINKS_WRITE_DELAY:
				if cur_node == "idle_wall_thinks" and _names.has("idle_wall_write"):
					_playback.travel("idle_wall_write")
					_thinks_write_timer = 0.0
					print("🎬 thinks → write (wall)")
				elif cur_node == "idle_ground_thinks" and _names.has("idle_ground_write"):
					_playback.travel("idle_ground_write")
					_thinks_write_timer = 0.0
					print("🎬 thinks → write (ground)")
				else:
					# No write anim → just reverse out
					if cur_node == "idle_wall_thinks":
						end_wall_thinks()
					else:
						end_ground_thinks()
		# Phase 2: After writing for a while, reverse out
		elif cur_node in ["idle_wall_write", "idle_ground_write"]:
			if _thinks_write_timer >= THINKS_WRITE_DURATION:
				if cur_node == "idle_wall_write":
					end_wall_thinks()
				else:
					end_ground_thinks()

	# ── Strike fire detection (animation position trigger) ──
	if current_state == State.STRIKING:
		_strike_time += delta  # Track how long we've been in STRIKING
		if not _strike_fired:
			var fire_at: float = STRIKE_FIRE_AT.get("strike_base", STRIKE_FIRE_FALLBACK)
			var pos: float = _playback.get_current_play_position()
			if pos >= fire_at:
				_strike_fired = true
				strike_fire_point.emit()
				print("🎬 🎯 STRIKE_FIRE at %.2fs (configured: %.2fs)" % [pos, fire_at])

	# ── Detect when strike finishes → choose next state ──
	if current_state == State.STRIKING:
		var pos: float = _playback.get_current_play_position()
		var length: float = _playback.get_current_length()
		# When a transition happens immediately, get_current_length() might return 0
		# So we must rely heavily on _strike_time for safety.
		if length > 0 and pos >= length - 0.05:
			_on_strike_complete()
		# Safety timeout: if position-check never triggers (low FPS, crossfade,
		# animation mismatch), force-complete after 3s to prevent being stuck.
		elif _strike_time > 3.0:
			print("🎬 ⚠️ STRIKING safety timeout (%.1fs) — forcing completion" % _strike_time)
			_on_strike_complete()


func _on_sm_node_changed(from_node: String, to_node: String) -> void:
	"""Called when the StateMachine transitions to a different node."""
	# walk_in or hello just ended → advance to idle (then idle_wall)
	if from_node in ["walk_in", "hello"] and to_node == "idle":
		_set_state(State.STANDING)
		_current_standing = "idle"
		off_wall_complete.emit()
		# If a mood was queued during walk-in, apply it
		if _queued_standing != "":
			var q := _queued_standing
			_queued_standing = ""
			if q == "strike":
				play_strike()
			elif q == "go_away":
				go_away()
			else:
				set_standing_anim(q)
		else:
			# Default: continue to idle_wall after walk_in completes
			# UNLESS onboarding is active — she stays standing to talk
			if onboarding_hold:
				print("🎬 Hello done → staying STANDING (onboarding hold)")
			else:
				_playback.travel("idle_wall")

	# off_wall just ended → we're now standing
	elif from_node == "off_wall" and to_node in ["idle", "suspicious", "angry"]:
		_set_state(State.STANDING)
		_current_standing = to_node
		off_wall_complete.emit()
		# If a mood was queued during transition, apply it now
		if _queued_standing != "":
			var q := _queued_standing
			_queued_standing = ""
			if q == "strike":
				play_strike()
			elif q == "go_away":
				go_away()
			else:
				set_standing_anim(q)

	# idle after walk_in → idle_wall (auto settled on wall)
	elif from_node == "idle" and to_node == "idle_wall" and current_state == State.STANDING:
		_set_state(State.ON_WALL)
		print("🎬 Walk-in complete → settled on wall")

	# return_wall just ended → back on wall
	elif from_node == "return_wall" and to_node == "idle_wall":
		_set_state(State.ON_WALL)
		if _queued_standing != "":
			var q := _queued_standing
			_queued_standing = ""
			if q == "strike": play_strike()
			else: set_standing_anim(q)

	# go_away just finished → OFF_SCREEN + hide mesh
	elif from_node == "go_away":
		_set_state(State.OFF_SCREEN)
		if _tama_node:
			_tama_node.visible = false
		print("🎬 GoAway complete → OFF_SCREEN (hidden)")

	# idle_wall_talk started
	elif to_node == "idle_wall_talk":
		_set_state(State.WALL_TALK)

	# idle_wall_talk_return ended → back to idle_wall (auto-advance)
	elif from_node == "idle_wall_talk_return" and to_node == "idle_wall":
		_set_state(State.ON_WALL)
		if _queued_standing != "":
			var q := _queued_standing
			_queued_standing = ""
			if q == "strike": play_strike()
			else: set_standing_anim(q)

	# idle_wall_hair ended → back to idle_wall (auto-advance, stays ON_WALL)
	elif from_node == "idle_wall_hair" and to_node == "idle_wall":
		# State stays ON_WALL — just a cosmetic variation
		if _queued_standing != "":
			var q := _queued_standing
			_queued_standing = ""
			if q == "strike": play_strike()
			else: set_standing_anim(q)

	# Entered strike
	elif to_node == "strike_base":
		_set_state(State.STRIKING)
		_strike_fired = false
		_strike_frames = 0
		_strike_time = 0.0

	# ── Ground Sitting State Detection ──

	# idle_ground_standup just ended → standing
	elif from_node == "idle_ground_standup" and to_node in ["idle", "suspicious", "angry"]:
		_set_state(State.STANDING)
		_current_standing = to_node
		off_wall_complete.emit()
		if _queued_standing != "":
			var q := _queued_standing
			_queued_standing = ""
			if q == "strike": play_strike()
			elif q == "go_away": go_away()
			else: set_standing_anim(q)

	# sit_ground just ended → on ground (or lying randomly)
	elif from_node == "sit_ground" and to_node == "idle_ground":
		if _queued_standing != "":
			var q := _queued_standing
			_queued_standing = ""
			if q == "strike": play_strike()
			elif q == "go_away": go_away()
			else: set_standing_anim(q)
		else:
			# 🆕 Random chance to lie down instead of sitting
			if _names.has("idle_lie") and randf() < LIE_PROBABILITY:
				_playback.travel("idle_lie")
				# State will be set to LYING when sit_ground→idle_lie is detected
				print("🎬 Sitting → lying down! (%.0f%% chance)" % (LIE_PROBABILITY * 100))
			else:
				_set_state(State.ON_GROUND)
				print("🎬 Sitting on ground")

	# idle_ground_talk started
	elif to_node == "idle_ground_talk":
		_set_state(State.GROUND_TALK)

	# idle_ground_talk_return ended → back to idle_ground
	elif from_node == "idle_ground_talk_return" and to_node == "idle_ground":
		_set_state(State.ON_GROUND)
		if _queued_standing != "":
			var q := _queued_standing
			_queued_standing = ""
			if q == "strike": play_strike()
			else: set_standing_anim(q)

	# ── Stand Talk State Detection ──

	# stand_talk started
	elif to_node == "stand_talk":
		_set_state(State.STAND_TALK)

	# stand_talk_return ended → back to idle (standing)
	elif from_node == "stand_talk_return" and to_node == "idle":
		_set_state(State.STANDING)
		_current_standing = "idle"
		if _queued_standing != "":
			var q := _queued_standing
			_queued_standing = ""
			if q == "strike": play_strike()
			elif q == "go_away": go_away()
			else: set_standing_anim(q)

	# ── Lying State Detection ──

	# sit_ground → idle_lie (random choice)
	elif from_node == "sit_ground" and to_node == "idle_lie":
		_set_state(State.LYING)
		print("🎬 Lying down on ground")

	# idle_lie_talk started
	elif to_node == "idle_lie_talk":
		_set_state(State.LIE_TALK)

	# idle_lie_talk_return ended → back to idle_lie
	elif from_node == "idle_lie_talk_return" and to_node == "idle_lie":
		_set_state(State.LYING)

	# idle_lie → idle (forced TP when angry)
	elif from_node == "idle_lie" and to_node == "idle":
		_set_state(State.STANDING)
		_current_standing = "idle"
		off_wall_complete.emit()

	# ── Wall Thinks/Write State Detection ──

	# idle_wall_thinks_return ended → back to idle_wall
	elif from_node == "idle_wall_thinks_return" and to_node == "idle_wall":
		_set_state(State.ON_WALL)
		_in_thinks_chain = false

	# ── Ground Thinks/Write State Detection ──

	# idle_ground_thinks_return ended → back to idle_ground
	elif from_node == "idle_ground_thinks_return" and to_node == "idle_ground":
		_set_state(State.ON_GROUND)
		_in_thinks_chain = false


func _on_strike_complete() -> void:
	"""Called when strike_base animation finishes."""
	# Don't process more than once
	if current_state != State.STRIKING:
		return
		
	if _was_on_ground_before_strike:
		_set_state(State.ON_GROUND)
		if _queued_standing != "":
			var q := _queued_standing
			_queued_standing = ""
			if q == "strike": play_strike()
			else: 
				print("🎬 Strike complete → Staying on ground, ignoring standing mood request: " + q)
				_playback.travel("idle_ground")
		else:
			_playback.travel("idle_ground")
			print("🎬 Strike complete → Back to sitting")
	else:
		_set_state(State.STANDING)
		if _queued_standing != "":
			var q := _queued_standing
			_queued_standing = ""
			print("🎬 Strike complete → Applying queued mood '%s'" % q)
			if q == "strike":
				play_strike()
			else:
				set_standing_anim(q)
		else:
			_current_standing = "angry"
			_playback.travel("angry")
			print("🎬 Strike complete → Standing (angry)")


func _set_state(new_state: int) -> void:
	if current_state == new_state:
		return
	var old_name: String = State.keys()[current_state]
	var new_name: String = State.keys()[new_state]
	current_state = new_state
	state_changed.emit(old_name, new_name)
