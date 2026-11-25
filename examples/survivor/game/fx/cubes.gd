class_name Cubes
extends MultiMeshInstance3D
## One kind of cube spray (enemy deaths, gem sparkles, fire...): a ring buffer of MultiMesh instances whose flight the
## shader computes from their birth (cubes.gdshader), so a cube costs GDScript one write when a burst makes it and
## nothing per frame, and a burst makes no node. A burst past the buffer's size overwrites the oldest cubes. Every kind
## shares one material, so its shader compiles once; the kind's gravity and life are this node's instance uniforms.

## The cubes fly anywhere in the arena and the shader moves them: the node is never culled.
const BOUNDS := AABB(Vector3(-200, -50, -200), Vector3(400, 100, 400))

var _next := 0
## The instances born so far, up to the capacity: 0 to _born - 1 (the ring fills in order).
var _born := 0


## Sets the kind up: at most `capacity` cubes at once, each a `cube` drawn with `shared` (cubes.gdshader), falling at
## `gravity` (m/s², up is positive) and gone after `life` seconds.
func setup(capacity: int, cube: Mesh, shared: ShaderMaterial, gravity: float, life: float) -> void:
	multimesh = MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.use_colors = true
	multimesh.use_custom_data = true
	multimesh.mesh = cube
	multimesh.instance_count = capacity
	multimesh.visible_instance_count = 0  # none born yet: drawn as the ring fills
	material_override = shared
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	custom_aabb = BOUNDS
	set_instance_shader_parameter(&"gravity", gravity)
	set_instance_shader_parameter(&"life", life)


## `amount` cubes from `at` in `color`, flying every way at `speed` × 0.4..1 m/s, `size` × 0.6..1.2 across, born at
## `now` (the shader's clock).
func burst(at: Vector3, color: Color, amount: int, speed: float, size: float, now: float) -> void:
	var count := multimesh.instance_count
	for i in amount:
		var dir := Vector3(randf_range(-1, 1), randf_range(-1, 1), randf_range(-1, 1))
		var vel := dir.normalized() * speed * randf_range(0.4, 1.0) if dir.length_squared() > 0.0001 else Vector3.ZERO
		var turn := Basis.from_euler(Vector3(randf(), randf(), randf()) * TAU)
		multimesh.set_instance_transform(_next, Transform3D(turn.scaled(Vector3.ONE * size * randf_range(0.6, 1.2)), at))
		multimesh.set_instance_color(_next, color)
		multimesh.set_instance_custom_data(_next, Color(vel.x, vel.y, vel.z, now))
		_next = (_next + 1) % count
	_born = mini(_born + amount, count)
	multimesh.visible_instance_count = _born
