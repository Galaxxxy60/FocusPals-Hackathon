extends Node3D
## Spring Bones — Second-Order Dynamics (t3ssel8r)
##
## Handles secondary motion for hair, hoodie strings, etc.
## Attach as child of the main scene node, then call:
##   setup(skeleton)        — once, after skeleton is ready
##   update(delta)          — every frame from _process
##   handle_input(event)    — from _unhandled_input for debug controls
##
## Debug: press F5 to toggle collider visualization, then use numpad to tune.

# ─── State ───────────────────────────────────────────────
var _skeleton: Skeleton3D = null
var _spring_bones: Array = []
var _spring_colliders: Array = []
var _debug_colliders: bool = false
var _debug_collider_meshes: Array = []
var _debug_selected_collider: int = 0

# ─── Collider Configs ────────────────────────────────────
# [type, bone_name, offset, radius, ...]
# type "sphere": ["sphere", bone, offset, radius]
# type "capsule": ["capsule", bone, offset, radius, half_height]
#   capsule axis = bone local Y, extends ±half_height from offset center
const COLLIDER_CONFIGS = [
	# Head sphere
	["sphere", "Jnt_C_Head", Vector3(-0.009, 0.092, 0.0), 0.135],
	# Center spine capsule
	["capsule", "Jnt_C_Spine2", Vector3(0.01, -0.14, 0.01), 0.16, 0.22],
	# Shoulder spheres
	["sphere", "Jnt_L_Shoulder", Vector3(-0.003, 0.098, 0.002), 0.14],
	["sphere", "Jnt_R_Shoulder", Vector3(-0.001, 0.108, 0.002), 0.14],
]

# ─── Spring Bone Configs ─────────────────────────────────
# [bone_name, frequency, damping, response, gravity]
# Second-Order Dynamics — clean, art-directable overlap motion
# frequency: Hz, how fast bone responds (higher = tighter follow, less lag)
# damping: 0-1+, oscillation control (0.3=bouncy, 0.7=smooth, 1.0=no overshoot)
# response: overshoot factor (0=sluggish, 1=normal, >1=anticipatory snap)
# gravity: downward acceleration (m/s²). 9.81 = earth gravity. Use 2-5 for hair.
# TIP: for overlap, give tip bones LOWER frequency than root bones
const BONE_CONFIGS = [
	# Front hair — snappy bounce
	["Jnt_L_FrontHair", 3.0, 0.4, 1.5, 3.0],
	["Jnt_R_FrontHair", 3.0, 0.4, 1.5, 3.0],
	# Side hair — root fast, tip slow = OVERLAP
	["Jnt_L_SideHair", 2.5, 0.5, 1.0, 4.0],
	["Jnt_L_SideHair2", 1.2, 0.35, 1.5, 5.0],
	["Jnt_R_SideHair", 2.5, 0.5, 1.0, 4.0],
	["Jnt_R_SideHair2", 1.2, 0.35, 1.5, 5.0],
	# Back hair — soft trail
	["Jnt_C_HairBack", 2.0, 0.45, 1.2, 4.0],
	# Hoodie strings — heavier, stronger gravity
	["Jnt_L_Strings",  3.0, 0.5, 1.0, 6.0],
	["Jnt_L_Strings2", 2.0, 0.4, 1.2, 7.0],
	["Jnt_L_strings3", 1.5, 0.35, 1.5, 8.0],
	["Jnt_L_strings4", 1.0, 0.3, 1.8, 9.0],
	["Jnt_R_strings",  3.0, 0.5, 1.0, 6.0],
	["Jnt_R_strings2", 2.0, 0.4, 1.2, 7.0],
	["Jnt_R_strings3", 1.5, 0.35, 1.5, 8.0],
	["Jnt_L_Shoulder4", 1.0, 0.3, 1.8, 9.0],  # Last bone in R string chain
]

# ─── Public API ──────────────────────────────────────────

func setup(skeleton: Skeleton3D) -> void:
	"""Call once after skeleton is ready."""
	_skeleton = skeleton
	_setup_spring_bones()

func update(delta: float) -> void:
	"""Call every frame from _process."""
	_update_spring_bones(delta)
	if _debug_colliders:
		_update_debug_collider_meshes()

