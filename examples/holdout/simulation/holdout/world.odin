package holdout

import "unified:level"
import "unified:nav"
import "unified:physics"
import "unified:sim"

// Shape categories (filter bits): every hit names the category of the shape it struck, and the body's tag says whose
// it is (a player's player_key, an enemy's handle_key).
CAT_LEVEL :: u64(1 << 0)
CAT_PLAYER :: u64(1 << 1)
CAT_CORE :: u64(1 << 2) // the level's Core body (its unified_category)
CAT_ENEMY :: u64(1 << 3)
CAT_HEAD :: u64(1 << 4) // an enemy's head: a rifle hit there does HEADSHOT_MULT
CAT_GRENADE :: u64(1 << 5)

MAX_GATES :: 4
MAX_FIELDS :: 8 // memoized fields: one per player chased, the core, a few to spare

// The game's levels (GAME.levels' order): the one yard.
Level_Id :: enum u8 {
	Yard,
}

// The world outside the block: the physics world, the yard's navigation mesh with its memo of fields (a pure function
// of the mesh and a goal: src/sim/README.md, World), what the sim reads from the yard's markers, and per-tick scratch.
World :: struct {
	phys:          ^physics.World,
	mesh:          nav.Mesh,
	fields:        nav.Fields,
	agent:         level.Nav_Agent, // what the mesh was baked for
	spawns:        [PLAYERS][3]f32, // by slot: the spawn markers, in order
	gates:         [MAX_GATES][3]f32, // the gate markers, in order: where waves come in
	gate_count:    int,
	core:          [3]f32, // the core marker: the foot of the core's middle
	core_poly:     nav.Poly, // the mesh polygon nearest the core, the enemies' goal when they chase no one
	character_def: physics.Character_Def,
	grid:          Enemy_Grid, // scratch: the alive enemies, rebuilt each tick before separation
	overlaps:      [dynamic]physics.Overlap, // scratch
}

// Builds the world from the yard: its static geometry (physics), its navigation mesh, and its markers.
world_create :: proc(seed: u64, levels: []sim.Level_File, _: sim.No_Setup) -> ^World {
	world := new(World)
	world.character_def = physics.CHARACTER_DEFAULT
	world.character_def.radius = PLAYER_RADIUS
	world.character_def.half_height = PLAYER_HALF_HEIGHT
	world.character_def.category = CAT_PLAYER
	world.character_def.max_speed = WALK_SPEED
	problem: string
	world.phys, problem = physics.create_with_levels({tick_hz = TICK_HZ}, levels, CAT_LEVEL)
	assert(problem == "", problem)
	yard := physics.level_data(world.phys, Level_Id.Yard)
	err: nav.Build_Error
	world.mesh, err = nav.build(yard.nav_vertices, yard.nav_polygons)
	assert(err == .None, "holdout: the yard's navigation mesh doesn't build (bake it: uni bake holdout --nav)")
	world.fields = nav.fields_make(&world.mesh, MAX_FIELDS)
	world.agent = yard.nav_agent
	spawns := 0
	for &marker in yard.markers {
		switch marker.kind {
		case "spawn":
			assert(spawns < PLAYERS, "holdout: more spawn markers than players")
			world.spawns[spawns] = marker.pos
			spawns += 1
		case "gate":
			assert(world.gate_count < MAX_GATES, "holdout: too many gates")
			world.gates[world.gate_count] = marker.pos
			world.gate_count += 1
		case "core":
			world.core = marker.pos
		}
	}
	assert(spawns == PLAYERS && world.gate_count > 0, "holdout: the yard needs a spawn per slot and a gate")
	world.core_poly, _ = nav.nearest(&world.mesh, world.core, CORE_HALF + 3)
	assert(world.core_poly != nav.NO_POLY, "holdout: no navigation beside the core")
	return world
}

world_destroy :: proc(world: ^World) {
	physics.destroy(world.phys)
	nav.fields_destroy(&world.fields)
	nav.destroy(&world.mesh)
	delete(world.overlaps)
	free(world)
}

// The block's view of the physics world: every body rolls back with the state.
extra :: proc(world: ^World) -> sim.Extra {
	return physics.extra(world.phys, State)
}

// The run starts in the lobby, in the yard.
init :: proc(t: ^Tick) {
	physics.level_change(t, t.world.phys, Level_Id.Yard)
	t.state.core_hp = CORE_HP
}
