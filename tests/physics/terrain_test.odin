// Dynamic bodies on level meshes and height fields (src/level/README.md, Authoring): the exporter's 3D fixture
// (tests/godot/levels/shapes_3d.tscn) as a game's level, crates riding its conveyor deck (a mesh) and balls rolling
// down its hill (a height field), through the sync-test and a late join.
package test_physics

import "core:testing"

import "unified:level"
import "unified:physics"
import "unified:sim"

Terrain :: struct {
	crates:  [2]physics.Body_Ref,
	balls:   [3]physics.Body_Ref,
	players: sim.Players(u32, sim.No_Profile, Field_Input, 2),
}

Terrain_World :: struct {
	phys:  ^physics.World,
	level: level.Level,
}

Terrain_Game :: sim.Game(
	Terrain,
	Field_Input,
	Terrain_World,
	Library_Events,
	sim.No_Commands,
	sim.No_Setup,
	sim.No_Profile,
	2,
)
Terrain_Tick :: sim.Tick(Terrain_Game)

TERRAIN := Terrain_Game {
	name = "terrain",
	version = "1",
	tick_hz = HZ,
	content = #load("../godot/levels/shapes_3d.level"),
	world_create = proc(seed: u64, content: []u8, _: sim.No_Setup) -> ^Terrain_World {
		terrain := new(Terrain_World)
		problem: string
		terrain.phys, terrain.level, problem = physics.create_with_level({tick_hz = HZ}, content)
		assert(problem == "", problem)
		return terrain
	},
	world_destroy = proc(terrain: ^Terrain_World) {
		physics.destroy_with_level(terrain.phys, &terrain.level)
		free(terrain)
	},
	extra = proc(terrain: ^Terrain_World) -> sim.Extra {return physics.extra(terrain.phys, Terrain)},
	init = proc(t: ^Terrain_Tick) {
		def := physics.shape_def(CAT_BOX)
		def.density = 1
		for &crate, i in t.state.crates {
			pos := [3]f32{9, 2 + f32(i), f32(i) - 0.5}
			crate, _ = physics.create_box(t.world.phys, physics.body_def(.Dynamic, pos), def, {0.25, 0.25, 0.25})
		}
		for &ball, i in t.state.balls {
			pos := [3]f32{-9.6 + 0.4 * f32(i), 5, 0.4 + 0.4 * f32(i)}
			ball, _ = physics.create_sphere(t.world.phys, physics.body_def(.Dynamic, pos), def, 0.3)
		}
	},
	tick = proc(t: ^Terrain_Tick) {steps(t.world.phys, 1)},
}

TERRAIN_TICKS :: 120

@(test)
terrain_synctest_and_resume :: proc(t: ^testing.T) {
	synctest_and_resume(
		t,
		&TERRAIN,
		5,
		TERRAIN_TICKS,
		proc(tick: u32) -> sim.Inputs(Terrain_Game) {return {present = {0, 1}}},
		after = proc(t: ^testing.T, simulation: ^sim.Sim(Terrain_Game)) {
			world := simulation.world.phys
			// The crates landed on the deck (1 m up) and its conveyor carries them along +x.
			for crate in simulation.state.crates {
				pos := physics.body_position(world, crate)
				testing.expectf(t, near_f32(pos.y, 1.25, 0.02) && pos.x > 9.2 && pos.x < 12, "a crate at %v", pos)
			}
			// The balls hit the hill and rolled off it, never through it or the floor.
			for ball, i in simulation.state.balls {
				pos := physics.body_position(world, ball)
				start := [3]f32{-9.6 + 0.4 * f32(i), 5, 0.4 + 0.4 * f32(i)}
				moved := abs(pos.x - start.x) + abs(pos.z - start.z)
				testing.expectf(t, pos.y > 0.25 && moved > 0.3, "ball %d at %v", i, pos)
			}
		},
	)
}
