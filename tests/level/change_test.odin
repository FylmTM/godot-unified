// The level as state (src/physics/README.md, Levels): a physics game whose two levels change inside its ticks. A
// sync-test rolls back across every change with check_refs after each restore, a portable snapshot resumes in a sim
// whose init built the other level, 4 workers reproduce 1 worker's checksums, and the world doesn't grow from one visit
// of a level to the next.
package test_level

import "base:runtime"
import "core:slice"
import "core:testing"

import "unified:headless"
import "unified:level"
import "unified:physics"
import "unified:sim"

Area :: enum u8 {
	Yard,
	Pit,
}

Pit_Input :: struct {
	push: u8,
	_pad: [3]u8,
}

Pit_Events :: union {
	sim.Event_Player_Joined,
	sim.Event_Player_Left,
}

Pit :: struct {
	crates:  [4]physics.Body_Ref,
	level:   sim.Active_Level(Area),
	changes: u32,
	players: sim.Players(u32, sim.No_Profile, Pit_Input, 2),
}

Pit_World :: struct {
	phys:    ^physics.World,
	workers: i32,
}

Pit_Game :: sim.Game(Pit, Pit_Input, Pit_World, Pit_Events, sim.No_Commands, sim.No_Setup, sim.No_Profile, 2)
Pit_Tick :: sim.Tick(Pit_Game)

CAT_CRATE :: u64(1 << 2)

// The ticks that change level (then every PIT_EVERY ticks): two in a row, so a rollback re-runs both.
PIT_CHANGES :: [?]u32{40, 90, 91}
PIT_EVERY :: 150

// The two levels, generated (encode) at startup.
pit_levels: [len(Area)]sim.Level_File

@(init)
pit_levels_make :: proc "contextless" () {
	context = runtime.default_context()
	// The yard: a floor, four posts and a ramp mesh; the pit: a lower floor, a height field and a ball, its floor
	// tilted so the crates slide.
	posts := []level.Shape {
		{kind = .Box, rot = {0, 0, 0, 1}, half = {20, 0.5, 20}},
		{kind = .Box, pos = {-4, 1.5, -4}, rot = {0, 0, 0, 1}, half = {0.5, 1, 0.5}},
		{kind = .Box, pos = {4, 1.5, -4}, rot = {0, 0, 0, 1}, half = {0.5, 1, 0.5}},
		{kind = .Hull, rot = {0, 0, 0, 1}, points = {{-4, 0.5, 4}, {-3, 0.5, 4}, {-4, 0.5, 5}, {-4, 2, 4}}},
		{
			kind      = .Mesh,
			rot       = {0, 0, 0, 1},
			points    = {{2, 0.5, 2}, {6, 2.5, 2}, {6, 2.5, 6}, {2, 0.5, 6}},
			triangles = {{0, 2, 1}, {0, 3, 2}},
		},
	}
	pit := []level.Shape {
		{kind = .Box, rot = {0, 0.0499792, 0, 0.99875}, half = {20, 0.5, 20}},
		{kind = .Sphere, pos = {0, 1, 3}, rot = {0, 0, 0, 1}, radius = 1},
		{
			kind    = .Height_Field,
			pos     = {-6, 0.5, -6},
			rot     = {0, 0, 0, 1},
			count_x = 3,
			count_z = 3,
			scale   = {3, 1, 3},
			heights = {0, 0, 0, 0, 1.5, 0, 0, 0, 0},
		},
	}
	yard_bodies := []level.Body {
		{name = "yard", pos = {0, -0.5, 0}, rot = {0, 0, 0, 1}, surface = {friction = 0.6}, shapes = posts},
	}
	pit_bodies := []level.Body {
		{
			name = "pit",
			pos = {0, -2, 0},
			rot = {0.0499792, 0, 0, 0.99875},
			surface = {friction = 0.2},
			shapes = pit[:1],
		},
		{
			name = "rocks",
			pos = {0, -2, 0},
			rot = {0, 0, 0, 1},
			surface = {friction = 0.6, material = 3},
			shapes = pit[1:],
		},
	}
	pit_levels[Area.Yard] = {"yard", encode(yard_bodies, nil)}
	pit_levels[Area.Pit] = {"pit", encode(pit_bodies, nil)}
	PIT.levels = pit_levels[:]
}

pit_world_create :: proc(workers: i32, levels: []sim.Level_File) -> ^Pit_World {
	pit_world := new(Pit_World)
	problem: string
	pit_world.phys, problem = physics.create_with_levels({tick_hz = 64, workers = workers}, levels)
	assert(problem == "", problem)
	return pit_world
}

PIT := Pit_Game {
	name = "pit",
	version = "1",
	tick_hz = 64,
	world_create = proc(
		seed: u64,
		levels: []sim.Level_File,
		_: sim.No_Setup,
	) -> ^Pit_World {return pit_world_create(1, levels)},
	world_destroy = proc(pit_world: ^Pit_World) {
		physics.destroy(pit_world.phys)
		free(pit_world)
	},
	extra = proc(pit_world: ^Pit_World) -> sim.Extra {return physics.extra(pit_world.phys, Pit)},
	init = proc(t: ^Pit_Tick) {
		physics.level_change(t, t.world.phys, Area.Yard)
		def := physics.shape_def(CAT_CRATE)
		def.density = 1
		for &crate, i in t.state.crates {
			pos := [3]f32{f32(i) * 1.5 - 2.25, 3, f32(i % 2)}
			crate, _ = physics.create_box(t.world.phys, physics.body_def(.Dynamic, pos), def, {0.3, 0.3, 0.3})
		}
	},
	tick = proc(t: ^Pit_Tick) {
		if pit_changes_at(t.number) {
			physics.level_change(t, t.world.phys, Area.Pit if t.state.level.id == .Yard else Area.Yard)
			t.state.changes += 1
		}
		// A crate that fell off the level is put back above it.
		for crate, i in t.state.crates {
			if physics.body_position(t.world.phys, crate).y < -20 {
				physics.body_set_transform(t.world.phys, crate, {f32(i) * 1.5 - 2.25, 4, 0}, {0, 0, 0, 1})
				physics.body_set_linear_velocity(t.world.phys, crate, {})
			}
		}
		physics.step(t.world.phys)
	},
}

