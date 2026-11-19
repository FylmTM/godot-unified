// A game's levels as physics (src/physics/README.md, Levels; src/level/README.md): every level parsed and its geometry
// built once, when the World is created; the active level's static bodies made by level_change, inside a tick.
package physics

import "base:intrinsics"
import "core:fmt"

import box3d "box3d:bindings"
import "unified:dmath"
import "unified:level"
import "unified:sim"

// One of the World's levels (create_with_levels): its parsed file and its geometry, immutable while the world lives.
@(private)
Baked_Level :: struct {
	name:          string,
	data:          level.Level,
	// The geometry of each shape, by its index in data.shapes (nil for the kinds that need none: spheres, capsules).
	hulls:         []^Hull_Data, // boxes and hulls, in their body's frame
	meshes:        []^Mesh_Data,
	height_fields: []^Height_Field_Data,
}

// A physics world for a game with levels (world_create): `settings`' world, then every level of `levels`
// (sim.Game.levels) parsed and its geometry built (hulls, meshes, height fields), so a level change creates bodies
// and builds nothing. No static body is made: the game's init enters a level (level_change). Shapes without a
// category in the file get `default_category`. `problem` names a file that is no level, or the first shape Box3D
// refuses in any level (a hull under 4 points or past its 128 edges, a mesh of degenerate triangles), with its level,
// body and shape: a bad level shows at startup, never at a change mid-session. `world` is nil with a problem. destroy
// frees the levels with the world.
//
//   world.phys, problem = physics.create_with_levels({tick_hz = TICK_HZ}, levels, CAT_STATIC)
//   assert(problem == "", problem)
create_with_levels :: proc(
	settings: Settings,
	levels: []sim.Level_File,
	default_category: u64 = 1,
) -> (
	world: ^World,
	problem: string,
) {
	world = create(settings)
	world.level_category = default_category
	for file in levels {
		baked := Baked_Level {
			name = file.name,
		}
		ok: bool
		baked.data, ok = level.load(file.bytes)
		if !ok {
			destroy(world)
			return nil, fmt.tprintf("level %q: not a level file of this version (src/level/README.md)", file.name)
		}
		append(&world.levels, baked)
		if problem = bake_level(&world.levels[len(world.levels) - 1]); problem != "" {
			destroy(world)
			return nil, problem
		}
	}
	return world, ""
}

// A level the World holds, parsed: its markers and bodies (`physics.level_data(world, Level_Id.Hub)`). Immutable, and
// as long-lived as the world.
level_data :: proc(
	world: ^World,
	id: $Id,
) -> ^level.Level where intrinsics.type_is_enum(Id) ||
	intrinsics.type_is_integer(Id) {
	return &world.levels[int(id)].data
}

// Makes `id` the active level, inside init or tick: destroys the static bodies of the level now built (in body index
// order) and creates `id`'s from what create_with_levels built (in file order, each height field's body after its
// level body's), then sim.level_enter. Box3D's snapshot holds static bodies like any other, so a rollback across the
// change, a late join after it and a replay of it are exact. Entering the active level rebuilds it.
//
// Destroy what hangs on the old level first: a joint to a level body goes with it (a character standing on the level
// or riding a platform: its pogo joint hangs on the ground it stands on, so destroy the character, as a leave does),
// and a Body_Link to one goes stale. check_refs names a joint ref left behind.
level_change :: proc(t: ^sim.Tick($G), world: ^World, id: $Id) where intrinsics.type_is_enum(Id) {
	assert(world.sealed, "physics: level_change runs in init or tick (after extra)")
	assert(int(id) >= 0 && int(id) < len(world.levels), "physics: no such level (create_with_levels' levels)")
	for &entry, index in world.bodies {
		if .Level not_in entry.flags || .Alive not_in entry.flags do continue
		id := body_id(world, Body_Ref{index1 = i32(index + 1), generation = entry.generation})
		if box3d.Body_IsValid(id) do box3d.DestroyBody(id) // a loaded table is checked (load); a guard, as destroy_body's
		entry = {}
	}
	build_level(world, &world.levels[int(id)])
	world.level_entered = true
	sim.level_enter(t, id)
}

// A level shape with its geometry built (build_level_shape), for create_level_shape: the World's, as long-lived as it.
Built_Level_Shape :: struct {
	shape: ^level.Shape, // must outlive the World (the game's level data, or level_data's)
	hull:  ^Hull_Data, // a box's or a hull's (nil otherwise)
	mesh:  ^Mesh_Data, // a mesh's (nil otherwise)
}

