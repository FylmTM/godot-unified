// Box3D itself, below physics' wrappers (src/physics/README.md, The boundary): every mirror has its binding's layout
// scalar for scalar (so a conversion is a transmute or a pointer cast), the enums' members are the library's, the golden
// trace that pins the library's results on every platform, a sync-test of the library alone, and image loads that are
// safe on any bytes. A Box3D upgrade is proven here before the physics tests run (the upgrade-dependency skill).
package test_physics

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:strings"
import "core:testing"

import box3d "box3d:bindings"
import "unified:physics"
import "unified:sim"

// ---- layouts

// Every mirror and the binding it stands for.
MIRRORS := [][2]typeid {
	{[3]f32, box3d.Vec3},
	{[4]f32, box3d.Quat},
	{physics.Transform, box3d.Transform},
	{physics.AABB, box3d.AABB},
	{physics.Matrix3, box3d.Matrix3},
	{physics.Mass_Data, box3d.MassData},
	{physics.Plane, box3d.Plane},
	{physics.Sphere, box3d.Sphere},
	{physics.Capsule, box3d.Capsule},
	{physics.Shape_Proxy, box3d.ShapeProxy},
	{physics.Mesh_Def, box3d.MeshDef},
	{physics.Mesh, box3d.Mesh},
	{physics.Height_Field_Def, box3d.HeightFieldDef},
	{physics.Compound_Def, box3d.CompoundDef},
	{physics.Compound_Capsule_Def, box3d.CompoundCapsuleDef},
	{physics.Compound_Hull_Def, box3d.CompoundHullDef},
	{physics.Compound_Mesh_Def, box3d.CompoundMeshDef},
	{physics.Compound_Sphere_Def, box3d.CompoundSphereDef},
	{physics.Body_Type, box3d.BodyType},
	{physics.Motion_Locks, box3d.MotionLocks},
	{physics.Body_Def, box3d.BodyDef},
	{physics.Shape_Type, box3d.ShapeType},
	{physics.Surface_Material, box3d.SurfaceMaterial},
	{physics.Filter, box3d.Filter},
	{physics.Shape_Def, box3d.ShapeDef},
	{physics.Explosion_Def, box3d.ExplosionDef},
	{physics.Manifold, box3d.Manifold},
	{physics.Manifold_Point, box3d.ManifoldPoint},
	{physics.Joint_Type, box3d.JointType},
	{physics.Joint_Def, box3d.JointDef},
	{physics.Distance_Joint_Def, box3d.DistanceJointDef},
	{physics.Filter_Joint_Def, box3d.FilterJointDef},
	{physics.Motor_Joint_Def, box3d.MotorJointDef},
	{physics.Mover_Joint_Def, box3d.MoverJointDef},
	{physics.Parallel_Joint_Def, box3d.ParallelJointDef},
	{physics.Pogo_Joint_Def, box3d.PogoJointDef},
	{physics.Prismatic_Joint_Def, box3d.PrismaticJointDef},
	{physics.Revolute_Joint_Def, box3d.RevoluteJointDef},
	{physics.Spherical_Joint_Def, box3d.SphericalJointDef},
	{physics.Weld_Joint_Def, box3d.WeldJointDef},
	{physics.Wheel_Joint_Def, box3d.WheelJointDef},
}

// One scalar of a flattened layout: its offset and its kind ("f4", "i4", "u8", "b1", "p8", ...).
Scalar :: struct {
	offset: int,
	kind:   string,
}

flatten :: proc(type_info: ^runtime.Type_Info, base: int, out: ^[dynamic]Scalar) {
	#partial switch variant in type_info.variant {
	case runtime.Type_Info_Named:
		flatten(variant.base, base, out)
	case runtime.Type_Info_Struct:
		for i in 0 ..< int(variant.field_count) {
			flatten(variant.types[i], base + int(variant.offsets[i]), out)
		}
	case runtime.Type_Info_Array:
		for k in 0 ..< variant.count {
			flatten(variant.elem, base + k * variant.elem_size, out)
		}
	case runtime.Type_Info_Enum:
		flatten(variant.base, base, out)
	case runtime.Type_Info_Float:
		append(out, Scalar{base, fmt.tprintf("f%d", type_info.size)})
	case runtime.Type_Info_Integer:
		append(out, Scalar{base, fmt.tprintf("%s%d", variant.signed ? "i" : "u", type_info.size)})
	case runtime.Type_Info_Boolean:
		append(out, Scalar{base, fmt.tprintf("b%d", type_info.size)})
	case runtime.Type_Info_Pointer, runtime.Type_Info_Multi_Pointer, runtime.Type_Info_Procedure:
		append(out, Scalar{base, fmt.tprintf("p%d", type_info.size)})
	case runtime.Type_Info_String:
		// cstring
		append(out, Scalar{base, fmt.tprintf("p%d", type_info.size)})
	case:
		append(out, Scalar{base, fmt.tprintf("? %v", type_info.id)})
	}
}

