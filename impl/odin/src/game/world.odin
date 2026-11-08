// The Box3D side of the game: world construction (GAME.md "World", in creation order), body
// creation for items and players, and body-ref helpers. The Box3D world is the only game state
// outside the block.
package game

import "core:sync"

import b3 "../box3d"

// Shape categories (filter bits) and user material ids (reported by ray casts).
CAT_STATIC :: u64(1 << 0)
CAT_CRATE :: u64(1 << 1)
CAT_BARREL :: u64(1 << 2)
CAT_PLAYER :: u64(1 << 3)
MAT_ITEM_BASE :: u64(1000) // item i -> 1000 + i

Physics :: struct {
	world: b3.WorldId,
	cache: ^b3.WorldStateCache,
}

// b3CreateWorld/b3DestroyWorld scan and modify Box3D's global world table and lazily initialise its
// contact registers, so worlds created from several threads (session clients) are serialised.
@(private)
world_mutex: sync.Mutex

PLAYER_START := [MAX_PLAYERS][3]f32{{4, 1, 4}, {-4, 1, 4}, {4, 1, -4}, {-4, 1, -4}}

item_position :: proc(i: int) -> [3]f32 {
	return {f32(i % 8) * 4 - 14, 1, f32(i / 8) * 4 - 8}
}

item_kind :: proc(i: int) -> Item_Kind {
	return i % 5 == 2 ? .Barrel : .Crate
}

body_id :: proc(ph: ^Physics, r: Body_Ref) -> b3.BodyId {
	return {index1 = r.index1, world0 = ph.world.index1 - 1, generation = r.generation}
}

body_ref :: proc(id: b3.BodyId) -> Body_Ref {
	return {index1 = id.index1, generation = id.generation}
}

@(private)
v3 :: proc(v: [3]f32) -> b3.Vec3 {
	return {v.x, v.y, v.z}
}

@(private)
add_static_box :: proc(ph: ^Physics, pos: [3]f32, half: [3]f32) {
	bd := b3.DefaultBodyDef()
	bd.position = v3(pos)
	body := b3.CreateBody(ph.world, &bd)
	sd := b3.DefaultShapeDef()
	sd.filter.categoryBits = CAT_STATIC
	hull := b3.MakeBoxHull(half.x, half.y, half.z)
	b3.CreateHullShape(body, &sd, &hull.base)
}

// Creates the body of item i (a crate or a barrel) at its grid spot.
create_item_body :: proc(ph: ^Physics, i: int) -> Body_Ref {
	bd := b3.DefaultBodyDef()
	bd.type = .dynamicBody
	bd.position = v3(item_position(i))
	body := b3.CreateBody(ph.world, &bd)
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
	return body_ref(body)
}

create_player_body :: proc(ph: ^Physics, p: int) -> Body_Ref {
	bd := b3.DefaultBodyDef()
	bd.type = .dynamicBody
	bd.position = v3(PLAYER_START[p])
	bd.motionLocks.angularX = true
	bd.motionLocks.angularY = true
	bd.motionLocks.angularZ = true
	bd.enableSleep = false
	body := b3.CreateBody(ph.world, &bd)
	sd := b3.DefaultShapeDef()
	sd.filter.categoryBits = CAT_PLAYER
	capsule := b3.Capsule{{0, -0.45, 0}, {0, 0.45, 0}, 0.45}
	b3.CreateCapsuleShape(body, &sd, &capsule)
	return body_ref(body)
}

destroy_body :: proc(ph: ^Physics, r: ^Body_Ref) {
	b3.DestroyBody(body_id(ph, r^))
	r^ = {}
}

// Builds the world and the initial state for `players` active players (GAME.md creation order).
world_create :: proc(s: ^State, ph: ^Physics, seed: u32, players: int) {
	assert(players >= 0 && players <= MAX_PLAYERS)
	s^ = {}
	s.seed = seed
	s.rng = seed == 0 ? 1 : seed
	s.enemy_cap = MAX_ENEMIES
	pool_init(&s.enemies)
	pool_init(&s.projectiles)
	pool_init(&s.gems)

	{
		sync.guard(&world_mutex)
		wd := b3.DefaultWorldDef()
		wd.workerCount = 1
		ph.world = b3.CreateWorld(&wd)
		ph.cache = b3.CreateWorldStateCache()
	}

	add_static_box(ph, {0, -0.5, 0}, {32, 0.5, 32}) // ground
	add_static_box(ph, {30.5, 1.5, 0}, {0.5, 1.5, 31}) // walls: inner faces at x, z = ±30
	add_static_box(ph, {-30.5, 1.5, 0}, {0.5, 1.5, 31})
	add_static_box(ph, {0, 1.5, 30.5}, {31, 1.5, 0.5})
	add_static_box(ph, {0, 1.5, -30.5}, {31, 1.5, 0.5})
	for k in 0 ..< 8 {
		add_static_box(ph, {14 * RING_C[k], 1.5, 14 * RING_S[k]}, {1, 1.5, 1})
	}
	for i in 0 ..< ITEM_COUNT {
		it := &s.items[i]
		it.kind = item_kind(i)
		it.alive = true
		it.hp = it.kind == .Barrel ? BARREL_HP : 0
		it.body = create_item_body(ph, i)
	}
	for p in 0 ..< MAX_PLAYERS {
		pl := &s.players[p]
		pl.fire_interval = 20
		pl.speed = 6
		pl.pos = PLAYER_START[p]
		if p < players {
			player_activate(s, ph, p)
		}
	}
}

world_destroy :: proc(ph: ^Physics) {
	sync.guard(&world_mutex)
	b3.DestroyWorldStateCache(ph.cache)
	b3.DestroyWorld(ph.world)
	ph^ = {}
}

player_activate :: proc(s: ^State, ph: ^Physics, p: int) {
	pl := &s.players[p]
	pl.active = true
	player_spawn(s, ph, p)
}

player_spawn :: proc(s: ^State, ph: ^Physics, p: int) {
	pl := &s.players[p]
	pl.alive = true
	pl.hp = PLAYER_HP
	pl.respawn = 0
	pl.pos = PLAYER_START[p]
	pl.body = create_player_body(ph, p)
}