// Builds a level shape's geometry (a hull, a mesh's BVH) for create_level_shape, in world_create (asserted: building
// costs too much for a tick, and a tick that re-runs would build again); ok is false when Box3D refused it (a hull
// under 4 points or past its 128 edges, a mesh of degenerate triangles). Spheres and capsules need nothing built. A
// height field needs a static body of its own: levels (level_change) make one. Freed with the World.
//
//   ramp, ok := physics.build_level_shape(world.phys, &ramp_shape) // world_create
//   physics.create_level_shape(t.world.phys, body, def, world.ramp) // init or tick, as often as rollbacks re-run it
build_level_shape :: proc(
	world: ^World,
	shape: ^level.Shape,
	loc := #caller_location,
) -> (
	built: Built_Level_Shape,
	ok: bool,
) {
	assert(!world.sealed, "physics: build_level_shape runs in world_create, before extra", loc)
	assert(shape.kind != .Height_Field, "physics: a level height field needs its own static body", loc)
	built.shape = shape
	#partial switch shape.kind {
	case .Box, .Hull:
		built.hull = level_hull(shape)
		if built.hull == nil do return {}, false
		append(&world.level_hulls, built.hull)
	case .Mesh:
		built.mesh = level_mesh(shape)
		if built.mesh == nil do return {}, false
		append(&world.level_meshes, built.mesh)
	}
	return built, true
}

// Adds a built level shape to a body (any type: games use it for their own level bodies too) with the level shape's
// surface (the def's materials are replaced). Builds nothing, so init and tick may call it, and a rollback re-runs it
// at the cost of the shape's creation alone.
create_level_shape :: proc(
	world: ^World,
	ref: Body_Ref,
	def: Shape_Def,
	built: Built_Level_Shape,
	loc := #caller_location,
) {
	check_shape_def(def, loc)
	assert(built.shape != nil, "physics: a level shape from build_level_shape", loc)
	def := def
	created := level_shape(body_id(world, ref), &def, built.shape, built.hull, built.mesh)
	assert(created, "physics: Box3D refused a level shape it built", loc)
}

// Builds every shape's geometry of a level once; the first refused shape is the problem, by level, body and shape.
@(private)
bake_level :: proc(baked: ^Baked_Level) -> (problem: string) {
	count := len(baked.data.shapes)
	baked.hulls = make([]^Hull_Data, count)
	baked.meshes = make([]^Mesh_Data, count)
	baked.height_fields = make([]^Height_Field_Data, count)
	index := 0
	for &level_body, body_index in baked.data.bodies {
		for &shape, shape_index in level_body.shapes {
			built := true
			switch shape.kind {
			case .Box, .Hull:
				baked.hulls[index] = level_hull(&shape)
				built = baked.hulls[index] != nil
			case .Mesh:
				baked.meshes[index] = level_mesh(&shape)
				built = baked.meshes[index] != nil
			case .Height_Field:
				baked.height_fields[index] = level_height_field(&shape)
				built = baked.height_fields[index] != nil
			case .Sphere, .Capsule:
			}
			if !built && problem == "" {
				problem = fmt.tprintf(
					"level %q, body %d %q, shape %d (%v%s): Box3D refused it",
					baked.name,
					body_index,
					level_body.name,
					shape_index,
					shape.kind,
					fmt.tprintf(" of %d points", len(shape.points)) if shape.kind == .Hull else "",
				)
			}
			index += 1
		}
	}
	return problem
}

// Frees a level's geometry and parsed file (after the Box3D world: its shapes point at the meshes and height fields).
@(private)
unbake_level :: proc(baked: ^Baked_Level) {
	for hull in baked.hulls do if hull != nil do destroy_hull(hull)
	for mesh in baked.meshes do if mesh != nil do destroy_mesh(mesh)
	for height_field in baked.height_fields do if height_field != nil do destroy_height_field(height_field)
	delete(baked.hulls)
	delete(baked.meshes)
	delete(baked.height_fields)
	level.destroy(&baked.data)
}