// Each mirror has its binding's size and alignment and the same scalars at the same offsets, nested structs and arrays
// included: a conversion reinterprets the bytes and changes nothing.
@(test)
mirrors_match_the_bindings :: proc(t: ^testing.T) {
	for pair in MIRRORS {
		ours, theirs := type_info_of(pair[0]), type_info_of(pair[1])
		our_scalars := make([dynamic]Scalar, context.temp_allocator)
		their_scalars := make([dynamic]Scalar, context.temp_allocator)
		flatten(ours, 0, &our_scalars)
		flatten(theirs, 0, &their_scalars)
		testing.expectf(t, ours.size == theirs.size, "%v: size %d, %v: %d", pair[0], ours.size, pair[1], theirs.size)
		testing.expectf(
			t,
			ours.align == theirs.align,
			"%v: align %d, %v: %d",
			pair[0],
			ours.align,
			pair[1],
			theirs.align,
		)
		if !testing.expectf(t, len(our_scalars) == len(their_scalars), "%v: %d scalars, %v: %d", pair[0], len(our_scalars), pair[1], len(their_scalars)) do continue
		for scalar, i in our_scalars {
			testing.expectf(
				t,
				scalar == their_scalars[i],
				"%v scalar %d: %v, %v: %v",
				pair[0],
				i,
				scalar,
				pair[1],
				their_scalars[i],
			)
		}
	}
}

// An enum mirror's members are the library's, by value and by name without the type's word (`dynamicBody` →
// `Dynamic`, `heightShape` → `Height`), in order; `drop_last` library members (a count) have no mirror.
expect_enum_members :: proc(t: ^testing.T, $Ours, $Theirs: typeid, drop_last := 0) {
	ours := runtime.type_info_base(type_info_of(Ours)).variant.(runtime.Type_Info_Enum)
	theirs := runtime.type_info_base(type_info_of(Theirs)).variant.(runtime.Type_Info_Enum)
	if !testing.expect_value(t, len(ours.names), len(theirs.names) - drop_last) do return
	for name, i in theirs.names[:len(ours.names)] {
		ada := strings.builder_make(context.temp_allocator)
		for char, k in transmute([]u8)name {
			if k == 0 {
				strings.write_byte(&ada, char - 'a' + 'A')
			} else if char >= 'A' && char <= 'Z' {
				strings.write_byte(&ada, '_')
				strings.write_byte(&ada, char)
			} else {
				strings.write_byte(&ada, char)
			}
		}
		ada_name := strings.to_string(ada)
		testing.expect_value(t, ours.names[i], ada_name[:strings.last_index_byte(ada_name, '_')])
		testing.expect_value(t, ours.values[i], theirs.values[i])
	}
}

@(test)
enum_members_match_the_bindings :: proc(t: ^testing.T) {
	expect_enum_members(t, physics.Body_Type, box3d.BodyType, drop_last = 1)
	expect_enum_members(t, physics.Shape_Type, box3d.ShapeType, drop_last = 1)
	expect_enum_members(t, physics.Joint_Type, box3d.JointType)
}

