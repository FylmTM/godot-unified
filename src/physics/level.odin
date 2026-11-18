// Static geometry from a level file (src/level/SPEC.md): one static body per level body, in file order.
package physics

import "core:fmt"

import box3d "box3d:bindings"
import "unified:dmath"
import "unified:level"

// Creates every static body of the level, in file order (the World's, when made before `extra`: call it first in
// world_create). Shapes without a category in the file get `default_category`. `problem` names the first level shape
// Box3D refused (a hull it can't build: under 4 points, or past its edge limit), "" when every shape was built: a
// refused shape is skipped, a hole in the level's collision the game must not run with (the games assert on it).
create_static :: proc(world: ^World, level_data: ^level.Level, default_category: u64 = 1) -> (problem: string) {
	for &level_body, body_index in level_data.bodies {
		body_def := transmute(Body_Def)box3d.DefaultBodyDef()
		body_def.position = level_body.pos
		body_def.rotation = level_body.rot
		id := box3d.CreateBody(world.id, (^box3d.BodyDef)(&body_def))
		body_created(world, id, 0)
		shape_def := transmute(Shape_Def)box3d.DefaultShapeDef()
		shape_def.base_material.friction = level_body.friction
		shape_def.base_material.restitution = level_body.restitution
		shape_def.base_material.user_material_id = level_body.material
		shape_def.filter.category = level_body.category if level_body.category != 0 else default_category
		for &shape, shape_index in level_body.shapes {
			if !level_shape(id, &shape_def, &shape) && problem == "" {
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
	return problem
}

// Adds one level shape to a body (any type: games use it for their own level bodies too); false when Box3D refused
// it (a hull under 4 points or past its 128 edges) and nothing was added.
create_level_shape :: proc(
	world: ^World,
	ref: Body_Ref,
	def: Shape_Def,
	shape: ^level.Shape,
	loc := #caller_location,
) -> bool {
	check_shape_def(def, loc)
	def := def
	return level_shape(body_id(world, ref), &def, shape)
}

@(private)
level_shape :: proc(body: box3d.BodyId, shape_def: ^Shape_Def, shape: ^level.Shape) -> bool {
	identity := shape.rot == {0, 0, 0, 1}
	id: box3d.ShapeId
	switch shape.kind {
	case .Box:
		hull := box3d.MakeBoxHull(shape.half.x, shape.half.y, shape.half.z)
		if identity && shape.pos == {} {
			id = box3d.CreateHullShape(body, (^box3d.ShapeDef)(shape_def), &hull.base)
		} else {
			transformed := box3d.CloneAndTransformHull(
				&hull.base,
				transmute(box3d.Transform)Transform{shape.pos, shape.rot},
				transmute(box3d.Vec3)[3]f32{1, 1, 1},
			)
			if transformed == nil do return false
			id = box3d.CreateHullShape(body, (^box3d.ShapeDef)(shape_def), transformed)
			box3d.DestroyHull(transformed)
		}
	case .Sphere:
		sphere := Sphere{shape.pos, shape.radius}
		id = box3d.CreateSphereShape(body, (^box3d.ShapeDef)(shape_def), (^box3d.Sphere)(&sphere))
	case .Capsule:
		axis := dmath.quat_rotate(shape.rot, {0, shape.half_height, 0})
		capsule := Capsule{shape.pos - axis, shape.pos + axis, shape.radius}
		id = box3d.CreateCapsuleShape(body, (^box3d.ShapeDef)(shape_def), (^box3d.Capsule)(&capsule))
	case .Hull:
		if len(shape.points) < 4 do return false
		hull := box3d.CreateHull(([^]box3d.Vec3)(raw_data(shape.points)), i32(len(shape.points)), 64)
		if hull == nil do return false
		id = box3d.CreateHullShape(body, (^box3d.ShapeDef)(shape_def), hull)
		box3d.DestroyHull(hull)
	}
	return id.index1 != 0
}