func handle_input(event: InputEvent) -> void:
	"""Call from _unhandled_input for F5 debug + numpad tuning."""
	# F5 = toggle debug collider visualization
	if event is InputEventKey and event.pressed and event.keycode == KEY_F5:
		_debug_colliders = !_debug_colliders
		if _debug_colliders:
			print("🛡️ [DEBUG] Colliders ON — Numpad controls:")
			print("  Num 4/6 = X offset | Num 2/8 = Y offset | Num 1/3 = Z offset")
			print("  Num +/- = radius   | Num 7/9 = capsule height")
			print("  Num 0   = switch collider")
			_create_debug_collider_meshes()
		else:
			print("🛡️ [DEBUG] Colliders OFF")
			_remove_debug_collider_meshes()
		return

	# Numpad collider tuning (only when F5 debug is active)
	if _debug_colliders and event is InputEventKey and event.pressed:
		var changed := false
		var sel := _debug_selected_collider
		if sel >= 0 and sel < _spring_colliders.size():
			var col = _spring_colliders[sel]
			# Get bone basis to convert world directions → bone local
			var bone_idx: int = col["bone_idx"]
			var bone_global: Transform3D = _skeleton.global_transform * _skeleton.get_bone_global_pose(bone_idx)
			var bone_inv_basis: Basis = bone_global.basis.inverse()
			var step := 0.01
			match event.keycode:
				KEY_KP_ADD:  # Num+ = bigger radius
					col["radius"] += 0.005
					changed = true
				KEY_KP_SUBTRACT:  # Num- = smaller radius
					col["radius"] = maxf(0.01, col["radius"] - 0.005)
					changed = true
				KEY_KP_8:  # Num8 = world UP
					col["offset"] += bone_inv_basis * Vector3(0, step, 0)
					changed = true
				KEY_KP_2:  # Num2 = world DOWN
					col["offset"] += bone_inv_basis * Vector3(0, -step, 0)
					changed = true
				KEY_KP_6:  # Num6 = world RIGHT
					col["offset"] += bone_inv_basis * Vector3(step, 0, 0)
					changed = true
				KEY_KP_4:  # Num4 = world LEFT
					col["offset"] += bone_inv_basis * Vector3(-step, 0, 0)
					changed = true
				KEY_KP_3:  # Num3 = world FORWARD (Z+)
					col["offset"] += bone_inv_basis * Vector3(0, 0, step)
					changed = true
				KEY_KP_1:  # Num1 = world BACKWARD (Z-)
					col["offset"] += bone_inv_basis * Vector3(0, 0, -step)
					changed = true
				KEY_KP_9:  # Num9 = capsule taller
					if col["type"] == "capsule":
						col["half_height"] = col.get("half_height", 0.1) + 0.01
						changed = true
				KEY_KP_7:  # Num7 = capsule shorter
					if col["type"] == "capsule":
						col["half_height"] = maxf(0.01, col.get("half_height", 0.1) - 0.01)
						changed = true
				KEY_KP_0:  # Num0 = switch collider
					_debug_selected_collider = (_debug_selected_collider + 1) % _spring_colliders.size()
					var cn = _spring_colliders[_debug_selected_collider]["bone_name"]
					print("🛡️ Selected: [%d] %s (%s)" % [_debug_selected_collider, cn, _spring_colliders[_debug_selected_collider]["type"]])
					_remove_debug_collider_meshes()
					_create_debug_collider_meshes()
			if changed:
				_remove_debug_collider_meshes()
				_create_debug_collider_meshes()
				var bn = col["bone_name"]
				var r = col["radius"]
				var o = col["offset"]
				if col["type"] == "capsule":
					var hh = col.get("half_height", 0.1)
					print('🛡️ [%s] capsule r=%.3f hh=%.3f offset=(%.3f, %.3f, %.3f)' % [bn, r, hh, o.x, o.y, o.z])
				else:
					print('🛡️ [%s] sphere r=%.3f offset=(%.3f, %.3f, %.3f)' % [bn, r, o.x, o.y, o.z])

# ─── Setup ───────────────────────────────────────────────