// A default def made through physics equals the library's own, scalar by scalar (padding bytes are unspecified).
@(test)
default_defs_are_the_librarys :: proc(t: ^testing.T) {
	expect_same :: proc(t: ^testing.T, ours: $Ours, theirs: $Theirs) {
		ours, theirs := ours, theirs
		scalars := make([dynamic]Scalar, context.temp_allocator)
		flatten(type_info_of(Ours), 0, &scalars)
		our_bytes, their_bytes := ([^]u8)(&ours), ([^]u8)(&theirs)
		for scalar in scalars {
			size := int(scalar.kind[1] - '0')
			testing.expectf(
				t,
				mem.compare(our_bytes[scalar.offset:][:size], their_bytes[scalar.offset:][:size]) == 0,
				"%v: the scalar at %d differs",
				typeid_of(Ours),
				scalar.offset,
			)
		}
	}
	expect_same(t, physics.default_body_def(), box3d.DefaultBodyDef())
	expect_same(t, physics.default_shape_def(), box3d.DefaultShapeDef())
	expect_same(t, physics.default_explosion_def(), box3d.DefaultExplosionDef())
	expect_same(t, physics.default_distance_joint_def(), box3d.DefaultDistanceJointDef())
	expect_same(t, physics.default_filter_joint_def(), box3d.DefaultFilterJointDef())
	expect_same(t, physics.default_motor_joint_def(), box3d.DefaultMotorJointDef())
	expect_same(t, physics.default_mover_joint_def(), box3d.DefaultMoverJointDef())
	expect_same(t, physics.default_parallel_joint_def(), box3d.DefaultParallelJointDef())
	expect_same(t, physics.default_pogo_joint_def(), box3d.DefaultPogoJointDef())
	expect_same(t, physics.default_prismatic_joint_def(), box3d.DefaultPrismaticJointDef())
	expect_same(t, physics.default_revolute_joint_def(), box3d.DefaultRevoluteJointDef())
	expect_same(t, physics.default_spherical_joint_def(), box3d.DefaultSphericalJointDef())
	expect_same(t, physics.default_weld_joint_def(), box3d.DefaultWeldJointDef())
	expect_same(t, physics.default_wheel_joint_def(), box3d.DefaultWheelJointDef())
}

// ---- the library alone: a fixed scene stepped through the bindings (the world comes from physics.create, which
// serialises Box3D's world creation against the other test packages)

BOX3D_DT :: f32(1.0 / 64)
BOX3D_SUBSTEPS :: 4

box3d_box :: proc(world: box3d.WorldId, type: box3d.BodyType, pos, half: [3]f32) -> box3d.BodyId {
	body_def := box3d.DefaultBodyDef()
	body_def.type = type
	body_def.position = transmute(box3d.Vec3)pos
	body := box3d.CreateBody(world, &body_def)
	shape_def := box3d.DefaultShapeDef()
	shape_def.density = 1
	hull := box3d.MakeBoxHull(half.x, half.y, half.z)
	box3d.CreateHullShape(body, &shape_def, &hull.base)
	return body
}

box3d_steps :: proc(world: box3d.WorldId, count: int) {
	for _ in 0 ..< count do box3d.World_Step(world, BOX3D_DT, BOX3D_SUBSTEPS)
}

// Position, rotation, velocities of each body as raw bits (−0 and +0 differ: exactness is the point).
box3d_bodies_hash :: proc(bodies: []box3d.BodyId) -> u64 {
	buf := make([dynamic]u8, context.temp_allocator)
	for id in bodies {
		state: struct {
			position: box3d.Vec3,
			rotation: box3d.Quat, // x, y, z, w
			velocity: box3d.Vec3,
			angular:  box3d.Vec3,
		} = {
			box3d.Body_GetPosition(id),
			box3d.Body_GetRotation(id),
			box3d.Body_GetLinearVelocity(id),
			box3d.Body_GetAngularVelocity(id),
		}
		#assert(size_of(state) == 13 * size_of(f32))
		append(&buf, ..([^]u8)(&state)[:size_of(state)])
	}
	return sim.hash_bytes(buf[:])
}

// Every body type, contacts that settle and sleep (a stack), a spinning capsule and a sphere.
Box3d_Scene :: struct {
	phys:   ^physics.World,
	world:  box3d.WorldId,
	bodies: [dynamic]box3d.BodyId,
}

