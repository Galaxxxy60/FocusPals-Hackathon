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
enum State { OFF_SCREEN, ON_WALL, WALL_TALK, LEAVING_WALL, STANDING, RETURNING_WALL, STRIKING }
var current_state: int = State.OFF_SCREEN

# ─── Internals ────────────────────────────────────────────────
var _tree: AnimationTree = null
var _player: AnimationPlayer = null
var _playback = null  # AnimationNodeStateMachinePlayback
var _skeleton: Skeleton3D = null
var _ready_ok: bool = false

# Resolved GLB animation names (handles prefixes like "F ")
var _names: Dictionary = {}

# What we're looking for → what GLB might call it
const WANTED = {
	"idle_wall": "Idle_wall",
	"idle_wall_talk": "Idle_wall_Talk",
	"off_wall": "OffThewall",
	"idle": "Idle",
	"suspicious": "Suspicious",
	"angry": "Angry",
	"strike_base": "Strike_Base",
	"walk_in": "WalkIn",
	"go_away": "GoAway",
}

# Which animations should loop
const LOOPS = ["idle_wall", "idle"]

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
		"off_wall": Vector2(200, 100),
		"idle": Vector2(400, 0),
		"suspicious": Vector2(400, 100),
		"angry": Vector2(400, 200),
		"return_wall": Vector2(200, 250),
		"strike_base": Vector2(600, 100),
		"walk_in": Vector2(-200, 100),
		"go_away": Vector2(-200, -100),
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

	# WalkIn (entrance from off-screen → idle → idle_wall)
	if _names.has("walk_in"):
		_add_trans(sm, "walk_in", "idle", XFADE_MOOD, true)  # auto-advance after WalkIn ends
		_add_trans(sm, "walk_in", "idle_wall", XFADE_TRANSITION)
		_add_trans(sm, "idle", "walk_in", XFADE_MOOD)

	# GoAway (exit — standing → GoAway → off-screen)
	if _names.has("go_away"):
		for key in ["idle", "suspicious", "angry"]:
			_add_trans(sm, key, "go_away", XFADE_MOOD)
		_add_trans(sm, "idle_wall", "go_away", XFADE_TRANSITION)
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
		# Always start in idle_wall (stable, known-working pose).
		# OFF_SCREEN is tracked logically — Tama is "hidden" until walk_in() is called.
		_playback.start("idle_wall")
		current_state = State.ON_WALL
		print("🎬 AnimTree: StateMachine built — starting in idle_wall")
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
	"""OFF_SCREEN → WalkIn → idle → idle_wall. Entrance animation."""
	if not _ready_ok or not _playback:
		return
	if current_state != State.OFF_SCREEN:
		print("🎬 walk_in() ignored — not off screen (state: %s)" % State.keys()[current_state])
		return
	if not _names.has("walk_in"):
		# Fallback: just go to idle_wall directly
		_playback.travel("idle_wall")
		_set_state(State.ON_WALL)
		print("🎬 → walk_in() fallback (no WalkIn anim)")
		return
	_set_state(State.LEAVING_WALL)  # Reuse LEAVING_WALL for walk-in transition
	_playback.travel("walk_in")
	print("🎬 → walk_in() — entering screen")


func go_away() -> void:
	"""Any state → GoAway → OFF_SCREEN. Exit animation."""
	if not _ready_ok or not _playback:
		return
	if current_state == State.OFF_SCREEN:
		return
	if not _names.has("go_away"):
		# Fallback: just return to wall
		return_to_wall()
		return
	_set_state(State.RETURNING_WALL)  # Reuse RETURNING_WALL for exit
	_playback.travel("go_away")
	print("🎬 → go_away() — leaving screen")