func _setup_spring_bones() -> void:
	"""Configure spring bones using Second-Order Dynamics (t3ssel8r)."""
	if _skeleton == null:
		return

	_spring_bones.clear()
	for config in BONE_CONFIGS:
		var bone_name: String = config[0]
		var idx: int = _skeleton.find_bone(bone_name)
		if idx < 0:
			print("⚠️ Spring bone '%s' not found" % bone_name)
			continue

		var parent_idx: int = _skeleton.get_bone_parent(idx)
		var base_rot: Quaternion = _skeleton.get_bone_pose_rotation(idx)
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
		if bone_length <= 0.001:
			bone_length = 0.06
			bone_local_dir = Vector3.UP

		var tail_pos: Vector3 = bone_global.origin + bone_global.basis * bone_local_dir * bone_length

		# Second-Order Dynamics constants
		var freq: float = config[1]
		var damp: float = config[2]
		var resp: float = config[3]
		var grav: float = config[4]
		var w: float = 2.0 * PI * freq
		var k1: float = damp / (PI * freq)
		var k2: float = 1.0 / (w * w)
		var k3: float = resp * damp / (2.0 * PI * freq)

		_spring_bones.append({
			"idx": idx,
			"name": bone_name,
			"base_rot": base_rot,
			"bone_length": bone_length,
			"bone_local_dir": bone_local_dir,
			"gravity": grav,
			"k1": k1, "k2": k2, "k3": k3,
			"y": tail_pos,
			"yd": Vector3.ZERO,
			"xp": tail_pos,
		})

	if _spring_bones.size() > 0:
		print("🌿 Spring bones: %d configured (Second-Order Dynamics)" % _spring_bones.size())

	# Setup collision shapes (spheres & capsules)
	_spring_colliders.clear()
	for col_cfg in COLLIDER_CONFIGS:
		var col_type: String = col_cfg[0]
		var col_bone_name: String = col_cfg[1]
		var col_bone_idx: int = _skeleton.find_bone(col_bone_name)
		if col_bone_idx < 0:
			print("⚠️ Collider bone '%s' not found" % col_bone_name)
			continue
		var col_data = {
			"type": col_type,
			"bone_idx": col_bone_idx,
			"bone_name": col_bone_name,
			"offset": col_cfg[2],
			"radius": col_cfg[3],
		}
		if col_type == "capsule" and col_cfg.size() > 4:
			col_data["half_height"] = col_cfg[4]
		_spring_colliders.append(col_data)
	if _spring_colliders.size() > 0:
		print("🛡️ Spring colliders: %d shapes" % _spring_colliders.size())

# ─── Physics Update ──────────────────────────────────────

func _update_spring_bones(delta: float) -> void:
	"""Second-Order Dynamics: each tail smoothly follows its rest position with natural lag."""
	if _skeleton == null or _spring_bones.is_empty():
		return

	var dt: float = minf(delta, 0.033)
	if dt < 0.0001:
		return

	for sb in _spring_bones:
		var idx: int = sb["idx"]
		var parent_idx: int = _skeleton.get_bone_parent(idx)
		var base_rot: Quaternion = sb["base_rot"]
		var bone_length: float = sb["bone_length"]
		var bone_local_dir: Vector3 = sb["bone_local_dir"]

		# Parent transform
		var parent_global: Transform3D
		if parent_idx >= 0:
			parent_global = _skeleton.global_transform * _skeleton.get_bone_global_pose(parent_idx)
		else:
			parent_global = _skeleton.global_transform

		var bone_head: Vector3 = (_skeleton.global_transform * _skeleton.get_bone_global_pose(idx)).origin

		# Target tail = rest position (no gravity here — applied as acceleration below)
		var rest_dir_world: Vector3 = (parent_global.basis * Basis(base_rot) * bone_local_dir).normalized()
		var x: Vector3 = bone_head + rest_dir_world * bone_length

		# ─── Second-Order Dynamics ───
		var k1: float = sb["k1"]
		var k2: float = sb["k2"]
		var k3: float = sb["k3"]
		var y: Vector3 = sb["y"]
		var yd: Vector3 = sb["yd"]
		var xp: Vector3 = sb["xp"]

		# Input velocity estimate
		var xd: Vector3 = (x - xp) / dt

		# Stability clamp on k2
		var k2_stable: float = maxf(k2, maxf(dt * dt / 2.0 + dt * k1 / 2.0, dt * k1))

		# Integrate — gravity is an EXTERNAL ACCELERATION inside the ODE
		var gravity_accel: Vector3 = Vector3.DOWN * sb["gravity"]
		y = y + dt * yd
		yd = yd + dt * ((x + k3 * xd - y - k1 * yd) / k2_stable + gravity_accel)

		sb["xp"] = x

		# ─── Distance Constraint ───
		# Project y onto sphere of radius bone_length around bone_head
		# but PRESERVE the tangential velocity (don't kill gravity momentum!)
		var new_tail: Vector3 = y
		var to_tail: Vector3 = new_tail - bone_head
		if to_tail.length_squared() > 0.00001:
			var dir: Vector3 = to_tail.normalized()
			new_tail = bone_head + dir * bone_length
			# Project velocity: remove radial component, keep tangential
			var radial_vel: float = yd.dot(dir)
			yd = yd - dir * radial_vel  # only tangential velocity survives
		else:
			new_tail = x

		# ─── Collider Collision ───
		var collider_pushed := false
		for _iter in range(3):
			var was_pushed := false
			for col in _spring_colliders:
				var col_global: Transform3D = _skeleton.global_transform * _skeleton.get_bone_global_pose(col["bone_idx"])
				var center: Vector3 = col_global.origin + col_global.basis * col["offset"]
				var col_radius: float = col["radius"]
				var closest_point: Vector3

				if col["type"] == "capsule":
					var hh: float = col.get("half_height", 0.1)
					var axis_dir: Vector3 = col_global.basis.y
					var cap_top: Vector3 = center + axis_dir * hh
					var cap_bot: Vector3 = center - axis_dir * hh
					var ab: Vector3 = cap_bot - cap_top
					var ab_len_sq: float = ab.length_squared()
					if ab_len_sq > 0.00001:
						var t: float = clampf((new_tail - cap_top).dot(ab) / ab_len_sq, 0.0, 1.0)
						closest_point = cap_top + ab * t
					else:
						closest_point = center
				else:
					closest_point = center

				var diff: Vector3 = new_tail - closest_point
				var dist: float = diff.length()
				if dist < col_radius and dist > 0.0001:
					new_tail = closest_point + diff.normalized() * col_radius
					was_pushed = true
					collider_pushed = true

			if was_pushed and _iter < 2:
				var to_tail2: Vector3 = new_tail - bone_head
				if to_tail2.length_squared() > 0.00001:
					new_tail = bone_head + to_tail2.normalized() * bone_length
			if not was_pushed:
				break

		# Update state
		sb["y"] = new_tail
		# Only dampen velocity on ACTUAL collider push (not distance constraint)
		if collider_pushed:
			sb["yd"] = yd * 0.1
		else:
			sb["yd"] = yd

		# ─── Compute Bone Rotation ───
		var parent_inv_basis: Basis = parent_global.basis.inverse()
		var local_rest: Vector3 = (parent_inv_basis * rest_dir_world).normalized()
		var final_dir_world: Vector3 = (new_tail - bone_head).normalized()
		var local_final_dir: Vector3 = (parent_inv_basis * final_dir_world).normalized()

		var rot_axis: Vector3 = local_rest.cross(local_final_dir)
		if rot_axis.length_squared() > 0.000001:
			rot_axis = rot_axis.normalized()
			var rot_angle: float = local_rest.angle_to(local_final_dir)
			var swing: Quaternion = Quaternion(rot_axis, rot_angle)
			_skeleton.set_bone_pose_rotation(idx, (swing * base_rot).normalized())
		else:
			_skeleton.set_bone_pose_rotation(idx, base_rot)