box3d_scene_make :: proc(scene: ^Box3d_Scene) {
	scene.phys = physics.create({tick_hz = HZ})
	scene.world = scene.phys.id
	append(&scene.bodies, box3d_box(scene.world, .staticBody, {0, -0.5, 0}, {20, 0.5, 20}))
	kinematic := box3d_box(scene.world, .kinematicBody, {-6, 1, 0}, {1, 0.25, 1})
	box3d.Body_SetLinearVelocity(kinematic, {1, 0, 0})
	append(&scene.bodies, kinematic)
	for i in 0 ..< 6 {
		append(&scene.bodies, box3d_box(scene.world, .dynamicBody, {3, 0.5 + f32(i) * 1.01, 0}, {0.5, 0.5, 0.5}))
	}
	body_def := box3d.DefaultBodyDef()
	body_def.type = .dynamicBody
	body_def.position = {0, 3, 4}
	body_def.angularVelocity = {0, 5, 2}
	capsule_body := box3d.CreateBody(scene.world, &body_def)
	shape_def := box3d.DefaultShapeDef()
	shape_def.density = 1
	capsule := box3d.Capsule{{0, -0.4, 0}, {0, 0.4, 0}, 0.3}
	box3d.CreateCapsuleShape(capsule_body, &shape_def, &capsule)
	append(&scene.bodies, capsule_body)
	body_def.position = {-3, 5, -3}
	body_def.angularVelocity = {}
	ball := box3d.CreateBody(scene.world, &body_def)
	sphere := box3d.Sphere{{0, 0, 0}, 0.5}
	box3d.CreateSphereShape(ball, &shape_def, &sphere)
	append(&scene.bodies, ball)
}

box3d_scene_destroy :: proc(scene: ^Box3d_Scene) {
	physics.destroy(scene.phys)
	delete(scene.bodies)
}

// The library's cross-platform pin: the scene hashed every 60 ticks. The values must match on every platform; a
// Box3D upgrade that changes them fails here first, then the games' reference runs. An intended change updates them in
// the same commit (the library-sim-change skill).
BOX3D_GOLDEN :: [4]u64{0x3125e350623f9163, 0x3f3637eb749e2a37, 0xf0d63788ca5d305b, 0xa2fd5716d15ff9f4}

@(test)
box3d_golden_trace :: proc(t: ^testing.T) {
	scene: Box3d_Scene
	box3d_scene_make(&scene)
	defer box3d_scene_destroy(&scene)
	got: [4]u64
	for &hash in got {
		box3d_steps(scene.world, 60)
		hash = box3d_bodies_hash(scene.bodies[:])
	}
	testing.expectf(t, got == BOX3D_GOLDEN, "golden trace changed: %x (pinned %x)", got, BOX3D_GOLDEN)
}

// The awake bodies' hash (physics' hash between deep ticks) sees which bodies are awake and every awake body's
// velocity, and agrees between two worlds stepped alike.
@(test)
box3d_awake_bodies_hash :: proc(t: ^testing.T) {
	scene_a, scene_b: Box3d_Scene
	box3d_scene_make(&scene_a)
	defer box3d_scene_destroy(&scene_a)
	box3d_scene_make(&scene_b)
	defer box3d_scene_destroy(&scene_b)
	hash :: box3d.World_HashAwakeBodies
	testing.expect_value(t, hash(scene_a.world), hash(scene_b.world))
	before := hash(scene_a.world)
	box3d_steps(scene_a.world, 1)
	box3d_steps(scene_b.world, 1)
	testing.expect(t, hash(scene_a.world) != before)
	testing.expect_value(t, hash(scene_a.world), hash(scene_b.world))
	last := scene_b.bodies[len(scene_b.bodies) - 1]
	box3d.Body_SetAwake(last, false)
	testing.expect(t, hash(scene_a.world) != hash(scene_b.world))
	box3d.Body_SetLinearVelocity(scene_a.bodies[2], {0, 1, 0})
	box3d.Body_SetLinearVelocity(scene_b.bodies[2], {0, 1.5, 0})
	box3d.Body_SetAwake(last, true)
	testing.expect(t, hash(scene_a.world) != hash(scene_b.world))
}

// ---- a sync-test of the library alone: a stack settles and falls asleep, a push wakes it, and the run rolls back
// BOX3D_WINDOW ticks after every tick and re-simulates. Every re-simulated tick must hash (the whole world, and the
// awake bodies) as a straight run with one worker does, on 1 and 4 workers, so both transitions happen inside rollback
// windows and the worker count changes nothing.

BOX3D_SYNC_TICKS :: 320
BOX3D_WINDOW :: 8
BOX3D_WAKE_TICK :: 200 // the push; the stack is asleep before it

Box3d_Stack :: struct {
	phys:  ^physics.World,
	boxes: [4]box3d.BodyId,
}

box3d_stack_make :: proc(workers: i32) -> Box3d_Stack {
	stack := Box3d_Stack {
		phys = physics.create({tick_hz = HZ, workers = workers}),
	}
	box3d_box(stack.phys.id, .staticBody, {0, -0.5, 0}, {10, 0.5, 10})
	for &body, i in stack.boxes {
		body = box3d_box(stack.phys.id, .dynamicBody, {0, 0.5 + f32(i) * 1.01, 0}, {0.5, 0.5, 0.5})
	}
	return stack
}

// One tick: a push on the top box at BOX3D_WAKE_TICK, then the step; both hashes after it.
box3d_stack_tick :: proc(stack: ^Box3d_Stack, tick: int) -> [2]u64 {
	if tick == BOX3D_WAKE_TICK do box3d.Body_ApplyLinearImpulseToCenter(stack.boxes[3], {3, 0, 1}, true)
	box3d.World_Step(stack.phys.id, BOX3D_DT, BOX3D_SUBSTEPS)
	return {box3d.World_HashState(stack.phys.id), box3d.World_HashAwakeBodies(stack.phys.id)}
}

box3d_stack_awake :: proc(stack: ^Box3d_Stack) -> bool {
	for body in stack.boxes {
		if box3d.Body_IsAwake(body) do return true
	}
	return false
}

@(test)
box3d_sync_test_sleep_and_wake :: proc(t: ^testing.T) {
	reference: [BOX3D_SYNC_TICKS][2]u64
	awake: [BOX3D_SYNC_TICKS]bool
	{
		stack := box3d_stack_make(1)
		defer physics.destroy(stack.phys)
		for tick in 0 ..< BOX3D_SYNC_TICKS {
			reference[tick] = box3d_stack_tick(&stack, tick)
			awake[tick] = box3d_stack_awake(&stack)
		}
	}
	// The scene does what the test is for: the stack falls asleep before the push and wakes with it.
	fell_asleep := -1
	for tick in 1 ..< BOX3D_WAKE_TICK {
		if awake[tick - 1] && !awake[tick] do fell_asleep = tick
	}
	testing.expectf(
		t,
		fell_asleep > 0 && !awake[BOX3D_WAKE_TICK - 1],
		"the stack never fell asleep before tick %d",
		BOX3D_WAKE_TICK,
	)
	testing.expect(t, awake[BOX3D_WAKE_TICK], "the push didn't wake the stack")
	for workers in ([]i32{1, 4}) {
		stack := box3d_stack_make(workers)
		defer physics.destroy(stack.phys)
		ring: [BOX3D_WINDOW + 1]box3d.WorldSnapshot // the state before each tick of the window
		defer for &snapshot in ring do box3d.DestroyWorldSnapshot(&snapshot)
		mismatches := 0
		ticks: for tick in 0 ..< BOX3D_SYNC_TICKS {
			box3d.World_SaveSnapshot(stack.phys.id, &ring[tick % len(ring)])
			if box3d_stack_tick(&stack, tick) != reference[tick] do mismatches += 1
			from := max(0, tick + 1 - BOX3D_WINDOW)
			if !box3d.World_RestoreSnapshot(stack.phys.id, &ring[from % len(ring)]) {
				mismatches = BOX3D_SYNC_TICKS
				break ticks
			}
			for resim in from ..= tick {
				if resim > from do box3d.World_SaveSnapshot(stack.phys.id, &ring[resim % len(ring)])
				if box3d_stack_tick(&stack, resim) != reference[resim] do mismatches += 1
			}
		}
		testing.expectf(t, mismatches == 0, "%d workers: %d re-simulated ticks differ", workers, mismatches)
	}
}

// ---- image loads: a late joiner's Box3D image can come from anyone, so `World_LoadImage` on damaged and made-up
// bytes either refuses them, leaving the world as it was, or loads a world that hashes, saves, snapshots, restores and
// is destroyed safely. Flips, 32-bit edge values, cuts and random bytes of real images of the golden scene. Stepping
// such worlds is unified-box3d's own fuzz suite (asserts off, bounds checks on); here it would trip the debug library's
// numeric asserts (the `box3d-debug` suite) on worlds that are safe but simulate badly.

@(private = "file")
Fuzz :: struct {
	state: u64,
}

@(private = "file")
fuzz_below :: proc(fuzz: ^Fuzz, n: int) -> int {
	fuzz.state += 0x9E3779B97F4A7C15
	z := fuzz.state
	z = (z ~ (z >> 30)) * 0xBF58476D1CE4E5B9
	z = (z ~ (z >> 27)) * 0x94D049BB133111EB
	return int((z ~ (z >> 31)) % u64(n))
}

