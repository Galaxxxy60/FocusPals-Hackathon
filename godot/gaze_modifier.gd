extends SkeletonModifier3D
## Gaze Modifier — Post-Animation Bone Rotation
##
## SkeletonModifier3D processes AFTER the AnimationPlayer writes bones.
## This is the official Godot 4.4+ solution for additive bone control
## that doesn't get overwritten by animation playback.
##
## Usage: attach as child of Skeleton3D, then set gaze_* vars from main.gd.

# ─── Gaze State (set by main.gd) ──────────────────────────
var gaze_active: bool = false
var gaze_blend: float = 0.0              # 0 = pure animation, 1 = full gaze
var gaze_blend_target: float = 0.0       # Target blend weight
var gaze_delta_head: Quaternion = Quaternion.IDENTITY   # Current smoothed rotation
var gaze_delta_neck: Quaternion = Quaternion.IDENTITY
var gaze_target_head: Quaternion = Quaternion.IDENTITY   # Target to slerp toward
var gaze_target_neck: Quaternion = Quaternion.IDENTITY
var gaze_lerp_speed: float = 5.0         # Slerp speed toward target

# Bone indices (set during setup)
var head_bone_idx: int = -1
var neck_bone_idx: int = -1

# Base rotation capture: the animation's natural pose (no gaze overlay)
var _head_base_rot: Quaternion = Quaternion.IDENTITY
var _neck_base_rot: Quaternion = Quaternion.IDENTITY
var _base_captured: bool = false
var _was_blending: bool = false  # For one-shot debug print

# Constants
const BLEND_SPEED: float = 4.0

# ─── Arm IK State (set by main.gd) ────────────────────────
var arm_ik_active: bool = false
var arm_ik_blend: float = 0.0
var arm_ik_blend_target: float = 0.0
var arm_ik_target: Vector3 = Vector3.ZERO  # World-space target point
const ARM_IK_BLEND_SPEED: float = 5.0

# Arm bone indices (set during setup)
var arm1_bone_idx: int = -1   # Jnt_R_Arm1 (upper arm)
var arm2_bone_idx: int = -1   # Jnt_R_Arm2 (forearm)
var hand_bone_idx: int = -1   # Jnt_R_Hand (end effector)

# Base rotations captured from animation
var _arm1_base_rot: Quaternion = Quaternion.IDENTITY
var _arm2_base_rot: Quaternion = Quaternion.IDENTITY

# ─── Spring Bones Reference ──────────────────────────────
# If set, spring bones update() will be called after gaze (same post-anim timing)
var spring_bones_node: Node = null
var ghost_freeze: bool = false  # When true, skip spring bones (ghost BS_Appear conflict)

# ─── Debug callback (optional, set by main.gd) ───────────
var debug_callback: Callable = Callable()

func _ready() -> void:
	active = true
	influence = 1.0

func _process_modification_with_delta(delta: float) -> void:
	"""Called by Skeleton3D AFTER AnimationPlayer has written bone poses.
	This is the perfect time to apply additive gaze rotations."""
	var skel: Skeleton3D = get_skeleton()
	if skel == null:
		return

	# ─── Gaze System ──────────────────────────────────────
	if gaze_active and head_bone_idx >= 0:
		_update_gaze(skel, delta)

	# ─── Arm IK ──────────────────────────────────────────
	if arm1_bone_idx >= 0 and arm2_bone_idx >= 0:
		_update_arm_ik(skel, delta)

	# ─── Spring Bones ─────────────────────────────────────
	if not ghost_freeze and spring_bones_node and spring_bones_node.has_method("update"):
		spring_bones_node.update(delta)

	# ─── Debug Callback ──────────────────────────────────
	if debug_callback.is_valid():
		debug_callback.call(delta)


