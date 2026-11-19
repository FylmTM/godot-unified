// A game's levels as physics (src/physics/README.md, Levels; src/level/README.md): every level parsed and its geometry
// built once, when the World is created; the active level's static bodies made by level_change, inside a tick.
package physics

import "base:intrinsics"
import "core:fmt"

import box3d "box3d:bindings"
import "unified:dmath"
import "unified:level"
import "unified:sim"

// One of the World's levels (create_with_levels): its parsed file, its geometry and the static bodies a change makes,
// immutable while the world lives.
@(private)
Baked_Level :: struct {
	name:          string,
	data:          level.Level,
	statics:       []Level_Static, // in the order level_change creates them
	compounds:     []^Compound_Data, // the statics' compounds
	// The geometry of each shape that stays a shape of its own, by its index in data.shapes (nil for a shape in a
	// compound, which holds a copy, and for the kinds that need none: spheres, capsules).
	hulls:         []^Hull_Data, // boxes and hulls, in their body's frame
	meshes:        []^Mesh_Data,
	height_fields: []^Height_Field_Data,
}

// One static body of a level, as level_change creates it: a compound of the shapes of one cell and category (at the
// cell's corner, unrotated), or one shape alone at its level body's pose (a cell's only shape of its category; a
// height field, which no compound holds, at its own pose).
@(private)
Level_Static :: struct {
	pos:      [3]f32,
	rot:      [4]f32,
	category: u64,
	compound: ^Compound_Data, // nil: `shape` alone
	shape:    int, // the shape alone, by its index in data.shapes
}

// The default edge of a level's compound cell (Settings.level_cell), in metres.
LEVEL_CELL_DEFAULT :: f32(64)

// The furthest cell from the origin on each axis, so a level shape's cell index stays an i32 (a shape past it shares
// the edge cell).
@(private)
LEVEL_CELL_LIMIT :: f32(1 << 20)

