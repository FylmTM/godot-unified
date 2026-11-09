// The Box3D fork and its bindings, on their own (AGENTS.md: every dependency has tests covering what
// we use): the binding layouts against the pinned headers, each call the games make, exact
// save/restore across body types, contacts, sleep and body creation/destruction, portable images in
// a second world, damaged images, and a golden trace that pins the fork's results (an upgrade that
// changes them fails here first, then the games' reference runs).
package test_box3d

import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:reflect"
import "core:strconv"
import "core:strings"
import "core:testing"

import b3 "unified:box3d"
import "unified:physics"
import "unified:sim"

DT :: f32(1.0 / 64)
SUBSTEPS :: 4

// Worlds come from physics.create, which serialises b3CreateWorld/b3DestroyWorld (they touch Box3D's
// global world table) against the other test packages running on other threads; it calls
// DefaultWorldDef and CreateWorld with one worker.
world_make :: proc(gravity: Maybe([3]f32) = nil) -> ^physics.World {
	return physics.create({gravity = gravity})
}

box_body :: proc(w: b3.WorldId, type: b3.BodyType, pos: b3.Vec3, half: b3.Vec3, sd: ^b3.ShapeDef = nil) -> b3.BodyId {
	bd := b3.DefaultBodyDef()
	bd.type = type
	bd.position = pos
	body := b3.CreateBody(w, &bd)
	def := b3.DefaultShapeDef()
	if sd != nil {
		def = sd^
	}
	def.density = 1
	hull := b3.MakeBoxHull(half.x, half.y, half.z)
	b3.CreateHullShape(body, &def, &hull.base)
	return body
}

// Position, rotation, velocities of each body as raw bits (−0 and +0 differ: exactness is the point).
state_hash :: proc(bodies: []b3.BodyId) -> u64 {
	buf := make([dynamic]u8, context.temp_allocator)
	for id in bodies {
		p := b3.Body_GetPosition(id)
		q := b3.Body_GetRotation(id)
		v := b3.Body_GetLinearVelocity(id)
		a := b3.Body_GetAngularVelocity(id)
		vals := [13]f32{p.x, p.y, p.z, q.v.x, q.v.y, q.v.z, q.s, v.x, v.y, v.z, a.x, a.y, a.z}
		append(&buf, ..([^]u8)(&vals)[:size_of(vals)])
	}
	return sim.hash_bytes(buf[:])
}

step :: proc(w: b3.WorldId, n: int) {
	for _ in 0 ..< n {
		b3.World_Step(w, DT, SUBSTEPS)
	}
}

// A scene with every body type, contacts that settle and sleep, a spinning capsule and a sphere.
Scene :: struct {
	phys:   ^physics.World,
	world:  b3.WorldId,
	bodies: [dynamic]b3.BodyId,
}

scene_make :: proc(s: ^Scene) {
	s.phys = world_make()
	s.world = s.phys.id
	append(&s.bodies, box_body(s.world, .staticBody, {0, -0.5, 0}, {20, 0.5, 20}))
	kin := box_body(s.world, .kinematicBody, {-6, 1, 0}, {1, 0.25, 1})
	b3.Body_SetLinearVelocity(kin, {1, 0, 0})
	append(&s.bodies, kin)
	for i in 0 ..< 6 { 	// a stack: contacts, then sleep
		append(&s.bodies, box_body(s.world, .dynamicBody, {3, 0.5 + f32(i) * 1.01, 0}, {0.5, 0.5, 0.5}))
	}
	bd := b3.DefaultBodyDef()
	bd.type = .dynamicBody
	bd.position = {0, 3, 4}
	bd.angularVelocity = {0, 5, 2}
	cap_body := b3.CreateBody(s.world, &bd)
	sd := b3.DefaultShapeDef()
	sd.density = 1
	capsule := b3.Capsule{{0, -0.4, 0}, {0, 0.4, 0}, 0.3}
	b3.CreateCapsuleShape(cap_body, &sd, &capsule)
	append(&s.bodies, cap_body)
	bd.position = {-3, 5, -3}
	bd.angularVelocity = {}
	ball := b3.CreateBody(s.world, &bd)
	sphere := b3.Sphere{{0, 0, 0}, 0.5}
	b3.CreateSphereShape(ball, &sd, &sphere)
	append(&s.bodies, ball)
}

scene_destroy :: proc(s: ^Scene) {
	physics.destroy(s.phys)
	delete(s.bodies)
}

@(test)
bodies_fall_and_rest :: proc(t: ^testing.T) {
	pw := world_make()
	defer physics.destroy(pw)
	w := pw.id
	box_body(w, .staticBody, {0, -0.5, 0}, {10, 0.5, 10})
	b := box_body(w, .dynamicBody, {0, 5, 0}, {0.5, 0.5, 0.5})
	step(w, 16)
	testing.expect(t, b3.Body_GetPosition(b).y < 5)
	testing.expect(t, b3.Body_GetLinearVelocity(b).y < 0)
	step(w, 300)
	p := b3.Body_GetPosition(b)
	testing.expectf(t, p.y > 0.45 && p.y < 0.55, "resting at %v", p)
	q := b3.Body_GetRotation(b)
	l := q.v.x * q.v.x + q.v.y * q.v.y + q.v.z * q.v.z + q.s * q.s
	testing.expect(t, l > 0.999 && l < 1.001)
}

@(test)
velocity_impulse_and_spin :: proc(t: ^testing.T) {
	pw := world_make([3]f32{})
	defer physics.destroy(pw)
	w := pw.id
	b := box_body(w, .dynamicBody, {0, 0, 0}, {0.5, 0.5, 0.5}) // 1 m³ at density 1: mass 1
	b3.Body_SetLinearVelocity(b, {2, 0, 0})
	testing.expect_value(t, b3.Body_GetLinearVelocity(b), b3.Vec3{2, 0, 0})
	b3.Body_ApplyLinearImpulseToCenter(b, {0, 0, 3}, true)
	v := b3.Body_GetLinearVelocity(b)
	testing.expectf(t, v.x == 2 && v.z > 2.99 && v.z < 3.01, "after impulse: %v", v)
	bd := b3.DefaultBodyDef()
	bd.type = .dynamicBody
	bd.angularVelocity = {0, 4, 0}
	spinner := b3.CreateBody(w, &bd)
	sd := b3.DefaultShapeDef()
	sd.density = 1
	cube := b3.MakeCubeHull(0.5)
	b3.CreateHullShape(spinner, &sd, &cube.base)
	step(w, 8)
	a := b3.Body_GetAngularVelocity(spinner)
	testing.expectf(t, a.y > 1 && a.y <= 4, "spin %v", a) // damped and precessing, but spinning
	testing.expect(t, b3.Body_GetRotation(spinner).v.y != 0)
}

// Angular motion locks (the game's player capsules) keep a body upright when hit off-centre.
@(test)
motion_locks_hold :: proc(t: ^testing.T) {
	pw := world_make()
	defer physics.destroy(pw)
	w := pw.id
	box_body(w, .staticBody, {0, -0.5, 0}, {10, 0.5, 10})
	bd := b3.DefaultBodyDef()
	bd.type = .dynamicBody
	bd.position = {0, 1, 0}
	bd.motionLocks = {
		angularX = true,
		angularY = true,
		angularZ = true,
	}
	body := b3.CreateBody(w, &bd)
	sd := b3.DefaultShapeDef()
	sd.density = 1
	capsule := b3.Capsule{{0, -0.45, 0}, {0, 0.45, 0}, 0.45}
	b3.CreateCapsuleShape(body, &sd, &capsule)
	hit := box_body(w, .dynamicBody, {-3, 1.6, 0.3}, {0.3, 0.3, 0.3})
	b3.Body_SetLinearVelocity(hit, {12, 0, 0})
	step(w, 64)
	q := b3.Body_GetRotation(body)
	testing.expectf(t, q.v == {} && q.s == 1, "rotated: %v", q)
	testing.expect_value(t, b3.Body_GetAngularVelocity(body), b3.Vec3{})
}

// Ray casts report the hit shape's userMaterialId; query and shape filters select what a ray sees
// and what collides (the game's crates, barrels, players and static geometry).
@(test)
ray_casts_and_filters :: proc(t: ^testing.T) {
	pw := world_make()
	defer physics.destroy(pw)
	w := pw.id
	CAT_A :: u64(1 << 1)
	CAT_B :: u64(1 << 2)
	sd := b3.DefaultShapeDef()
	sd.baseMaterial.userMaterialId = 1007
	sd.filter.categoryBits = CAT_A
	a := box_body(w, .staticBody, {0, 0, 0}, {1, 1, 1}, &sd)
	sd.baseMaterial.userMaterialId = 2002
	sd.filter.categoryBits = CAT_B
	box_body(w, .staticBody, {0, 0, 5}, {1, 1, 1}, &sd)
	qf := b3.DefaultQueryFilter()
	r := b3.World_CastRayClosest(w, {0, 0, -5}, {0, 0, 20}, qf)
	testing.expect(t, r.hit)
	testing.expect_value(t, r.userMaterialId, 1007)
	testing.expectf(t, r.point.z > -1.01 && r.point.z < -0.99, "hit at %v", r.point)
	testing.expectf(t, r.fraction > 0.19 && r.fraction < 0.21, "fraction %v", r.fraction)
	testing.expect_value(t, r.normal, b3.Vec3{0, 0, -1})
	qf.maskBits = CAT_B
	r = b3.World_CastRayClosest(w, {0, 0, -5}, {0, 0, 20}, qf)
	testing.expect(t, r.hit)
	testing.expect_value(t, r.userMaterialId, 2002)
	qf.maskBits = 1 << 5
	testing.expect(t, !b3.World_CastRayClosest(w, {0, 0, -5}, {0, 0, 20}, qf).hit)
	// A destroyed body no longer blocks rays.
	b3.DestroyBody(a)
	r = b3.World_CastRayClosest(w, {0, 0, -5}, {0, 0, 20}, b3.DefaultQueryFilter())
	testing.expect_value(t, r.userMaterialId, 2002)
	// Shapes whose masks exclude each other's categories pass through each other.
	sd2 := b3.DefaultShapeDef()
	sd2.filter.categoryBits = CAT_A
	sd2.filter.maskBits = ~CAT_B
	ghost := box_body(w, .dynamicBody, {0, 4, 5}, {0.5, 0.5, 0.5}, &sd2)
	step(w, 120)
	testing.expectf(t, b3.Body_GetPosition(ghost).y < -5, "the ghost landed at %v", b3.Body_GetPosition(ghost))
}

// Save, run on, restore, run again: bit-identical, for every body type, through contacts and sleep,
// and across bodies created and destroyed after the save (rollback re-simulates exactly that).
@(test)
save_restore_is_exact :: proc(t: ^testing.T) {
	s: Scene
	scene_make(&s)
	defer scene_destroy(&s)
	cache := b3.CreateWorldStateCache()
	defer b3.DestroyWorldStateCache(cache)
	st := b3.CreateWorldState()
	defer b3.DestroyWorldState(st)
	step(s.world, 90)
	testing.expect(t, b3.World_SaveState(s.world, cache, st) > 0)
	h0 := state_hash(s.bodies[:])
	step(s.world, 120) // the stack sleeps by now
	h1 := state_hash(s.bodies[:])
	testing.expect(t, h1 != h0)
	testing.expect(t, b3.World_RestoreState(s.world, cache, st))
	testing.expect_value(t, state_hash(s.bodies[:]), h0)
	step(s.world, 120)
	testing.expect_value(t, state_hash(s.bodies[:]), h1)

	// Diverge: destroy a stacked box, add one, run; restore; the original continuation reappears.
	testing.expect(t, b3.World_RestoreState(s.world, cache, st))
	b3.DestroyBody(s.bodies[4])
	extra := box_body(s.world, .dynamicBody, {3, 8, 0}, {0.5, 0.5, 0.5})
	step(s.world, 30)
	_ = extra
	testing.expect(t, b3.World_RestoreState(s.world, cache, st))
	testing.expect_value(t, state_hash(s.bodies[:]), h0)
	step(s.world, 120)
	testing.expect_value(t, state_hash(s.bodies[:]), h1)
}

// A saved image restores into a second world built the same way (late join, resume), and runs on
// identically; damaged images are refused.
@(test)
image_into_another_world :: proc(t: ^testing.T) {
	a, b: Scene
	scene_make(&a)
	defer scene_destroy(&a)
	scene_make(&b)
	defer scene_destroy(&b)
	ca, cb := b3.CreateWorldStateCache(), b3.CreateWorldStateCache()
	defer b3.DestroyWorldStateCache(ca)
	defer b3.DestroyWorldStateCache(cb)
	sa, sb := b3.CreateWorldState(), b3.CreateWorldState()
	defer b3.DestroyWorldState(sa)
	defer b3.DestroyWorldState(sb)
	testing.expect(t, b3.World_SaveState(b.world, cb, sb) > 0) // fills b's geometry registry in creation order
	step(a.world, 100)
	n := int(b3.World_SaveState(a.world, ca, sa))
	image := make([]u8, n)
	defer delete(image)
	copy(image, b3.WorldState_GetData(sa)[:n])
	testing.expect_value(t, int(b3.WorldState_GetSize(sa)), n)
	testing.expect(t, b3.World_RestoreStateFromBytes(b.world, cb, image))
	testing.expect_value(t, state_hash(b.bodies[:]), state_hash(a.bodies[:]))
	step(a.world, 100)
	step(b.world, 100)
	testing.expect_value(t, state_hash(b.bodies[:]), state_hash(a.bodies[:]))
	// An empty image is refused.
	testing.expect(t, !b3.World_RestoreStateFromBytes(b.world, cb, nil))
}

// The pinned fork's results: a fixed scene, 240 ticks, hashed every 60. The same on every platform.
// A Box3D upgrade or a build-flag change that alters any of these values fails here; if the change
// is intended, update the values (and regenerate the reference runs, `dev.py regen <game>|toy`) in
// the same commit.
GOLDEN := [4]u64{0x3125e350623f9163, 0x3f3637eb749e2a37, 0xf0d63788ca5d305b, 0xa2fd5716d15ff9f4}

@(test)
golden_trace :: proc(t: ^testing.T) {
	s: Scene
	scene_make(&s)
	defer scene_destroy(&s)
	got: [4]u64
	for k in 0 ..< 4 {
		step(s.world, 60)
		got[k] = state_hash(s.bodies[:])
	}
	testing.expectf(t, got == GOLDEN, "golden trace changed: %x (pinned %x)", got, GOLDEN)
}

// ---- binding layouts against the pinned headers -----------------------------------------------------

Layout :: struct {
	odin:   typeid,
	c:      string,
	fields: string, // C field names in Odin field order ("" : the Odin names)
}

LAYOUTS := []Layout {
	{b3.Vec3, "b3Vec3", ""},
	{b3.Quat, "b3Quat", ""},
	{b3.AABB, "b3AABB", ""},
	{b3.Matrix3, "b3Matrix3", ""},
	{b3.WorldId, "b3WorldId", ""},
	{b3.BodyId, "b3BodyId", ""},
	{b3.ShapeId, "b3ShapeId", ""},
	{b3.Capacity, "b3Capacity", ""},
	{b3.WorldDef, "b3WorldDef", ""},
	{b3.MotionLocks, "b3MotionLocks", ""},
	{b3.BodyDef, "b3BodyDef", ""},
	{b3.SurfaceMaterial, "b3SurfaceMaterial", ""},
	{b3.Filter, "b3Filter", ""},
	{b3.ShapeDef, "b3ShapeDef", ""},
	{b3.QueryFilter, "b3QueryFilter", ""},
	{b3.RayResult, "b3RayResult", ""},
	{b3.Sphere, "b3Sphere", ""},
	{b3.Capsule, "b3Capsule", ""},
	{b3.Plane, "b3Plane", ""},
	{b3.HullVertex, "b3HullVertex", ""},
	{b3.HullHalfEdge, "b3HullHalfEdge", ""},
	{b3.HullFace, "b3HullFace", ""},
	{b3.HullData, "b3HullData", ""},
	{b3.BoxHull, "b3BoxHull", ""},
}

// Constants copied by value into the binding.
CONSTANTS := []struct {
	c:    string,
	odin: i64,
} {
	{"b3_staticBody", i64(b3.BodyType.staticBody)},
	{"b3_kinematicBody", i64(b3.BodyType.kinematicBody)},
	{"b3_dynamicBody", i64(b3.BodyType.dynamicBody)},
}

// The private mirror of the fork's internal b3RecBuffer (src/recording.h) that
// World_RestoreStateFromBytes relies on: size and offsets as box3d.odin declares them.
REC_BUFFER := [?]struct {
	what:  string,
	value: i64,
} {
	{"sizeof(b3RecBuffer)", 24},
	{"offsetof(b3RecBuffer, data)", 0},
	{"offsetof(b3RecBuffer, capacity)", 8},
	{"offsetof(b3RecBuffer, size)", 12},
	{"offsetof(b3RecBuffer, countOnly)", 16},
}

BOX3D_DIR :: #directory + "/../../third_party/box3d"

platform_dir :: proc() -> string {
	os_ := ODIN_OS == .Darwin ? "macos" : ODIN_OS == .Windows ? "windows" : "linux"
	arch := ODIN_ARCH == .arm64 ? "arm64" : "x64"
	return fmt.tprintf("%s/build/%s-%s", BOX3D_DIR, os_, arch)
}

@(test)
bindings_match_the_headers :: proc(t: ^testing.T) {
	include := fmt.tprintf("%s/include", platform_dir())
	internal :: BOX3D_DIR + "/src/src"
	if !os.exists(fmt.tprintf("%s/box3d/box3d.h", include)) || !os.exists(internal + "/recording.h") {
		log.info("Box3D headers not staged (python tools/box3d.py); layout check skipped")
		return
	}
	cc := ""
	for name in ([]string{"clang", "cc"}) {
		if p, ok := find_on_path(name); ok {
			cc = p
			break
		}
	}
	if cc == "" {
		log.info("no C compiler on PATH; layout check skipped")
		return
	}
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintln(
		&b,
		"#include <stdio.h>\n#include <stddef.h>\n#include \"box3d/box3d.h\"\n#include \"box3d/collision.h\"",
	)
	fmt.sbprintln(&b, "#include \"recording.h\"\nint main(void) {")
	for l in LAYOUTS {
		fmt.sbprintfln(&b, "printf(\"size %s %%zu\\n\", sizeof(%s));", l.c, l.c)
		for f in reflect.struct_field_names(l.odin) {
			fmt.sbprintfln(&b, "printf(\"off %s.%s %%zu\\n\", offsetof(%s, %s));", l.c, f, l.c, f)
		}
	}
	for c in CONSTANTS {
		fmt.sbprintfln(&b, "printf(\"const %s %%lld\\n\", (long long)(%s));", c.c, c.c)
	}
	for r, i in REC_BUFFER {
		fmt.sbprintfln(&b, "printf(\"rec %d %%lld\\n\", (long long)(%s));", i, r.what)
	}
	fmt.sbprintln(&b, "return 0; }")
	dir := os.temp_directory(context.temp_allocator) or_else "."
	src, _ := filepath.join({dir, "unified-box3d-layout.c"}, context.temp_allocator)
	exe, _ := filepath.join(
		{dir, ODIN_OS == .Windows ? "unified-box3d-layout.exe" : "unified-box3d-layout"},
		context.temp_allocator,
	)
	testing.expect(t, os.write_entire_file(src, transmute([]u8)strings.to_string(b)) == nil)
	defer os.remove(src)
	defer os.remove(exe)
	st, _, cerr, err := os.process_exec(
		{command = {cc, "-I", include, "-I", internal, "-o", exe, src}},
		context.temp_allocator,
	)
	if !testing.expectf(
		t,
		err == nil && st.exit_code == 0,
		"compiling the layout probe failed: %v\n%s",
		err,
		string(cerr),
	) {
		return
	}
	st2, out, _, err2 := os.process_exec({command = {exe}}, context.temp_allocator)
	if !testing.expect(t, err2 == nil && st2.exit_code == 0, "running the layout probe failed") {
		return
	}
	vals := make(map[string]i64, context.temp_allocator)
	for line in strings.split_lines(string(out), context.temp_allocator) {
		parts := strings.fields(line, context.temp_allocator)
		if len(parts) == 3 {
			v, _ := strconv.parse_i64(parts[2])
			vals[strings.concatenate({parts[0], " ", parts[1]}, context.temp_allocator)] = v
		}
	}
	for l in LAYOUTS {
		size := i64(reflect.size_of_typeid(l.odin))
		testing.expectf(
			t,
			vals[fmt.tprintf("size %s", l.c)] == size,
			"%s: C size %d, Odin %d",
			l.c,
			vals[fmt.tprintf("size %s", l.c)],
			size,
		)
		offsets := reflect.struct_field_offsets(l.odin)
		for f, i in reflect.struct_field_names(l.odin) {
			c_off := vals[fmt.tprintf("off %s.%s", l.c, f)]
			testing.expectf(t, c_off == i64(offsets[i]), "%s.%s: C offset %d, Odin %d", l.c, f, c_off, offsets[i])
		}
	}
	for c in CONSTANTS {
		testing.expectf(
			t,
			vals[fmt.tprintf("const %s", c.c)] == c.odin,
			"%s: header %d, Odin %d",
			c.c,
			vals[fmt.tprintf("const %s", c.c)],
			c.odin,
		)
	}
	for r, i in REC_BUFFER {
		testing.expectf(
			t,
			vals[fmt.tprintf("rec %d", i)] == r.value,
			"%s: fork %d, box3d.odin %d",
			r.what,
			vals[fmt.tprintf("rec %d", i)],
			r.value,
		)
	}
}

find_on_path :: proc(name: string) -> (string, bool) {
	path := os.get_env("PATH", context.temp_allocator)
	for d in strings.split(path, ODIN_OS == .Windows ? ";" : ":", context.temp_allocator) {
		p, _ := filepath.join(
			{d, ODIN_OS == .Windows ? strings.concatenate({name, ".exe"}, context.temp_allocator) : name},
			context.temp_allocator,
		)
		if os.is_file(p) {
			return p, true
		}
	}
	return "", false
}
