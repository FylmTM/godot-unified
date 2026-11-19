class_name ViewMeshes
## The 2D meshes and MultiMeshes of drift's multi views, built in code. The host writes every instance's
## TRANSFORM_2D (position, rotation, scale per axis), colour and custom data (UnifiedMultiView, src/godot/README.md),
## so a mesh is drawn at unit scale, in pixels: rocks at radius 1 m (scaled by the rock's radius in metres), bullets
## and gems (scaled by the pulse or stretch fill_frame gives them).


## A MultiMesh in the layout the host fills: TRANSFORM_2D, colours and custom data.
static func multimesh(mesh: Mesh) -> MultiMesh:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_2D
	mm.use_colors = true
	mm.use_custom_data = true
	mm.mesh = mesh
	return mm


## A convex polygon as a triangle fan around its centroid. UV.x is 0 at the centre and 1 on the rim (shaders
## outline with it), UV.y the corner's angle / TAU.
static func fan(points: PackedVector2Array) -> ArrayMesh:
	var hull := Geometry2D.convex_hull(points)
	if hull.size() > 1 and hull[0] == hull[hull.size() - 1]:
		hull.remove_at(hull.size() - 1)  # convex_hull closes the loop
	var c := Vector2.ZERO
	for p in hull:
		c += p
	c /= maxf(hull.size(), 1)
	var verts := PackedVector2Array()
	var uvs := PackedVector2Array()
	for i in hull.size():
		var a := hull[i]
		var b := hull[(i + 1) % hull.size()]
		verts.append(c)
		verts.append(a)
		verts.append(b)
		uvs.append(Vector2(0, 0))
		uvs.append(Vector2(1, float(i) / hull.size()))
		uvs.append(Vector2(1, float(i + 1) / hull.size()))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


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


static func material(shader: Shader) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = shader
	return m