// A physics world for a game with levels (world_create): `settings`' world, then every level of `levels`
// (sim.Game.levels) parsed and its geometry built (hulls, meshes, height fields), and its shapes baked into compounds
// by cell and category (src/physics/README.md, Levels), so a level change creates bodies and builds nothing. No static
// body is made: the game's init enters a level (level_change). Shapes without a
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
	assert(settings.level_cell >= 0, "physics: Settings.level_cell is a cell's edge in metres (0: LEVEL_CELL_DEFAULT)")
	world = create(settings)
	world.level_category = default_category
	world.level_cell = settings.level_cell if settings.level_cell > 0 else LEVEL_CELL_DEFAULT
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
		if problem = bake_level(world, &world.levels[len(world.levels) - 1]); problem != "" {
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
// order) and creates `id`'s from what create_with_levels built (its compounds in cell and category order, then its
// height fields in file order), then sim.level_enter. Box3D's snapshot holds static bodies like any other, so a rollback across the
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

// Builds every shape's geometry of a level once, then bakes its static bodies (bake_statics); the first refused shape
// is the problem, by level, body and shape.
@(private)
bake_level :: proc(world: ^World, baked: ^Baked_Level) -> (problem: string) {
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
	if problem == "" do bake_statics(world, baked)
	return problem
}

// A level shape on its way into a static body (bake_statics): the cell and category that group it, and where it is.
@(private)
Level_Cell_Entry :: struct {
	center:   [3]f32, // of its bounds in the world
	cell:     [3]i32,
	category: u64,
	index:    int, // in data.shapes
	body:     int, // in data.bodies
}

// Groups a level's shapes by cell and filter category, sorted by cell x, y, z then category (file order inside a
// group), and makes each group of two shapes or more one compound at its cell's corner. The cells are cubes of edge
// world.level_cell from the lowest corner of the level's bounds, so a level smaller than a cell is one compound per
// category wherever it sits; a shape's cell is the one holding the centre of its bounds. A group of one stays a shape
// of its own; height fields, which no compound holds, come after, in file order. The order and the bytes depend on
// the level and the cell size alone, so every peer builds the same statics. The geometry copied into a compound is
// freed.
@(private)
bake_statics :: proc(world: ^World, baked: ^Baked_Level) {
	entries := make([dynamic]Level_Cell_Entry, 0, len(baked.data.shapes), context.temp_allocator)
	statics: [dynamic]Level_Static
	compounds: [dynamic]^Compound_Data
	corner: [3]f32 // the lowest corner of the shapes' bounds: the cells' origin
	index := 0
	for &level_body, body_index in baked.data.bodies {
		category := level_body.category if level_body.category != 0 else world.level_category
		pose := Transform{level_body.pos, level_body.rot}
		for &shape in level_body.shapes {
			if shape.kind != .Height_Field {
				bounds := level_shape_bounds(&shape, pose, baked.hulls[index], baked.meshes[index])
				if len(entries) == 0 do corner = bounds.lower_bound
				for axis in 0 ..< 3 do corner[axis] = dmath.min(corner[axis], bounds.lower_bound[axis])
				center := (bounds.lower_bound + bounds.upper_bound) * 0.5
				append(
					&entries,
					Level_Cell_Entry{center = center, category = category, index = index, body = body_index},
				)
			}
			index += 1
		}
	}
	for &entry in entries do entry.cell = level_cell_of(entry.center - corner, world.level_cell)
	sort_results(world, entries[:], proc(a, b: Level_Cell_Entry) -> bool {
		for axis in 0 ..< 3 do if a.cell[axis] != b.cell[axis] do return a.cell[axis] < b.cell[axis]
		return a.category < b.category
	})
	for start := 0; start < len(entries); {
		end := start + 1
		for end < len(entries) &&
		    entries[end].cell == entries[start].cell &&
		    entries[end].category == entries[start].category {
			end += 1
		}
		group := entries[start:end]
		start = end
		if len(group) == 1 {
			level_body := &baked.data.bodies[group[0].body]
			append(&statics, Level_Static {
				pos      = level_body.pos,
				rot      = level_body.rot,
				category = group[0].category,
				shape    = group[0].index,
			})
			continue
		}
		origin := corner + [3]f32{f32(group[0].cell.x), f32(group[0].cell.y), f32(group[0].cell.z)} * world.level_cell
		compound := level_compound(baked, group, origin)
		append(&compounds, compound)
		append(
			&statics,
			Level_Static{pos = origin, rot = {0, 0, 0, 1}, category = group[0].category, compound = compound},
		)
	}
	index = 0
	for &level_body in baked.data.bodies {
		category := level_body.category if level_body.category != 0 else world.level_category
		for &shape in level_body.shapes {
			if shape.kind == .Height_Field {
				pose := transmute(Transform)box3d.MulTransforms(
					transmute(box3d.Transform)Transform{level_body.pos, level_body.rot},
					transmute(box3d.Transform)Transform{shape.pos, shape.rot},
				)
				append(&statics, Level_Static{pos = pose.p, rot = pose.q, category = category, shape = index})
			}
			index += 1
		}
	}
	baked.statics = statics[:]
	baked.compounds = compounds[:]
}

// A level shape's bounds in the world, its level body at `pose`.
@(private)
level_shape_bounds :: proc(shape: ^level.Shape, pose: Transform, hull: ^Hull_Data, mesh: ^Mesh_Data) -> AABB {
	#partial switch shape.kind {
	case .Box, .Hull:
		return compute_hull_aabb(hull, pose)
	case .Mesh:
		return compute_mesh_aabb(mesh, pose)
	case .Sphere:
		return compute_sphere_aabb({shape.pos, shape.radius}, pose)
	case .Capsule:
		return compute_capsule_aabb(level_capsule(shape), pose)
	}
	return {}
}

// The cell holding `point` (from the cells' origin), in cells of edge `cell` (clamped to LEVEL_CELL_LIMIT on each axis).
@(private)
level_cell_of :: proc(point: [3]f32, cell: f32) -> (index: [3]i32) {
	for axis in 0 ..< 3 {
		index[axis] = i32(dmath.clamp(dmath.floor(point[axis] / cell), -LEVEL_CELL_LIMIT, LEVEL_CELL_LIMIT))
	}
	return
}

