class_name Quads
## The quad mesh and the MultiMesh layout every crowd and effect draws with.


## A MultiMesh in the layout the host fills (and the effects' ring buffers write): 2D transforms, colours and custom
## data.
static func multimesh(mesh: Mesh) -> MultiMesh:
	var instances := MultiMesh.new()
	instances.transform_format = MultiMesh.TRANSFORM_2D
	instances.use_colors = true
	instances.use_custom_data = true
	instances.mesh = mesh
	return instances


## A quad from -half to +half, UV 0..1 across it.
static func quad(half: Vector2) -> ArrayMesh:
	var low := -half
	var high := half
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector2Array([low, Vector2(high.x, low.y), high, low, high, Vector2(low.x, high.y)])
	arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array([Vector2(0, 0), Vector2(1, 0), Vector2(1, 1),
		Vector2(0, 0), Vector2(1, 1), Vector2(0, 1)])
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh
