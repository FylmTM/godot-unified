// The world outside the block: the physics world (static geometry, then items and players, in
// GAME.md creation order) and per-tick scratch; plus body creation and the game descriptor.
package survivor

import b3 "unified:box3d"
import "unified:physics"
import "unified:sim"

// Shape categories (filter bits) and user material ids (reported by ray casts).
CAT_STATIC :: u64(1 << 0)
CAT_CRATE :: u64(1 << 1)
CAT_BARREL :: u64(1 << 2)
CAT_PLAYER :: u64(1 << 3)
MAT_ITEM_BASE :: u64(1000) // item i -> 1000 + i

World :: struct {
	phys:    ^physics.World,
	scratch: Scratch,
	extras:  [1]sim.Extra,
}

Game :: sim.Game(State, Input, World, MAX_PLAYERS)
Sim :: sim.Sim(State, Input, World, MAX_PLAYERS)

Event_Kind :: enum u16 {
	Player_Died,
	Player_Respawned,
	Enemy_Died,
	Barrel_Exploded,
	Gem_Collected,
	Level_Up,
	Match_Started,
	Match_Over,
	Player_Joined,
	Player_Left,
}

EVENT_NAMES := []string {
	"player_died",
	"player_respawned",
	"enemy_died",
	"barrel_exploded",
	"gem_collected",
	"level_up",
	"match_started",
	"match_over",
	"player_joined",
	"player_left",
}

GAME := Game {
	name = "survivor",
	tick_hz = TICK_HZ,
	world_create = world_create,
	world_destroy = world_destroy,
	extras = proc(w: ^World) -> []sim.Extra {return w.extras[:]},
	init = init,
	tick = tick,
	event_names = EVENT_NAMES,
}

PLAYER_START := [MAX_PLAYERS][3]f32{{4, 1, 4}, {-4, 1, 4}, {4, 1, -4}, {-4, 1, -4}}

item_position :: proc(i: int) -> [3]f32 {
	return {f32(i % 8) * 4 - 14, 1, f32(i / 8) * 4 - 8}
}

item_kind :: proc(i: int) -> Item_Kind {
	return i % 5 == 2 ? .Barrel : .Crate
}

body_id :: proc(w: ^World, r: Body_Ref) -> b3.BodyId {
	return physics.body_id(w.phys, r)
}

@(private)
add_static_box :: proc(w: ^World, pos: [3]f32, half: [3]f32) {
	bd := b3.DefaultBodyDef()
	bd.position = physics.v3(pos)
	body := b3.CreateBody(w.phys.id, &bd)
	sd := b3.DefaultShapeDef()
	sd.filter.categoryBits = CAT_STATIC
	hull := b3.MakeBoxHull(half.x, half.y, half.z)
	b3.CreateHullShape(body, &sd, &hull.base)
}

// Creates the body of item i (a crate or a barrel) at its grid spot.
create_item_body :: proc(w: ^World, i: int) -> Body_Ref {
	bd := b3.DefaultBodyDef()
	bd.type = .dynamicBody
	bd.position = physics.v3(item_position(i))
	body := b3.CreateBody(w.phys.id, &bd)
	sd := b3.DefaultShapeDef()
	sd.density = 1
	sd.baseMaterial.userMaterialId = MAT_ITEM_BASE + u64(i)
	if item_kind(i) == .Barrel {
		sd.filter.categoryBits = CAT_BARREL
		capsule := b3.Capsule{{0, -0.3, 0}, {0, 0.3, 0}, 0.4}
		b3.CreateCapsuleShape(body, &sd, &capsule)
	} else {
		sd.filter.categoryBits = CAT_CRATE
		hull := b3.MakeBoxHull(0.5, 0.5, 0.5)
		b3.CreateHullShape(body, &sd, &hull.base)
	}
	return physics.ref_of(body)
}

create_player_body :: proc(w: ^World, p: int) -> Body_Ref {
	bd := b3.DefaultBodyDef()
	bd.type = .dynamicBody
	bd.position = physics.v3(PLAYER_START[p])
	bd.motionLocks.angularX = true
	bd.motionLocks.angularY = true
	bd.motionLocks.angularZ = true
	bd.enableSleep = false
	body := b3.CreateBody(w.phys.id, &bd)
	sd := b3.DefaultShapeDef()
	sd.filter.categoryBits = CAT_PLAYER
	capsule := b3.Capsule{{0, -0.45, 0}, {0, 0.45, 0}, 0.45}
	b3.CreateCapsuleShape(body, &sd, &capsule)
	return physics.ref_of(body)
}

destroy_body :: proc(w: ^World, r: ^Body_Ref) {
	physics.destroy_body(w.phys, r)
}

// The physics world with its static geometry (GAME.md creation order: ground, walls, pillars).
world_create :: proc(seed: u64) -> ^World {
	w := new(World)
	w.phys = physics.create()
	w.extras[0] = physics.extra(w.phys, State)
	add_static_box(w, {0, -0.5, 0}, {32, 0.5, 32}) // ground
	add_static_box(w, {30.5, 1.5, 0}, {0.5, 1.5, 31}) // walls: inner faces at x, z = ±30
	add_static_box(w, {-30.5, 1.5, 0}, {0.5, 1.5, 31})
	add_static_box(w, {0, 1.5, 30.5}, {31, 1.5, 0.5})
	add_static_box(w, {0, 1.5, -30.5}, {31, 1.5, 0.5})
	for k in 0 ..< 8 {
		add_static_box(w, {14 * RING_C[k], 1.5, 14 * RING_S[k]}, {1, 1.5, 1})
	}
	return w
}

world_destroy :: proc(w: ^World) {
	physics.destroy(w.phys)
	free(w)
}

// The tick-0 state: items with their bodies; players join when they are first present.
init :: proc(s: ^State, w: ^World, seed: u64) {
	s.seed = u32(seed)
	s.rng = sim.rng_seed(seed)
	s.enemy_cap = MAX_ENEMIES
	for i in 0 ..< ITEM_COUNT {
		it := &s.items[i]
		it.kind = item_kind(i)
		it.alive = true
		it.hp = it.kind == .Barrel ? BARREL_HP : 0
		it.body = create_item_body(w, i)
	}
	for p in 0 ..< MAX_PLAYERS {
		pl := &s.players[p]
		pl.fire_interval = 20
		pl.speed = 6
		pl.pos = PLAYER_START[p]
	}
}

player_activate :: proc(s: ^State, w: ^World, p: int) {
	s.players[p].active = true
	player_spawn(s, w, p)
}

player_spawn :: proc(s: ^State, w: ^World, p: int) {
	pl := &s.players[p]
	pl.alive = true
	pl.hp = PLAYER_HP
	pl.respawn = 0
	pl.pos = PLAYER_START[p]
	pl.body = create_player_body(w, p)
}

// The player leaves: body gone, progress reset (a rejoin starts fresh).
player_deactivate :: proc(s: ^State, w: ^World, p: int) {
	pl := &s.players[p]
	destroy_body(w, &pl.body)
	pl^ = {
		fire_interval = 20,
		speed         = 6,
		pos           = PLAYER_START[p],
	}
}