// One compound of a group of level shapes (two or more, no height field), in the frame of a static body at `origin`,
// unrotated: each child at its level body's pose with its surface. A box's, hull's or mesh's geometry is copied in, so
// the level's own copy is freed.
@(private)
level_compound :: proc(baked: ^Baked_Level, group: []Level_Cell_Entry, origin: [3]f32) -> ^Compound_Data {
	hulls := make([dynamic]Compound_Hull_Def, 0, len(group), context.temp_allocator)
	meshes := make([dynamic]Compound_Mesh_Def, 0, len(group), context.temp_allocator)
	spheres := make([dynamic]Compound_Sphere_Def, 0, len(group), context.temp_allocator)
	capsules := make([dynamic]Compound_Capsule_Def, 0, len(group), context.temp_allocator)
	for entry in group {
		level_body := &baked.data.bodies[entry.body]
		shape := &baked.data.shapes[entry.index]
		pose := Transform{level_body.pos - origin, level_body.rot} // the level body in the compound's frame
		material := surface_material(shape.surface)
		#partial switch shape.kind {
		case .Box, .Hull:
			append(&hulls, Compound_Hull_Def{hull = baked.hulls[entry.index], transform = pose, material = material})
		case .Mesh:
			mesh := baked.meshes[entry.index]
			// One surface per material index the mesh's triangles use (Box3D's count; the file may name more).
			materials := make([]Surface_Material, mesh.materialCount, context.temp_allocator)
			for &surface, i in materials do surface = surface_material(shape.materials[i])
			append(&meshes, Compound_Mesh_Def {
				mesh_data      = mesh,
				transform      = pose,
				scale          = {1, 1, 1},
				materials      = raw_data(materials),
				material_count = i32(len(materials)),
			})
		case .Sphere:
			sphere := Sphere{level_point(pose, shape.pos), shape.radius}
			append(&spheres, Compound_Sphere_Def{sphere = sphere, material = material})
		case .Capsule:
			capsule := level_capsule(shape)
			capsule.center1 = level_point(pose, capsule.center1)
			capsule.center2 = level_point(pose, capsule.center2)
			append(&capsules, Compound_Capsule_Def{capsule = capsule, material = material})
		}
	}
	compound := create_compound({
		capsules      = raw_data(capsules),
		capsule_count = i32(len(capsules)),
		hulls         = raw_data(hulls),
		hull_count    = i32(len(hulls)),
		meshes        = raw_data(meshes),
		mesh_count    = i32(len(meshes)),
		spheres       = raw_data(spheres),
		sphere_count  = i32(len(spheres)),
	})
	for entry in group {
		if hull := baked.hulls[entry.index]; hull != nil do destroy_hull(hull)
		if mesh := baked.meshes[entry.index]; mesh != nil do destroy_mesh(mesh)
		baked.hulls[entry.index] = nil
		baked.meshes[entry.index] = nil
	}
	return compound
}

// A body-local point moved by the body's pose.
@(private)
level_point :: proc(pose: Transform, point: [3]f32) -> [3]f32 {
	return pose.p + dmath.quat_rotate(pose.q, point)
}

// A level capsule in its body's frame.
@(private)
level_capsule :: proc(shape: ^level.Shape) -> Capsule {
	axis := dmath.quat_rotate(shape.rot, {0, shape.half_height, 0})
	return {shape.pos - axis, shape.pos + axis, shape.radius}
}

// Frees a level's geometry and parsed file (after the Box3D world: its shapes point at the compounds, meshes and
// height fields).
@(private)
unbake_level :: proc(baked: ^Baked_Level) {
	for compound in baked.compounds do destroy_compound(compound)
	for hull in baked.hulls do if hull != nil do destroy_hull(hull)
	for mesh in baked.meshes do if mesh != nil do destroy_mesh(mesh)
	for height_field in baked.height_fields do if height_field != nil do destroy_height_field(height_field)
	delete(baked.statics)
	delete(baked.compounds)
	delete(baked.hulls)
	delete(baked.meshes)
	delete(baked.height_fields)
	level.destroy(&baked.data)
}

// Creates a level's static bodies (bake_statics), flagged as the level's in the body table.
@(private)
build_level :: proc(world: ^World, baked: ^Baked_Level) {
	for &level_static in baked.statics {
		body := level_body_create(world, level_static.pos, level_static.rot)
		shape_def := transmute(Shape_Def)box3d.DefaultShapeDef()
		shape_def.filter.category = level_static.category
		if level_static.compound != nil {
			id := box3d.CreateBakedCompoundShape(body, (^box3d.ShapeDef)(&shape_def), level_static.compound)
			assert(id.index1 != 0, "physics: Box3D refused a level compound it built")
			continue
		}
		shape := &baked.data.shapes[level_static.shape]
		if shape.kind == .Height_Field {
			shape_def.base_material = surface_material(shape.surface)
			field := baked.height_fields[level_static.shape]
			id := box3d.CreateHeightFieldShape(body, (^box3d.ShapeDef)(&shape_def), field)
			assert(id.index1 != 0, "physics: Box3D refused a level height field it built")
			continue
		}
		hull, mesh := baked.hulls[level_static.shape], baked.meshes[level_static.shape]
		built := level_shape(body, &shape_def, shape, hull, mesh)
		assert(built, "physics: Box3D refused a level shape it built")
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
		capsule := level_capsule(shape)
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
