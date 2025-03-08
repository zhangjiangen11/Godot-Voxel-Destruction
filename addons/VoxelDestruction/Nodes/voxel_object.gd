@tool
@icon("voxel_object.svg")
extends MultiMeshInstance3D
class_name VoxelObject

@export var invulnerable = false
@export var darkening = true
@export_subgroup("Debri")
@export_enum("None", "Rigid Bodies", "Multimesh") var debri_type = 2
@export var debri_weight = 1
@export_range(0, 1, .1) var debri_density = .2
@export var debri_lifetime = 5
@export_subgroup("Dithering")
@export_range(0, .20, .01) var dark_dithering = 0.0:
	set(value):
		dark_dithering = value
		populate_mesh()
@export_range(0, .20, .01) var light_dithering = 0.0:
	set(value):
		light_dithering = value
		populate_mesh()
@export_range(0, 1, .1) var dithering_bias = 0.5:
	set(value):
		dithering_bias = value
		populate_mesh()
@export var dithering_seed: int = 0:
	set(value):
		dithering_seed = value
		populate_mesh()
@export_subgroup("Experimental")
@export var remove_floating_voxels = false
@export_subgroup("Resources")
@export var voxel_resource: VoxelResource
@export var damage_resource: DamageResource
@export_storage var size = Vector3(.1, .1, .1)
var _collision_shapes = {}
var _collision_shapes_list = []
var _debri_queue = []
var _debri_called = false
var _mutex: Mutex
var _semaphore: Semaphore
var _thread: Thread
var _exit_thread := false
@onready var hp: float = 1


func _ready() -> void:
	if not Engine.is_editor_hint():
		var shape = BoxShape3D.new()
		shape.size = size
		for i in multimesh.instance_count:
			var body = StaticBody3D.new()
			var shapenode = CollisionShape3D.new()
			shapenode.shape = shape
			body.position = voxel_resource.positions[i]*size
			body.add_child(shapenode)
			add_child(body, false, Node.INTERNAL_MODE_BACK)
			_collision_shapes[body] = i
			voxel_resource.colors[i] = multimesh.get_instance_color(i)
		if debri_type == 1:
			damage_resource.pool_rigid_bodies(min(multimesh.instance_count, 1000))
		_collision_shapes_list = _collision_shapes.keys()
		_mutex = Mutex.new()
		_semaphore = Semaphore.new()
		_exit_thread = false

		_thread = Thread.new()
		_thread.start(_flood_fill)


func populate_mesh():
	if Engine.get_frames_drawn() != 0:
		multimesh = MultiMesh.new()
		multimesh.transform_format = MultiMesh.TRANSFORM_3D
		multimesh.use_colors = true
		multimesh.instance_count = voxel_resource.positions.size()
		var mesh = BoxMesh.new()
		mesh.material = preload("res://addons/VoxelDestruction/Resources/voxel_material.tres")
		mesh.size = size
		multimesh.mesh = mesh
		
		var random = RandomNumberGenerator.new()
		random.set_seed(dithering_seed)
			
		for i in multimesh.instance_count:
			var dark_variation = random.randf_range(0, dark_dithering)
			var light_variation = random.randf_range(0, light_dithering)
			var dithered_color = Color.WHITE
			if dark_dithering == 0 or light_dithering == 0:
				if dark_dithering == 0:
					dithered_color = voxel_resource.colors[i].lightened(light_variation)
				elif light_dithering == 0:
					dithered_color = voxel_resource.colors[i].darkened(dark_variation)
			else:
				dithered_color = voxel_resource.colors[i].darkened(dark_variation) if randf() > dithering_bias else voxel_resource.colors[i].lightened(light_variation)
			
			multimesh.set_instance_transform(i, Transform3D(Basis(), voxel_resource.positions[i]*size))
			multimesh.set_instance_color(i, dithered_color)