# ─── Debug Collider Visualization ────────────────────────

func _create_debug_collider_meshes() -> void:
	"""Create translucent meshes to visualize collision volumes."""
	_remove_debug_collider_meshes()
	for i in range(_spring_colliders.size()):
		var col = _spring_colliders[i]
		var mesh: Mesh

		if col["type"] == "capsule":
			var cap := CapsuleMesh.new()
			cap.radius = col["radius"]
			cap.height = col.get("half_height", 0.1) * 2.0 + col["radius"] * 2.0
			cap.radial_segments = 16
			cap.rings = 4
			mesh = cap
		else:
			var sph := SphereMesh.new()
			sph.radius = col["radius"]
			sph.height = col["radius"] * 2.0
			sph.radial_segments = 16
			sph.rings = 8
			mesh = sph

		var mat := StandardMaterial3D.new()
		# Selected collider = brighter
		if i == _debug_selected_collider:
			mat.albedo_color = Color(0.4, 1.0, 0.5, 0.35)
		else:
			mat.albedo_color = Color(0.2, 1.0, 0.3, 0.2)
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mesh.material = mat

		var node := MeshInstance3D.new()
		node.mesh = mesh
		node.name = "DebugCollider_%d" % i
		add_child(node)
		_debug_collider_meshes.append(node)
	_update_debug_collider_meshes()

func _remove_debug_collider_meshes() -> void:
	"""Remove all debug collider meshes."""
	for node in _debug_collider_meshes:
		if is_instance_valid(node):
			node.queue_free()
	_debug_collider_meshes.clear()

func _update_debug_collider_meshes() -> void:
	"""Move debug meshes to match current collider bone positions + rotations."""
	if _skeleton == null:
		return
	for i in range(mini(_spring_colliders.size(), _debug_collider_meshes.size())):
		var col = _spring_colliders[i]
		var node = _debug_collider_meshes[i]
		var col_global: Transform3D = _skeleton.global_transform * _skeleton.get_bone_global_pose(col["bone_idx"])
		var center: Vector3 = col_global.origin + col_global.basis * col["offset"]
		node.global_position = center
		# Capsules need to match bone rotation (axis = bone Y)
		if col["type"] == "capsule":
			node.global_transform.basis = col_global.basis