// Creates a level's static bodies from its baked geometry, flagged as the level's in the body table.
@(private)
build_level :: proc(world: ^World, baked: ^Baked_Level) {
	index := 0
	for &level_body in baked.data.bodies {
		body := level_body_create(world, level_body.pos, level_body.rot)
		shape_def := transmute(Shape_Def)box3d.DefaultShapeDef()
		shape_def.filter.category = level_body.category if level_body.category != 0 else world.level_category
		for &shape in level_body.shapes {
			if shape.kind == .Height_Field {
				pose := transmute(Transform)box3d.MulTransforms(
					transmute(box3d.Transform)Transform{level_body.pos, level_body.rot},
					transmute(box3d.Transform)Transform{shape.pos, shape.rot},
				)
				field_body := level_body_create(world, pose.p, pose.q)
				field_def := shape_def
				field_def.base_material = surface_material(shape.surface)
				id := box3d.CreateHeightFieldShape(
					field_body,
					(^box3d.ShapeDef)(&field_def),
					baked.height_fields[index],
				)
				assert(id.index1 != 0, "physics: Box3D refused a level height field it built")
			} else {
				built := level_shape(body, &shape_def, &shape, baked.hulls[index], baked.meshes[index])
				assert(built, "physics: Box3D refused a level shape it built")
			}
			index += 1
		}
	}
}

// A static body of the active level, recorded in the body table as the level's (with its generation, so
// level_change can destroy it).
@(private)
level_body_create :: proc(world: ^World, pos: [3]f32, rot: [4]f32) -> box3d.BodyId {
	body_def := transmute(Body_Def)box3d.DefaultBodyDef()
	body_def.position = pos
	body_def.rotation = rot
	id := box3d.CreateBody(world.id, (^box3d.BodyDef)(&body_def))
	body_created(world, id, 0)
	entry := &world.bodies[id.index1 - 1]
	entry.flags = {.Alive, .Level}
	entry.generation = id.generation
	return id
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

// One shape on a body from its built geometry (`hull` for a box or hull, `mesh` for a mesh); false when Box3D refused
// it.
@(private)
level_shape :: proc(
	body: box3d.BodyId,
	shape_def: ^Shape_Def,
	shape: ^level.Shape,
	hull: ^Hull_Data,
	mesh: ^Mesh_Data,
) -> bool {
	shape_def.base_material = surface_material(shape.surface)
	shape_def.materials = nil
	shape_def.material_count = 0
	id: box3d.ShapeId
	switch shape.kind {
	case .Box, .Hull:
		id = box3d.CreateHullShape(body, (^box3d.ShapeDef)(shape_def), hull)
	case .Sphere:
		sphere := Sphere{shape.pos, shape.radius}
		id = box3d.CreateSphereShape(body, (^box3d.ShapeDef)(shape_def), (^box3d.Sphere)(&sphere))
	case .Capsule:
		axis := dmath.quat_rotate(shape.rot, {0, shape.half_height, 0})
		capsule := Capsule{shape.pos - axis, shape.pos + axis, shape.radius}
		id = box3d.CreateCapsuleShape(body, (^box3d.ShapeDef)(shape_def), (^box3d.Capsule)(&capsule))
	case .Mesh:
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

// A box's or hull's geometry in its body's frame (a box moved by its pose); nil when Box3D can't build it. Free with
// destroy_hull.
@(private)
level_hull :: proc(shape: ^level.Shape) -> ^Hull_Data {
	if shape.kind == .Box {
		box := box3d.MakeBoxHull(shape.half.x, shape.half.y, shape.half.z)
		if shape.rot == {0, 0, 0, 1} && shape.pos == {} do return box3d.CloneHull(&box.base)
		return box3d.CloneAndTransformHull(
			&box.base,
			transmute(box3d.Transform)Transform{shape.pos, shape.rot},
			transmute(box3d.Vec3)[3]f32{1, 1, 1},
		)
	}
	if len(shape.points) < 4 do return nil
	return box3d.CreateHull(([^]box3d.Vec3)(raw_data(shape.points)), i32(len(shape.points)), 64)
}

// A level mesh's BVH, its vertices moved into the body's frame when the shape has a pose of its own (the exporter
// writes them body-local); nil when Box3D can't build it (no triangle that isn't degenerate). Free with destroy_mesh.
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

// A level height field, quantized between its own lowest and highest heights; nil when Box3D can't build it. Free
// with destroy_height_field.
@(private)
level_height_field :: proc(shape: ^level.Shape) -> ^Height_Field_Data {
	lowest, highest := shape.heights[0], shape.heights[0]
	for height in shape.heights {
		lowest = dmath.min(lowest, height)
		highest = dmath.max(highest, height)
	}
	return create_height_field({
		heights               = raw_data(shape.heights),
		scale                 = shape.scale,
		count_x               = i32(shape.count_x),
		count_z               = i32(shape.count_z),
		global_minimum_height = lowest,
		global_maximum_height = highest,
	})
}