func reset():
	damage_resource.positions = voxel_resource.positions
	damage_resource.positions_dict = voxel_resource.positions_dict
	damage_resource.health.fill(100)
	for body in _collision_shapes:
		body.get_child(0).disabled = false
	populate_mesh()
	_set_hp()


func _damage_voxel(body: StaticBody3D, damager: VoxelDamager):
	var voxid = _collision_shapes[body]
	if voxid == -1:
		return  # Skip if voxel not found
	var decay = damager.global_pos.distance_to(body.global_position) / damager.range
	var damage = damager.base_damage * damager.damage_curve.sample(decay)
	var power = damager.base_power * damager.power_curve.sample(decay)/max(debri_weight, .1)
	var health = damage_resource.health[voxid] - damage
	health = clamp(health, 0, 100)
	damage_resource.health[voxid] = health
	if health != 0:
		if darkening:
			multimesh.set_instance_color(voxid, voxel_resource.colors[voxid].darkened(1.0 - (health * 0.01)))
	else:
		if body.get_child(0).disabled == false:
			var vox_pos = Vector3i(voxel_resource.positions[voxid])
			var damage_id = damage_resource.positions_dict[vox_pos]
			if damage_id != -1:
				damage_resource.positions_dict.erase(vox_pos)
			multimesh.set_instance_transform(voxid, Transform3D())
			body.get_child(0).disabled = true
			_debri_queue.append({ "pos": Vector3(vox_pos)*size + global_position, "origin": damager.global_pos, "power": power }) 
			if debri_type == 0:
				_start_debri("_no_debri", true)
			elif debri_type == 1:
				_start_debri("_create_debri_rigid_bodies", true)
			elif debri_type == 2:
				_start_debri("_create_debri_multimesh", true)


func _start_debri(function, check_floating):
	if _debri_called or debri_lifetime == 0 or debri_density == 0:
		return
	if check_floating and remove_floating_voxels:
		call_deferred("_remove_detached_voxels_start")
	damage_resource.positions = PackedVector3Array(damage_resource.positions_dict.keys())
	_debri_called = true
	call_deferred(function)
	_set_hp()


func _no_debri():
	_debri_called = false


func _create_debri_multimesh():
	var gravity_magnitude : float = ProjectSettings.get_setting("physics/3d/default_gravity")
	var debri_states = []
	var multi_mesh_instance = MultiMeshInstance3D.new()
	var multi_mesh = MultiMesh.new()
	multi_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	multi_mesh_instance.top_level = true
	multi_mesh_instance.multimesh = multi_mesh
	multi_mesh.mesh = preload("res://addons/VoxelDestruction/Resources/debri.tres").duplicate()
	multi_mesh.mesh.size = size
	multi_mesh.transform_format = MultiMesh.TRANSFORM_3D
	multi_mesh.instance_count = _debri_queue.size()
	add_child(multi_mesh_instance)
	var idx = 0
	for debris_data in _debri_queue:
		# Control debri amount
		if randf() > debri_density: continue
		
		var debris_pos = debris_data.pos
		
		# Store data for manual physics update
		debri_states.append({
			"position": debris_pos,
			"velocity": (debris_pos - debris_data.origin).normalized() * -debris_data.power,
		})
		
		multi_mesh.set_instance_transform(idx, Transform3D(Basis(), debris_pos))
		idx += 1
	var current_lifetime = debri_lifetime
	_debri_called = false
	_debri_queue.clear()
	while current_lifetime > 0:
		var delta = get_physics_process_delta_time()
		current_lifetime -= delta
		for i in debri_states.size():
			var data = debri_states[i]
			data["velocity"].x *= .98
			data["velocity"].z *= .98
			data["velocity"].y -= gravity_magnitude * delta * debri_weight
			data["position"] += data["velocity"] * delta * 2
			multi_mesh.set_instance_transform(i, Transform3D(Basis(), data["position"]))
		await get_tree().process_frame
	multi_mesh_instance.queue_free()


