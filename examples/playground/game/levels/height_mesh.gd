@tool
extends MeshInstance3D
## Draws the HeightMapShape3D of the sibling CollisionShape3D "Shape" (Godot draws no mesh for one): a triangle per
## half cell, split along the same diagonal as the collision, one metre a cell, centred like the shape.


func _ready() -> void:
	var shape_node := get_parent().get_node_or_null("Shape") as CollisionShape3D
	if shape_node == null or not (shape_node.shape is HeightMapShape3D):
		return
	var height_map := shape_node.shape as HeightMapShape3D
	var width := height_map.map_width
	var depth := height_map.map_depth
	var heights := height_map.map_data
	var half := Vector2((width - 1) * 0.5, (depth - 1) * 0.5)
	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	for z: int in depth - 1:
		for x: int in width - 1:
			var a := Vector3(x - half.x, heights[z * width + x], z - half.y)
			var b := Vector3(x + 1 - half.x, heights[z * width + x + 1], z - half.y)
			var c := Vector3(x - half.x, heights[(z + 1) * width + x], z + 1 - half.y)
			var d := Vector3(x + 1 - half.x, heights[(z + 1) * width + x + 1], z + 1 - half.y)
			for vertex: Vector3 in [a, b, c, b, d, c]:
				tool.add_vertex(vertex)
	tool.generate_normals()
	mesh = tool.commit()