func _update_gaze(skel: Skeleton3D, delta: float) -> void:
	"""Additive gaze: blend between animation's base rotation and gaze target."""

	# 0. Capture the animation's bone rotation when gaze ISN'T active.
	#    Here in _process_modification_with_delta, the bones contain the
	#    ANIMATION'S output (not our previous modification) — this is the
	#    key advantage of SkeletonModifier3D!
	#    We still only capture when blend ≈ 0 to avoid feedback loops from
	#    the influence system.
	if gaze_blend < 0.01:
		if head_bone_idx >= 0:
			_head_base_rot = skel.get_bone_pose_rotation(head_bone_idx)
		if neck_bone_idx >= 0:
			_neck_base_rot = skel.get_bone_pose_rotation(neck_bone_idx)
		if not _base_captured:
			_base_captured = true
			print("👀 GazeModifier: base rotation captured (head=%s)" % str(_head_base_rot))

	# 1. Smooth blend weight (fade in/out)
	var blend_t: float = clampf(BLEND_SPEED * delta, 0.0, 1.0)
	gaze_blend = lerpf(gaze_blend, gaze_blend_target, blend_t)

	# 2. Slerp toward target rotation
	var slerp_t: float = clampf(gaze_lerp_speed * delta, 0.0, 1.0)
	gaze_delta_head = gaze_delta_head.slerp(gaze_target_head, slerp_t).normalized()
	gaze_delta_neck = gaze_delta_neck.slerp(gaze_target_neck, slerp_t).normalized()

	# 3. When blend ≈ 0, no need to modify bones — animation pose is already correct
	if gaze_blend < 0.005:
		if _was_blending:
			_was_blending = false
			print("👀 GazeModifier: blend faded out (gaze inactive)")
		return

	# One-shot print when gaze starts affecting bones
	if not _was_blending:
		_was_blending = true
		print("👀 GazeModifier: blend ACTIVE! blend=%.3f target=%.3f delta_head=%s" % [gaze_blend, gaze_blend_target, str(gaze_delta_head)])

	# 4. Blend between base rotation and base+gaze.
	#    base_rot → the animation's natural head position (no chin-up)
	#    base_rot * gaze_delta → gaze applied on top of animation
	if head_bone_idx >= 0:
		var target_rot: Quaternion = (_head_base_rot * gaze_delta_head).normalized()
		var final_rot: Quaternion = _head_base_rot.slerp(target_rot, gaze_blend).normalized()
		skel.set_bone_pose_rotation(head_bone_idx, final_rot)
	if neck_bone_idx >= 0:
		var target_rot: Quaternion = (_neck_base_rot * gaze_delta_neck).normalized()
		var final_rot: Quaternion = _neck_base_rot.slerp(target_rot, gaze_blend).normalized()
		skel.set_bone_pose_rotation(neck_bone_idx, final_rot)


# ─── Arm IK (Right Arm Procedural Pointing) ──────────────────
func _update_arm_ik(skel: Skeleton3D, delta: float) -> void:
	"""Additive IK: make right arm point towards arm_ik_target."""

	# Smooth blend weight
	var blend_t: float = clampf(ARM_IK_BLEND_SPEED * delta, 0.0, 1.0)
	arm_ik_blend = lerpf(arm_ik_blend, arm_ik_blend_target, blend_t)

	# Capture base rotations when IK is inactive
	if arm_ik_blend < 0.01:
		_arm1_base_rot = skel.get_bone_pose_rotation(arm1_bone_idx)
		_arm2_base_rot = skel.get_bone_pose_rotation(arm2_bone_idx)
		return

	# Get current arm bone positions in world space
	var arm1_global := skel.global_transform * skel.get_bone_global_pose(arm1_bone_idx)
	var arm2_global := skel.global_transform * skel.get_bone_global_pose(arm2_bone_idx)
	var arm1_pos := arm1_global.origin
	var arm2_pos := arm2_global.origin

	# Current and desired directions (world space)
	var current_dir := (arm2_pos - arm1_pos).normalized()
	var desired_dir := (arm_ik_target - arm1_pos).normalized()

	if current_dir.length() < 0.001 or desired_dir.length() < 0.001:
		return

	# World-space rotation from current arm direction to desired
	var axis := current_dir.cross(desired_dir)
	if axis.length() < 0.0001:
		return  # Already pointing at target
	axis = axis.normalized()
	var angle := current_dir.angle_to(desired_dir)
	angle = clampf(angle, -1.2, 1.2)  # Max ~70° from baked pose
	var world_delta := Quaternion(axis, angle)

	# Apply world delta to get new world rotation for this bone
	var bone_world_rot := arm1_global.basis.get_rotation_quaternion()
	var new_world_rot := (world_delta * bone_world_rot).normalized()

	# Convert new world rotation back to parent-bone space
	var parent_idx := skel.get_bone_parent(arm1_bone_idx)
	var parent_world_rot := Quaternion.IDENTITY
	if parent_idx >= 0:
		var parent_global := skel.global_transform * skel.get_bone_global_pose(parent_idx)
		parent_world_rot = parent_global.basis.get_rotation_quaternion()
	var new_local_rot := (parent_world_rot.inverse() * new_world_rot).normalized()

	# Blend between animation pose and IK pose
	var anim_rot := skel.get_bone_pose_rotation(arm1_bone_idx)
	var final_rot := anim_rot.slerp(new_local_rot, arm_ik_blend).normalized()
	skel.set_bone_pose_rotation(arm1_bone_idx, final_rot)