func return_to_wall() -> void:
	"""STANDING/STRIKING → reverse OffThewall → ON_WALL.
	WALL_TALK → reverse Idle_wall_Talk → ON_WALL."""
	if not _ready_ok or not _playback:
		return
	if current_state == State.ON_WALL or current_state == State.RETURNING_WALL:
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
		# Need to walk in first — queue the mood
		_queued_standing = key
		walk_in()
		return

	if current_state == State.ON_WALL:
		# Need to leave wall first — queue the mood
		_queued_standing = key
		leave_wall()
		return

	if current_state == State.LEAVING_WALL:
		# Still transitioning — queue it
		_queued_standing = key
		return

	if current_state == State.STRIKING:
		# Don't interrupt a strike in progress, but queue the mood!
		print("🎬 Mood '%s' queued (currently STRIKING)" % key)
		_queued_standing = key
		return

	# Already standing — travel directly
	_playback.travel(key)
	_current_standing = key
	_set_state(State.STANDING)

var _current_standing: String = "idle"
var _queued_standing: String = ""


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

	if not is_standing():
		print("🎬 play_strike() queued — currently %s, ensuring standing first" % State.keys()[current_state])
		_queued_standing = "strike"
		if current_state == State.OFF_SCREEN:
			walk_in()
		elif current_state == State.ON_WALL or current_state == State.WALL_TALK:
			leave_wall()
		# Si en cours de LEAVING_WALL ou RETURNING_WALL, la file d'attente s'en chargera
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
	match mood:
		"calm", "amused", "proud":
			# If on wall, play wall talk instead of leaving wall
			if is_on_wall() and _names.has("idle_wall_talk"):
				play_wall_talk()
				return
			key = "idle"
		"curious":
			if intensity < 0.4 and is_on_wall() and _names.has("idle_wall_talk"):
				play_wall_talk()
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
			key = "idle"
	set_standing_anim(key)


func is_off_screen() -> bool:
	return current_state == State.OFF_SCREEN

func is_on_wall() -> bool:
	return current_state == State.ON_WALL or current_state == State.WALL_TALK

func is_standing() -> bool:
	return current_state == State.STANDING

func is_striking() -> bool:
	return current_state == State.STRIKING

func is_transitioning() -> bool:
	return current_state in [State.LEAVING_WALL, State.RETURNING_WALL]

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

	# ── Strike fire detection (animation position trigger) ──
	if current_state == State.STRIKING and not _strike_fired:
		var fire_at: float = STRIKE_FIRE_AT.get(cur_node, STRIKE_FIRE_FALLBACK)
		var pos: float = _playback.get_current_play_position()
		if pos >= fire_at:
			_strike_fired = true
			strike_fire_point.emit()
			print("🎬 🎯 STRIKE_FIRE at %.2fs (configured: %.2fs in '%s')" % [pos, fire_at, cur_node])

	# ── Detect when strike finishes → choose next state ──
	if current_state == State.STRIKING and cur_node == "strike_base":
		var pos: float = _playback.get_current_play_position()
		var length: float = _playback.get_current_length()
		if length > 0 and pos >= length - 0.05:
			_on_strike_complete()


func _on_sm_node_changed(from_node: String, to_node: String) -> void:
	"""Called when the StateMachine transitions to a different node."""
	# walk_in just ended → advance to idle (then idle_wall)
	if from_node == "walk_in" and to_node == "idle":
		_set_state(State.STANDING)
		_current_standing = "idle"
		off_wall_complete.emit()
		# If a mood was queued during walk-in, apply it
		if _queued_standing != "":
			var q := _queued_standing
			_queued_standing = ""
			if q == "strike":
				play_strike()
			else:
				set_standing_anim(q)
		else:
			# Default: continue to idle_wall after walk_in completes
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

	# go_away just finished → OFF_SCREEN
	elif from_node == "go_away":
		_set_state(State.OFF_SCREEN)
		print("🎬 GoAway complete → OFF_SCREEN")

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

	# Entered strike
	elif to_node == "strike_base":
		_set_state(State.STRIKING)
		_strike_fired = false
		_strike_frames = 0
		_strike_time = 0.0


func _on_strike_complete() -> void:
	"""Called when strike_base animation finishes."""
	# Don't process more than once
	if current_state != State.STRIKING:
		return
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
