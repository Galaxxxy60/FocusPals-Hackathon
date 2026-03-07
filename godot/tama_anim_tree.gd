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
enum State { ON_WALL, WALL_TALK, LEAVING_WALL, STANDING, RETURNING_WALL, STRIKING }
var current_state: int = State.ON_WALL

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
	"peek": "Peek",
	"bye": "bye",
}

# Which animations should loop
const LOOPS = ["idle_wall", "idle"]

# ─── Strike Sync ─────────────────────────────────────────────
var _strike_bone_idx: int = -1
var _strike_fired: bool = false
var _strike_frames: int = 0
const STRIKE_THRESHOLD: float = 1.05
const STRIKE_WARMUP: int = 5

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

	# 4. Find strike bone
	if _skeleton:
		for bi in range(_skeleton.get_bone_count()):
			var bn: String = _skeleton.get_bone_name(bi).to_lower()
			if "jnt_r_hand" in bn or "r_hand" in bn:
				_strike_bone_idx = bi
				print("🎬 AnimTree: Strike bone '%s' (idx %d)" % [_skeleton.get_bone_name(bi), bi])
				break

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
		"peek": Vector2(400, -100),
		"bye": Vector2(200, -100),
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

	# Peek
	if _names.has("peek"):
		_add_trans(sm, "idle", "peek", XFADE_MOOD)
		_add_trans(sm, "peek", "idle", XFADE_MOOD)
		_add_trans(sm, "idle_wall", "peek", XFADE_TRANSITION)

	# Bye
	if _names.has("bye"):
		for key in ["idle", "suspicious", "angry"]:
			_add_trans(sm, key, "bye", XFADE_MOOD)
		_add_trans(sm, "bye", "return_wall", XFADE_TRANSITION, true)

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
		_playback.start("idle_wall")
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
	"""Switch between standing animations: 'idle', 'suspicious', 'angry', 'peek'.
	If currently on wall, triggers leave_wall() first."""
	if not _ready_ok or not _playback:
		return
	if not _names.has(key):
		push_warning("🎬 Unknown standing anim: " + key)
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

	if current_state == State.ON_WALL:
		# Need to leave wall first, then strike
		_queued_standing = "strike"
		leave_wall()
		return

	_set_state(State.STRIKING)
	_strike_fired = false
	_strike_frames = 0
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
			key = "peek" if intensity < 0.4 and _names.has("peek") else "suspicious"
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

	# ── Strike fire detection (bone scale trigger) ──
	if current_state == State.STRIKING and not _strike_fired:
		_strike_frames += 1
		if _strike_frames >= STRIKE_WARMUP and _strike_bone_idx >= 0 and _skeleton:
			var scale := _skeleton.get_bone_pose_scale(_strike_bone_idx)
			if scale.x > STRIKE_THRESHOLD:
				_strike_fired = true
				strike_fire_point.emit()
				print("🎬 🎯 STRIKE_FIRE detected!")

	# ── Detect when strike finishes → choose next state ──
	if current_state == State.STRIKING and cur_node == "strike_base":
		var pos: float = _playback.get_current_play_position()
		var length: float = _playback.get_current_length()
		if length > 0 and pos >= length - 0.05:
			_on_strike_complete()


func _on_sm_node_changed(from_node: String, to_node: String) -> void:
	"""Called when the StateMachine transitions to a different node."""
	# off_wall just ended → we're now standing
	if from_node == "off_wall" and to_node in ["idle", "suspicious", "angry", "peek"]:
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

	# return_wall just ended → back on wall
	elif from_node == "return_wall" and to_node == "idle_wall":
		_set_state(State.ON_WALL)

	# idle_wall_talk started
	elif to_node == "idle_wall_talk":
		_set_state(State.WALL_TALK)

	# idle_wall_talk_return ended → back to idle_wall (auto-advance)
	elif from_node == "idle_wall_talk_return" and to_node == "idle_wall":
		_set_state(State.ON_WALL)

	# Entered strike
	elif to_node == "strike_base":
		_set_state(State.STRIKING)
		_strike_fired = false
		_strike_frames = 0


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
