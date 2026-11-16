// Static geometry from a level file (src/level/SPEC.md): one static body per level body, in file order.
package physics

import "core:fmt"

import "unified:b3"
import "unified:dmath"
import "unified:level"

// Creates every static body of the level, in file order, and returns how many. Shapes without a
// category in the file get `default_category`. `problem` names the first level shape Box3D refused (a hull it
// can't build: under 4 points, or past its 128 edges), "" when every shape was built: a refused shape is skipped,
// a hole in the level's collision the game must not run with (the games assert on it).
create_static :: proc(
	world: ^World,
	level_data: ^level.Level,
	default_category: u64 = 1,
) -> (
	count: int,
	problem: string,
) {
	for &level_body, body_index in level_data.bodies {
		body_def := b3.default_body_def()
		body_def.position = level_body.pos
		body_def.rotation = level_body.rot
		id := b3.create_body(world.id, &body_def)
		shape_def := b3.default_shape_def()
		shape_def.base_material.friction = level_body.friction
		shape_def.base_material.restitution = level_body.restitution
		shape_def.base_material.user_material_id = level_body.material
		shape_def.filter.category_bits = level_body.category if level_body.category != 0 else default_category
		for &shape, shape_index in level_body.shapes {
			if !create_shape(id, &shape_def, &shape) && problem == "" {
				problem = fmt.tprintf(
					"level body %d %q, shape %d (%v%s): Box3D refused it",
					body_index,
					level_body.name,
					shape_index,
					shape.kind,
					fmt.tprintf(" of %d points", len(shape.points)) if shape.kind == .Hull else "",
				)
			}
		}
	}
	return len(level_data.bodies), problem
}

// Adds one level shape to a body (any type: games use it for their own level bodies too); false when Box3D refused
// it (a hull under 4 points or past its 128 edges) and nothing was added.
create_shape :: proc(body: b3.Body_Id, shape_def: ^b3.Shape_Def, shape: ^level.Shape) -> bool {
	identity := shape.rot == {0, 0, 0, 1}
	id: b3.Shape_Id
	switch shape.kind {
	case .Box:
		hull := b3.make_box_hull(shape.half.x, shape.half.y, shape.half.z)
		if identity && shape.pos == {} {
			id = b3.create_hull_shape(body, shape_def, &hull.base)
		} else {
			transformed := b3.clone_and_transform_hull(&hull.base, {shape.pos, shape.rot}, {1, 1, 1})
			if transformed == nil do return false
			id = b3.create_hull_shape(body, shape_def, transformed)
			b3.destroy_hull(transformed)
		}
	case .Sphere:
		sphere := b3.Sphere{shape.pos, shape.radius}
		id = b3.create_sphere_shape(body, shape_def, &sphere)
	case .Capsule:
		axis := dmath.quat_rotate(shape.rot, {0, shape.half_height, 0})
		capsule := b3.Capsule{shape.pos - axis, shape.pos + axis, shape.radius}
		id = b3.create_capsule_shape(body, shape_def, &capsule)
	case .Hull:
		if len(shape.points) < 4 do return false
		hull := b3.create_hull(shape.points, 64)
		if hull == nil do return false
		id = b3.create_hull_shape(body, shape_def, hull)
		b3.destroy_hull(hull)
	}
	return id.index1 != 0
}