@(private = "file")
Counts :: struct {
	tried, loaded: int,
}

// Loads `bytes` into a fresh world; what loads is hashed, saved, snapshotted and restored, and a refusal leaves the
// world as it was (its hash unchanged).
@(private = "file")
fuzz_try :: proc(t: ^testing.T, bytes: []u8, counts: ^Counts, state: ^box3d.WorldState) {
	counts.tried += 1
	world := physics.create({tick_hz = HZ})
	defer physics.destroy(world)
	before := box3d.World_HashState(world.id)
	if !box3d.World_LoadImage(world.id, raw_data(bytes), i32(len(bytes))) {
		testing.expect_value(t, box3d.World_HashState(world.id), before)
		return
	}
	counts.loaded += 1
	_ = box3d.World_HashState(world.id)
	_ = box3d.World_HashAwakeBodies(world.id)
	snapshot: box3d.WorldSnapshot
	box3d.World_SaveSnapshot(world.id, &snapshot)
	testing.expect(t, box3d.World_RestoreSnapshot(world.id, &snapshot))
	box3d.DestroyWorldSnapshot(&snapshot)
	testing.expect(t, box3d.World_SaveImage(world.id, state, true) > 0)
}

@(test)
box3d_image_load_is_safe_on_any_bytes :: proc(t: ^testing.T) {
	scene: Box3d_Scene
	box3d_scene_make(&scene)
	defer box3d_scene_destroy(&scene)
	state := box3d.CreateWorldState()
	defer box3d.DestroyWorldState(state)
	seeds: [2][]u8
	for &seed, k in seeds {
		box3d_steps(scene.world, 60 + 200 * k) // moving, then asleep
		testing.expect(t, box3d.World_SaveImage(scene.world, state, true) > 0)
		data := box3d.WorldState_GetData(state)[:box3d.WorldState_GetSize(state)]
		seed = make([]u8, len(data))
		copy(seed, data)
	}
	defer for seed in seeds {
		delete(seed)
	}
	work := make([]u8, max(len(seeds[0]), len(seeds[1])))
	defer delete(work)
	fuzz := Fuzz{0xD11A}
	for seed in seeds {
		counts: Counts
		fuzz_try(t, seed, &counts, state)
		testing.expect_value(t, counts.loaded, 1)
	}
	EDGES := [?]u32{0, 1, 0xFFFFFFFF, 0x7FFFFFFF, 0x80000000, 0x7FC00000, 1 << 20, 1 << 30}
	flips, edges, cuts, random: Counts
	for seed in seeds {
		for offset := 0; offset < len(seed); offset += 5 {
			bytes := work[:len(seed)]
			copy(bytes, seed)
			bytes[offset] ~= u8(1 + fuzz_below(&fuzz, 255))
			fuzz_try(t, bytes, &flips, state)
		}
		for offset := 0; offset + 4 <= len(seed); offset += 12 {
			bytes := work[:len(seed)]
			copy(bytes, seed)
			(^u32le)(&bytes[offset])^ = u32le(EDGES[fuzz_below(&fuzz, len(EDGES))])
			fuzz_try(t, bytes, &edges, state)
		}
		for length := 0; length < len(seed); length += 37 {
			fuzz_try(t, seed[:length], &cuts, state)
		}
		for i in 0 ..< 200 {
			length := 1 + fuzz_below(&fuzz, len(seed))
			bytes := work[:length]
			keep := i % 2 == 0 ? 0 : fuzz_below(&fuzz, length)
			copy(bytes[:keep], seed[:keep])
			for &b in bytes[keep:] {
				b = u8(fuzz_below(&fuzz, 256))
			}
			fuzz_try(t, bytes, &random, state)
		}
	}
	testing.expect_value(t, cuts.loaded, 0)
	testing.expect_value(t, random.loaded, 0)
	log.infof(
		"images of %d and %d bytes: flips %d of %d loaded, edge words %d of %d, cuts %d of %d, random %d of %d",
		len(seeds[0]),
		len(seeds[1]),
		flips.loaded,
		flips.tried,
		edges.loaded,
		edges.tried,
		cuts.loaded,
		cuts.tried,
		random.loaded,
		random.tried,
	)
}
