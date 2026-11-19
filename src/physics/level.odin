// Static geometry from a level file (src/physics/README.md, Static level geometry; src/level/README.md): one static
// body per level body, in file order.
package physics

import "core:fmt"

import box3d "box3d:bindings"
import "unified:dmath"
import "unified:level"

// A game World's level and physics in one call (world_create): the level loaded from `content` (sim.Game.content),
// a physics world made with `settings`, then the level's static bodies (create_static) as its first bodies. `problem`:
// the content is no level (`phys` nil then), or create_static's; "" when all is built. destroy_with_level frees both.
//
//   world.phys, world.level, problem = physics.create_with_level({tick_hz = TICK_HZ}, content, CAT_STATIC)
//   assert(problem == "", problem)
create_with_level :: proc(
	settings: Settings,
	content: []u8,
	default_category: u64 = 1,
) -> (
	phys: ^World,
	level_data: level.Level,
	problem: string,
) {
	ok: bool
	level_data, ok = level.load(content)
	if !ok do return nil, {}, "the level file is missing or not a level (src/level/README.md)"
	phys = create(settings)
	problem = create_static(phys, &level_data, default_category)
	return
}

// Frees what create_with_level made: the physics world and the loaded level (not the content).
destroy_with_level :: proc(phys: ^World, level_data: ^level.Level) {
	if phys != nil do destroy(phys)
	level.destroy(level_data)
}

// Creates every static body of the level, in file order (the World's, when made before `extra`: call it first in
// world_create): one body per level body, plus one per height field (Box3D's take no local transform), right after
// its level body. Meshes and height fields are built here and kept by the World until destroy. Shapes without a
// category in the file get `default_category`. `problem` names the first level shape Box3D refused (a hull it can't
// build: under 4 points, or past its edge limit; a mesh of degenerate triangles), "" when every shape was built: a
// refused shape is skipped, a hole in the level's collision the game must not run with (the games assert on it).
create_static :: proc(world: ^World, level_data: ^level.Level, default_category: u64 = 1) -> (problem: string) {
	for &level_body, body_index in level_data.bodies {
		body_def := transmute(Body_Def)box3d.DefaultBodyDef()
		body_def.position = level_body.pos
		body_def.rotation = level_body.rot
		id := box3d.CreateBody(world.id, (^box3d.BodyDef)(&body_def))
		body_created(world, id, 0)
		shape_def := transmute(Shape_Def)box3d.DefaultShapeDef()
		shape_def.filter.category = level_body.category if level_body.category != 0 else default_category
		for &shape, shape_index in level_body.shapes {
			built: bool
			if shape.kind == .Height_Field {
				built = level_height_field(world, Transform{level_body.pos, level_body.rot}, shape_def, &shape)
			} else {
				built = level_shape(world, id, &shape_def, &shape)
			}
			if !built && problem == "" {
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

// Adds one level shape to a body (any type: games use it for their own level bodies too) with the level shape's
// surface (the def's materials are replaced); false when Box3D refused it (a hull under 4 points or past its 128
// edges, a mesh of degenerate triangles) and nothing was added. A mesh is built here and kept by the World until
// destroy. A height field needs a static body of its own at its pose: create_static makes one.
create_level_shape :: proc(
	world: ^World,
	ref: Body_Ref,
	def: Shape_Def,
	shape: ^level.Shape,
	loc := #caller_location,
) -> bool {
	check_shape_def(def, loc)
	assert(shape.kind != .Height_Field, "physics: a level height field needs its own static body (create_static)", loc)
	def := def
	return level_shape(world, body_id(world, ref), &def, shape)
}

// A level surface as Box3D's surface material.
@(private)
surface_material :: proc(surface: level.Surface) -> Surface_Material {
	return {
		friction           = surface.friction,
		restitution        = surface.restitution,
		rolling_resistance = surface.rolling_resistance,
		tangent_velocity   = surface.tangent_velocity,
		user_material_id   = surface.material,
	}
}

@(private)
level_shape :: proc(world: ^World, body: box3d.BodyId, shape_def: ^Shape_Def, shape: ^level.Shape) -> bool {
	shape_def.base_material = surface_material(shape.surface)
	shape_def.materials = nil
	shape_def.material_count = 0
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
	case .Mesh:
		mesh := level_mesh(shape)
		if mesh == nil do return false
		append(&world.level_meshes, mesh)
		materials := make([]Surface_Material, len(shape.materials), context.temp_allocator)
		for surface, i in shape.materials do materials[i] = surface_material(surface)
		shape_def.materials = raw_data(materials)
		shape_def.material_count = i32(len(materials))
		id = box3d.CreateMeshShape(body, (^box3d.ShapeDef)(shape_def), mesh, transmute(box3d.Vec3)[3]f32{1, 1, 1})
		shape_def.materials = nil
		shape_def.material_count = 0
	case .Height_Field:
		return false
	}
	return id.index1 != 0
}

// A level mesh's BVH, its vertices moved into the body's frame when the shape has a pose of its own (the exporter
// writes them body-local); nil when Box3D can't build it (no triangle that isn't degenerate).
@(private)
level_mesh :: proc(shape: ^level.Shape) -> ^Mesh_Data {
	vertices := shape.points
	if shape.rot != {0, 0, 0, 1} || shape.pos != {} {
		vertices = make([][3]f32, len(shape.points), context.temp_allocator)
		for point, i in shape.points do vertices[i] = shape.pos + dmath.quat_rotate(shape.rot, point)
	}
	def := Mesh_Def {
		vertices         = raw_data(vertices),
		indices          = ([^]i32)(raw_data(shape.triangles)),
		material_indices = raw_data(shape.triangle_materials) if len(shape.triangle_materials) > 0 else nil,
		vertex_count     = i32(len(vertices)),
		triangle_count   = i32(len(shape.triangles)),
		identify_edges   = true,
	}
	return create_mesh(def)
}

// A level height field on a static body of its own at the level body's pose times the shape's (the grid's corner),
// built here and kept by the World until destroy; false when Box3D refused it.
@(private)
level_height_field :: proc(world: ^World, body: Transform, shape_def: Shape_Def, shape: ^level.Shape) -> bool {
	lowest, highest := shape.heights[0], shape.heights[0]
	for height in shape.heights {
		lowest = dmath.min(lowest, height)
		highest = dmath.max(highest, height)
	}
	height_field := create_height_field({
		heights               = raw_data(shape.heights),
		scale                 = shape.scale,
		count_x               = i32(shape.count_x),
		count_z               = i32(shape.count_z),
		global_minimum_height = lowest,
		global_maximum_height = highest,
	})
	if height_field == nil do return false
	append(&world.level_height_fields, height_field)
	pose := transmute(Transform)box3d.MulTransforms(
		transmute(box3d.Transform)body,
		transmute(box3d.Transform)Transform{shape.pos, shape.rot},
	)
	body_def := transmute(Body_Def)box3d.DefaultBodyDef()
	body_def.position = pose.p
	body_def.rotation = pose.q
	id := box3d.CreateBody(world.id, (^box3d.BodyDef)(&body_def))
	body_created(world, id, 0)
	shape_def := shape_def
	shape_def.base_material = surface_material(shape.surface)
	return box3d.CreateHeightFieldShape(id, (^box3d.ShapeDef)(&shape_def), height_field).index1 != 0
}