pit_changes_at :: proc(tick: u32) -> bool {
	for change in PIT_CHANGES do if tick == change do return true
	return tick > PIT_CHANGES[len(PIT_CHANGES) - 1] && tick % PIT_EVERY == 0
}

pit_inputs :: proc(tick: u32) -> sim.Inputs(Pit_Game) {
	return {present = {0, 1}}
}

PIT_TICKS :: 620

// Rolls back 8 ticks after every tick, across every change, check_refs after each restore; returns the forward
// checksums.
pit_synctest :: proc(t: ^testing.T, game: ^Pit_Game) -> []u64 {
	run := headless.run_begin(game, 9, window = 8)
	defer headless.run_end(&run)
	for tick in u32(1) ..= PIT_TICKS {
		inputs := pit_inputs(tick)
		headless.run_step(&run, &inputs)
	}
	testing.expectf(t, run.mismatches == 0, "%d re-simulated ticks differ, first %d", run.mismatches, run.first_tick)
	testing.expectf(t, run.check == "", "after restoring tick %d: %s", run.check_tick, run.check)
	changes := u32(0)
	for tick in u32(1) ..= PIT_TICKS do changes += u32(pit_changes_at(tick))
	testing.expect_value(t, run.simulation.state.changes, changes)
	forward := make([]u64, len(run.forward), context.temp_allocator)
	copy(forward, run.forward[:])
	return forward
}

@(test)
level_change_rolls_back :: proc(t: ^testing.T) {
	one_worker := pit_synctest(t, &PIT)
	four := PIT
	four.world_create = proc(seed: u64, levels: []sim.Level_File, _: sim.No_Setup) -> ^Pit_World {
		return pit_world_create(4, levels)
	}
	four_workers := pit_synctest(t, &four)
	testing.expect(t, slice.equal(one_worker, four_workers), "4 workers: checksums differ from 1 worker's")
}

// A late joiner's sim enters the yard in init, then loads a snapshot taken in the pit: it runs on bit-exact through the
// next changes.
@(test)
level_change_crosses_a_snapshot :: proc(t: ^testing.T) {
	session := sim.create(&PIT, 9)
	defer sim.destroy(session)
	for tick in u32(1) ..= 100 {
		inputs := pit_inputs(tick)
		sim.step(session, &inputs)
	}
	testing.expect_value(t, session.state.level, sim.Active_Level(Area){since = 91, id = .Pit})
	for tick in u32(101) ..= 140 {
		inputs := pit_inputs(tick)
		sim.step(session, &inputs)
	}
	snap := sim.snapshot_encode(session, 140)
	defer delete(snap)
	joiner, err := sim.from_snapshot(&PIT, snap)
	testing.expect_value(t, err, sim.Snap_Error.None)
	if joiner == nil do return
	defer sim.destroy(joiner)
	testing.expect_value(t, physics.check_refs(joiner.world.phys, &joiner.state), "")
	for tick in u32(141) ..= 400 {
		inputs, joiner_inputs := pit_inputs(tick), pit_inputs(tick)
		sim.step(session, &inputs)
		sim.step(joiner, &joiner_inputs)
		testing.expect_value(t, sim.checksum(joiner), sim.checksum(session))
	}
	testing.expect_value(t, joiner.state.level.id, session.state.level.id)
}

// The world holds the active level only: its static bodies are the active level's, by the body table, and back in a
// level the body table is as long as on the first visit (destroyed bodies' indices are reused).
@(test)
level_change_does_not_grow :: proc(t: ^testing.T) {
	session := sim.create(&PIT, 9)
	defer sim.destroy(session)
	yard_sizes: [dynamic]int // the body table's length in the yard
	defer delete(yard_sizes)
	tick := u32(0)
	for visit in 0 ..< 6 {
		for {
			tick += 1
			inputs := pit_inputs(tick)
			sim.step(session, &inputs)
			if pit_changes_at(tick + 1) do break
		}
		level_bodies := 0
		for entry in session.world.phys.bodies do level_bodies += int(.Level in entry.flags)
		testing.expect_value(t, level_bodies, 1 if session.state.level.id == .Yard else 3) // the pit's field has a body
		if session.state.level.id == .Yard && visit > 0 do append(&yard_sizes, len(session.world.phys.bodies))
	}
	testing.expect(t, len(yard_sizes) >= 2)
	for size in yard_sizes do testing.expectf(t, size == yard_sizes[0], "the yard's world grew: %v", yard_sizes)
}

// check_refs knows the level's bodies from orphans: one whose level flag is cleared is an orphan, and a joint ref to a
// body of the level left behind is stale after a change.
@(test)
level_change_check_refs :: proc(t: ^testing.T) {
	session := sim.create(&PIT, 9)
	defer sim.destroy(session)
	world := session.world.phys
	testing.expect_value(t, physics.check_refs(world, &session.state), "")
	for &entry in world.bodies {
		if .Level in entry.flags do entry.flags -= {.Level}
	}
	testing.expect(t, physics.check_refs(world, &session.state) != "", "a level body without its flag is an orphan")
}