func _create_debri_rigid_bodies():
	# Pre-cache children
	var debri_objects = []  # To store all the debris
	for debris_data in _debri_queue:
		# Control debri amount
		if randf() > debri_density: continue
		# Retrieve/generate debri
		var debri = damage_resource.get_debri()
		debri.name = "VoxelDebri"
		debri.top_level = true
		debri.show()
		# Cache shape and mesh if possible
		var shape = debri.get_child(0)
		var mesh = debri.get_child(1)
		# Set size/position in a single step
		add_child(debri, true, Node.INTERNAL_MODE_BACK)
		var debris_pos = debris_data.pos
		debri.global_position = debris_pos
		shape.shape.size = size
		mesh.mesh.size = size
		# Launch debri
		var velocity = (debris_pos - debris_data.origin).normalized() * debris_data.power
		debri.freeze = false
		debri.gravity_scale = debri_weight
		debri.apply_impulse(velocity)
		# Add the debri to list
		debri_objects.append(debri)
	_debri_called = false
	_debri_queue.clear()
	
	await get_tree().create_timer(debri_lifetime).timeout
	if not debri_objects.is_empty():
		var tween = get_tree().create_tween()
		for debri in debri_objects:
			var shape = debri.get_child(0)
			var mesh = debri.get_child(1)
			tween.parallel().tween_property(shape, "scale", Vector3(.01, .01, .01), 1)
			tween.parallel().tween_property(mesh, "scale", Vector3(.01, .01, .01), 1)
		await get_tree().create_timer(1).timeout
	
		for debri in debri_objects:
			_restore_debri_rigid_bodies(debri)


func _restore_debri_rigid_bodies(debri):
	if is_instance_valid(debri.get_parent()):
		debri.get_parent().remove_child(debri)
		debri.get_child(0).scale = Vector3(1, 1, 1)
		debri.get_child(1).scale = Vector3(1, 1, 1)
		debri.hide()
		damage_resource.debri_pool.append(debri)


func _remove_detached_voxels_start():
	var res = damage_resource
	var origin: Vector3i
	if not voxel_resource.origin in res.positions_dict:
		if not damage_resource.positions.is_empty():
			voxel_resource.origin = Vector3i(Array(damage_resource.positions).pick_random())
	_semaphore.post()


func _flood_fill():
	while true:
		_semaphore.wait()
		
		_mutex.lock()
		var should_exit = _exit_thread
		_mutex.unlock()
		
		if should_exit:
			break
		
		var queue = [voxel_resource.origin]
		var visited = {}
		var damage_positions_dict = damage_resource.positions_dict
		
		visited[voxel_resource.origin] = null
		
		var offsets = [
			Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
			Vector3i(0, 1, 0), Vector3i(0, -1, 0),
			Vector3i(0, 0, 1), Vector3i(0, 0, -1)
		]
		
		var front = 0
		while front < queue.size():
			var vox = queue[front]
			front += 1
			
			for offset in offsets:
				var neighbor_vox = vox + offset
				
				if not visited.has(neighbor_vox) and damage_positions_dict.has(neighbor_vox):
					visited[neighbor_vox] = null
					queue.append(neighbor_vox)
		
		var to_remove = []
		for vox in damage_positions_dict:
			if not visited.has(vox):
				to_remove.append(vox)
		
		
		_mutex.lock()
		for vox in to_remove:
			var voxid = voxel_resource.positions_dict.get(vox, -1)
			if voxid != -1:
				damage_resource.positions_dict.erase(vox)
				multimesh.set_instance_transform(voxid, Transform3D())
				call_deferred("_remove_vox", voxid)
		damage_resource.positions = PackedVector3Array(damage_resource.positions_dict.keys())
		_set_hp()
		_mutex.unlock()


func _remove_vox(voxid):
	var collision_shape = _collision_shapes_list[voxid].get_child(0)
	collision_shape.disabled = true



func _set_hp():
	hp = float(int(float(damage_resource.positions.size())/float(voxel_resource.positions.size())*100))/100
