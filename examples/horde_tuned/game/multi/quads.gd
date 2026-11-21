class_name Quads
## The quads and MultiMeshes the tuned views draw with.


## A MultiMesh in the layout the host fills: TRANSFORM_2D, colours and custom data.
static func multimesh(mesh: Mesh) -> MultiMesh:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_2D
	mm.use_colors = true
	mm.use_custom_data = true
	mm.mesh = mesh
	return mm


## A quad from -half to +half, UV 0..1.
static func quad(half: Vector2) -> ArrayMesh:
	var a := -half
	var b := half
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector2Array([a, Vector2(b.x, a.y), b, a, b, Vector2(a.x, b.y)])
	arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array([Vector2(0, 0), Vector2(1, 0), Vector2(1, 1),
		Vector2(0, 0), Vector2(1, 1), Vector2(0, 1)])
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh
