// The World (outside the block): the physics world locked to the plane, the level and what the sim reads from
// its markers, body creation, and the game descriptor.
package drift

import b3 "unified:box3d"
import "unified:dmath"
import "unified:level"
import "unified:physics"
import "unified:sim"

// Shape categories (filter bits) and user materials (how rays tell entities apart).
CAT_STATIC :: u64(1 << 0)
CAT_SHIP :: u64(1 << 1)
CAT_ROCK :: u64(1 << 2)
CAT_STATION :: u64(1 << 3)
CAT_CATALOGUE :: u64(1 << 4) // collides with nothing
CAT_BULLET :: u64(1 << 5) // rays only
MAT_ROCK :: u64(1000) // + rock index
MAT_STATION :: u64(2000)

Gate_Def :: struct {
	pos:  [2]f32,
	pair: int, // gate index
}

Spawner_Def :: struct {
	pos: [2]f32,
	dir: [2]f32, // unit
}

World :: struct {
	phys:       ^physics.World,
	extras:     [1]sim.Extra,
	lvl:        level.Level,
	px_per_m:   f32, // the level's (the view's units)
	spawns:     [MAX_PLAYERS][2]f32,
	station:    [2]f32,
	gates:      [MAX_GATES]Gate_Def,
	n_gates:    int,
	spawners:   [MAX_SPAWNERS]Spawner_Def,
	n_spawners: int,
}

Game :: sim.Game(State, Input, World, MAX_PLAYERS)
Sim :: sim.Sim(State, Input, World, MAX_PLAYERS)

@(rodata)
GAME := Game {
	name = "drift",
	version = "1",
	tick_hz = TICK_HZ,
	world_create = world_create,
	world_destroy = world_destroy,
	extras = proc(w: ^World) -> []sim.Extra {return w.extras[:]},
	init = init,
	tick = tick,
	event_names = EVENT_NAMES,
	commands = COMMANDS,
}

// Builds the world from the level (src/level/SPEC.md, 2D levels): static geometry, the rock catalogue, then
// the markers. Bodies the block owns (the station, ships, rocks) are created by init and the tick.
world_create :: proc(seed: u64, content: []u8) -> ^World {
	w := new(World)
	lvl, ok := level.load(content)
	assert(ok && lvl.px_per_m > 0, "drift: the level file is missing or not a 2D level (src/level/SPEC.md)")
	w.lvl = lvl
	w.px_per_m = lvl.px_per_m
	w.phys = physics.create({gravity = [3]f32{0, 0, 0}})
	w.extras[0] = physics.extra(w.phys, State)
	physics.create_static(w.phys, &w.lvl, CAT_STATIC)
	create_catalogue(w)
	for p in 0 ..< MAX_PLAYERS do w.spawns[p] = {f32(p) * 2 - 3, 6}
	n_spawn := 0
	for &m in w.lvl.markers {
		pos := [2]f32{m.pos.x, m.pos.y}
		switch m.kind {
		case "spawn":
			if n_spawn < MAX_PLAYERS {
				w.spawns[n_spawn] = pos
				n_spawn += 1
			}
		case "station":
			w.station = pos
		case "gate":
			assert(w.n_gates < MAX_GATES, "drift: too many gates")
			w.gates[w.n_gates] = {pos, level.prop_ref(&m, "pair")} // a marker index for now
			w.n_gates += 1
		case "rock_spawn":
			assert(w.n_spawners < MAX_SPAWNERS, "drift: too many rock spawners")
			d := dmath.normalize2(level.prop_vec2(&m, "dir", {0, 1}))
			if d == {} do d = {0, 1}
			w.spawners[w.n_spawners] = {pos, d}
			w.n_spawners += 1
		}
	}
	assert(w.n_spawners > 0, "drift: the level has no rock_spawn marker")
	// gate pairs: marker index -> gate index
	for i in 0 ..< w.n_gates {
		pair := -1
		k := 0
		for &m in w.lvl.markers {
			if m.kind != "gate" do continue
			if m.index == w.gates[i].pair do pair = k
			k += 1
		}
		w.gates[i].pair = pair
	}
	return w
}

world_destroy :: proc(w: ^World) {
	physics.destroy(w.phys)
	level.destroy(&w.lvl)
	free(w)
}

// Every rock hull (each variant at each size) on one static body far outside the arena that collides with
// nothing, created before tick 0: Box3D's portable image names hull geometry by its index in the registry a
// fresh world fills from its tick-0 save, so a late joiner can load any rock a split makes later
// (src/physics/SPEC.md, 2D: generated geometry).
create_catalogue :: proc(w: ^World) {
	bd := physics.body_def_2d(.staticBody, {-1000, -1000})
	id := b3.CreateBody(w.phys.id, &bd)
	sd := b3.DefaultShapeDef()
	sd.filter.categoryBits = CAT_CATALOGUE
	sd.filter.maskBits = 0
	for v in 0 ..< ROCK_VARIANTS {
		for size in Rock_Size {
			pts := rock_points(v, size)
			physics.polygon_2d(id, &sd, pts[:], ROCK_DEPTH)
		}
	}
}

rock_points :: proc(variant: int, size: Rock_Size) -> (pts: [8][2]f32) {
	r := ROCK_RADIUS[size]
	for k in 0 ..< 8 {
		f := ROCK_SHAPES[variant][k] * r
		pts[k] = {dmath.DIR8_C[k] * f, dmath.DIR8_S[k] * f}
	}
	return
}

// The station's hexagon (corners at k × 60°: cos/sin from exact constants).
@(rodata)
HEX_C := [6]f32{1, 0.5, -0.5, -1, -0.5, 0.5}
@(rodata)
HEX_S := [6]f32{0, 0.8660254, 0.8660254, 0, -0.8660254, -0.8660254}

init :: proc(s: ^State, w: ^World, seed: u64) {
	s.rng = sim.rng_seed(seed)
	s.station_hp = STATION_HP
	bd := physics.body_def_2d(.kinematicBody, w.station)
	id := b3.CreateBody(w.phys.id, &bd)
	sd := b3.DefaultShapeDef()
	sd.filter.categoryBits = CAT_STATION
	sd.baseMaterial.userMaterialId = MAT_STATION
	pts: [6][2]f32
	for k in 0 ..< 6 do pts[k] = {HEX_C[k] * STATION_RADIUS, HEX_S[k] * STATION_RADIUS}
	physics.polygon_2d(id, &sd, pts[:], ROCK_DEPTH)
	s.station = physics.ref_of(id)
	physics.set_velocity_2d(w.phys, s.station, {}, STATION_SPIN)
}

create_ship :: proc(s: ^State, w: ^World, p: int) {
	bd := physics.body_def_2d(.dynamicBody, w.spawns[p], {0, -1})
	bd.linearDamping = SHIP_DAMPING
	bd.isBullet = false
	id := b3.CreateBody(w.phys.id, &bd)
	sd := b3.DefaultShapeDef()
	sd.density = SHIP_DENSITY
	sd.baseMaterial.restitution = 0.5
	sd.baseMaterial.friction = 0.1
	sd.filter.categoryBits = CAT_SHIP
	physics.circle_2d(id, &sd, SHIP_RADIUS)
	s.ships[p].body = physics.ref_of(id)
}

create_rock :: proc(
	s: ^State,
	w: ^World,
	size: Rock_Size,
	variant: int,
	pos, vel: [2]f32,
	spin: f32,
	events: Events,
) -> bool {
	r, h, ok := sim.spawn(&s.rocks)
	if !ok do return false
	bd := physics.body_def_2d(.dynamicBody, pos)
	id := b3.CreateBody(w.phys.id, &bd)
	sd := b3.DefaultShapeDef()
	sd.density = 1
	sd.baseMaterial.restitution = 0.4
	sd.baseMaterial.friction = 0.3
	sd.baseMaterial.userMaterialId = MAT_ROCK + u64(h.index)
	sd.filter.categoryBits = CAT_ROCK
	pts := rock_points(variant, size)
	physics.polygon_2d(id, &sd, pts[:], ROCK_DEPTH)
	r^ = {
		body    = physics.ref_of(id),
		size    = size,
		variant = u8(variant),
		hp      = ROCK_HP[size],
	}
	physics.set_velocity_2d(w.phys, r.body, vel, spin)
	return true
}
