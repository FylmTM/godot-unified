@tool
extends MeshInstance3D
## The visual of a ramp: the triangles of its body's convex collision shape (the sibling "Shape"), so what is drawn is
## what the sim and the navigation bake collide with. The wedge's six points: the top edge's two, the foot's two, and
## the two under the top edge; each face wound so it faces away from the wedge's centre.

const FACES: Array[int] = [0, 2, 1, 1, 2, 3, 0, 4, 2, 1, 3, 5, 0, 1, 4, 1, 5, 4, 2, 4, 3, 3, 4, 5]


func _ready() -> void:
	var shape := (get_parent().get_node(^"Shape") as CollisionShape3D).shape as ConvexPolygonShape3D
	var points := shape.points
	if points.size() != 6:
		push_error("wedge_mesh: %s's shape needs the wedge's 6 points" % get_parent().name)
		return
	var center := Vector3.ZERO
	for p in points:
		center += p / 6.0
	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	for f in range(0, FACES.size(), 3):
		var a := points[FACES[f]]
		var b := points[FACES[f + 1]]
		var c := points[FACES[f + 2]]
		# (b - a) x (c - a) made to point outward, then a, c, b: Godot's front faces are clockwise from the front
		if (b - a).cross(c - a).dot((a + b + c) / 3.0 - center) > 0.0:
			var swap := b
			b = c
			c = swap
		tool.add_vertex(a)
		tool.add_vertex(c)
		tool.add_vertex(b)
	tool.generate_normals()
	mesh = tool.commit()
