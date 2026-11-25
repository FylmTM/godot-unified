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
		// One compound each (the yard's hulls and mesh; the pit's floor and ball), and the pit's field on a body of its own.
		testing.expect_value(t, level_bodies, 1 if session.state.level.id == .Yard else 2)
		if session.state.level.id == .Yard && visit > 0 do append(&yard_sizes, len(session.world.phys.bodies))
	}
	testing.expect(t, len(yard_sizes) >= 2)
	for size in yard_sizes do testing.expectf(t, size == yard_sizes[0], "the yard's world grew: %v", yard_sizes)
}

// check_refs knows the level's bodies from orphans: one whose level flag is cleared is an orphan (a joint left on the
// old level: a_joint_left_on_the_old_level_is_stale).
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

// level_change's contract: a joint ref left behind goes stale (refs are weak). A weld from a crate to a level body,
// kept in the block across a change, is stale after it: joint_valid says so, check_refs and a snapshot load take it,
// destroying it is safe, and an unguarded use asserts (an_unguarded_stale_joint_use_asserts).
Hang :: struct {
	crate:   physics.Body_Ref,
	weld:    physics.Weld_Joint_Ref,
	level:   sim.Active_Level(Area),
	_pad:    u32,
	players: sim.Players(u32, sim.No_Profile, Pit_Input, 2),
}

Hang_Game :: sim.Game(Hang, Pit_Input, Pit_World, Pit_Events, sim.No_Commands, sim.No_Setup, sim.No_Profile, 2)
Hang_Tick :: sim.Tick(Hang_Game)

// A crate welded to the yard's floor at tick 5, the level changed to the pit at tick 10.
hang_game :: proc() -> Hang_Game {
	return Hang_Game {
		name = "hang",
		version = "1",
		tick_hz = 64,
		world_create = proc(seed: u64, levels: []sim.Level_File, _: sim.No_Setup) -> ^Pit_World {
			return pit_world_create(1, levels)
		},
		world_destroy = PIT.world_destroy,
		extra = proc(pit_world: ^Pit_World) -> sim.Extra {return physics.extra(pit_world.phys, Hang)},
		init = proc(t: ^Hang_Tick) {
			physics.level_change(t, t.world.phys, Area.Yard)
			def := physics.shape_def(CAT_CRATE)
			def.density = 1
			t.state.crate, _ = physics.create_box(
				t.world.phys,
				physics.body_def(.Dynamic, {0, 1, 0}),
				def,
				{0.3, 0.3, 0.3},
			)
		},
		tick = proc(t: ^Hang_Tick) {
			world := t.world.phys
			if t.number == 5 {
				hit, ok := physics.world_cast_ray_closest(world, {10, 10, 10}, {0, -20, 0})
				assert(ok, "no floor under (10, 10)")
				t.state.weld = physics.create_weld_joint(
					world,
					physics.link(t.state.crate),
					hit.body,
					physics.default_weld_joint_def(),
				)
			}
			if t.number == 10 do physics.level_change(t, world, Area.Pit)
			physics.step(world)
		},
		levels = pit_levels[:],
	}
}

@(test)
a_joint_left_on_the_old_level_is_stale :: proc(t: ^testing.T) {
	game := hang_game()
	session := sim.create(&game, 3)
	defer sim.destroy(session)
	world := session.world.phys
	inputs: sim.Inputs(Hang_Game)
	for _ in u32(1) ..= 9 do sim.step(session, &inputs)
	testing.expect_value(t, physics.check_refs(world, &session.state), "")
	testing.expect(t, physics.joint_valid(world, session.state.weld.joint))
	sim.step(session, &inputs)
	testing.expect(t, !physics.joint_valid(world, session.state.weld.joint))
	testing.expect(t, session.state.weld != {}, "the block keeps the stale ref")
	testing.expect_value(t, physics.check_refs(world, &session.state), "")
	snap := sim.snapshot_encode(session, session.tick)
	defer delete(snap)
	joiner, err := sim.from_snapshot(&game, snap)
	testing.expect_value(t, err, sim.Snap_Error.None)
	if joiner != nil do sim.destroy(joiner)
	physics.destroy_joint(world, &session.state.weld.joint) // safe on the stale ref
	testing.expect_value(t, session.state.weld, physics.Weld_Joint_Ref{})
	testing.expect_value(t, physics.check_refs(world, &session.state), "")
}

// A stale joint ref used without joint_valid first asserts, naming the cause, rather than reaching Box3D's unchecked
// release library (which would set whatever joint sits at that index now).
@(test)
an_unguarded_stale_joint_use_asserts :: proc(t: ^testing.T) {
	context.allocator = runtime.default_allocator() // the assert ends the test before the session is freed: untracked
	game := hang_game()
	session := sim.create(&game, 3)
	inputs: sim.Inputs(Hang_Game)
	for _ in u32(1) ..= 10 do sim.step(session, &inputs)
	testing.expect_assert_message(
		t,
		"physics: a stale joint ref (its joint is gone, destroyed with one of its bodies): check physics.joint_valid first",
	)
	physics.weld_joint_set_linear_hertz(session.world.phys, session.state.weld, 5)
}

// "The world holds the active level only", with no dynamic body at all: only the level's statics, flipped every 4
// ticks; the save and the image of a visit to the yard stay the size of the first one's.
@(test)
a_world_of_level_statics_only_does_not_grow :: proc(t: ^testing.T) {
	game := PIT
	game.name = "pit static"
	game.init = proc(t: ^Pit_Tick) {
		physics.level_change(t, t.world.phys, Area.Yard)
	}
	game.tick = proc(t: ^Pit_Tick) {
		if t.number % 4 == 0 {
			physics.level_change(t, t.world.phys, Area.Pit if t.state.level.id == .Yard else Area.Yard)
		}
		physics.step(t.world.phys)
	}
	session := sim.create(&game, 9)
	defer sim.destroy(session)
	first_save, first_image := 0, 0
	for tick in u32(1) ..= 8 * 300 {
		inputs := pit_inputs(tick)
		sim.step(session, &inputs)
		if tick % 8 != 2 do continue
		save, image := sim.save_size(session), sim.snapshot_size(session)
		if tick / 8 == 1 do first_save, first_image = save, image
		if tick / 8 > 1 && (save != first_save || image != first_image) {
			testing.expectf(
				t,
				false,
				"visit %d: save %d B (first %d), image %d B (first %d)",
				tick / 8 + 1,
				save,
				first_save,
				image,
				first_image,
			)
			return
		}
	}
}

// A crafted body table cannot crash a joiner: physics' load refuses a table that disagrees with the Box3D image it
// comes with (a block-owned crate claimed by the level, a level entry where Box3D has no body), unknown flag bits,
// non-zero padding, a dead entry that isn't zero and a table cut short of Box3D's bodies, and puts the world back as
// it was.
@(test)
a_crafted_body_table_is_refused_at_load :: proc(t: ^testing.T) {
	session := sim.create(&PIT, 9)
	defer sim.destroy(session)
	for tick in u32(1) ..= 30 {
		inputs := pit_inputs(tick)
		sim.step(session, &inputs)
	}
	world := session.world.phys
	extra := physics.extra(world, Pit)
	honest := image_of(session)
	before := sim.checksum(session)
	Craft :: enum {
		Crate_Claimed,
		Ghost_Level_Body,
		Unknown_Flag,
		Padding,
		Dead_Not_Zero,
		Truncated,
	}
	for craft in Craft {
		entries := make([]physics.Body_Entry, 64, context.temp_allocator)
		copy(entries, world.bodies[:])
		crate := session.state.crates[0]
		switch craft {
		case .Crate_Claimed:
			entries[crate.index1 - 1].flags += {.Level}
			entries[crate.index1 - 1].generation = crate.generation
		case .Ghost_Level_Body:
			entries[63] = {
				flags      = {.Alive, .Level},
				generation = 7,
			}
		case .Unknown_Flag:
			(^u8)(&entries[crate.index1 - 1].flags)^ |= 0x80
		case .Padding:
			entries[crate.index1 - 1]._pad2[1] = 1
		case .Dead_Not_Zero:
			entries[63].tag = 5
		case .Truncated:
			entries = entries[:crate.index1 - 1] // the crate and every body after it left out
		}
		crafted := make([dynamic]u8, context.temp_allocator)
		append(&crafted, ..honest[:])
		append(&crafted, ..([^]u8)(raw_data(entries))[:len(entries) * size_of(physics.Body_Entry)])
		testing.expectf(t, !extra.load(extra.data, crafted[:]), "%v: loaded", craft)
		testing.expectf(t, sim.checksum(session) == before, "%v: the world was not put back", craft)
	}
	honest_table := make([dynamic]u8, context.temp_allocator)
	append(&honest_table, ..honest[:])
	append(&honest_table, ..([^]u8)(raw_data(world.bodies))[:len(world.bodies) * size_of(physics.Body_Entry)])
	testing.expect(t, extra.load(extra.data, honest_table[:]), "the honest table loads")
}

// The honest part of a portable physics image of the session's current tick: Box3D's image with its size first, the
// body table after it left out (for a test to append its own).
@(private = "file")
image_of :: proc(session: ^sim.Sim(Pit_Game)) -> []u8 {
	extra := physics.extra(session.world.phys, Pit)
	image := extra.image(extra.data, int(session.tick % u32(len(session.ring))), true)
	size := int((^u32le)(raw_data(image))^)
	out := make([dynamic]u8, context.temp_allocator)
	append(&out, ..image[:4 + size])
	return out[:]
}

// ... and a crafted snapshot whose digest is right is refused whole by from_snapshot (Extra_Rejected): a body table
// grown to a level entry Box3D never made, a Body_Ref in the block naming a body Box3D never made (the extra's check,
// run at every load), or a body table cut short of Box3D's bodies (its next teleport would index past the table).
@(test)
a_crafted_snapshot_is_refused_by_from_snapshot :: proc(t: ^testing.T) {
	source := sim.create(&PIT, 9)
	for tick in u32(1) ..= 20 {
		inputs := pit_inputs(tick)
		sim.step(source, &inputs)
	}
	snap := sim.snapshot_encode(source, 20)
	sim.destroy(source)
	defer delete(snap)
	block_at := sim.SNAP_HEADER + 2 // no Setup: its length only
	image_len_at := block_at + size_of(Pit)
	image_len := int((^u32le)(&snap[image_len_at])^)
	testing.expect_value(t, image_len_at + 4 + image_len, len(snap))
	Craft :: enum {
		Ghost_Level_Entry,
		Ghost_Ref,
		Short_Table, // the body table cut to the anchor's entry alone
	}
	for craft in Craft {
		crafted := make([dynamic]u8, context.temp_allocator)
		append(&crafted, ..snap[:])
		extra_bytes := 0
		switch craft {
		case .Ghost_Ref:
			crate := (^physics.Body_Ref)(&crafted[block_at + int(offset_of(Pit, crates))])
			crate.index1 = 150_000
		case .Ghost_Level_Entry:
			extra_entries := 64
			for i in 0 ..< extra_entries {
				entry: physics.Body_Entry
				if i == extra_entries - 1 do entry = {
					flags      = {.Alive, .Level},
					generation = 7,
				}
				bytes := transmute([size_of(physics.Body_Entry)]u8)entry
				append(&crafted, ..bytes[:])
			}
			extra_bytes = extra_entries * size_of(physics.Body_Entry)
		case .Short_Table:
			box3d_size := int((^u32le)(&crafted[image_len_at + 4])^)
			table_bytes := image_len - 4 - box3d_size
			testing.expect(t, table_bytes > 2 * size_of(physics.Body_Entry))
			extra_bytes = size_of(physics.Body_Entry) - table_bytes
			resize(&crafted, len(crafted) + extra_bytes)
		}
		(^u32le)(&crafted[image_len_at])^ = u32le(image_len + extra_bytes)
		sim.snapshot_seal(crafted[:])
		joiner, err := sim.from_snapshot(&PIT, crafted[:])
		testing.expectf(t, joiner == nil && err == .Extra_Rejected, "%v: %v", craft, err)
		if joiner != nil do sim.destroy(joiner)
	}
}

// A game's own level shape made in a tick: built once in world_create (build_level_shape), created by the tick as
// often as rollbacks re-run it. The world keeps the one mesh BVH, and the sync-test agrees.
Piece :: struct {
	piece:   physics.Body_Ref,
	players: sim.Players(u32, sim.No_Profile, Pit_Input, 1),
}

Piece_World :: struct {
	phys: ^physics.World,
	ramp: physics.Built_Level_Shape,
}

Piece_Game :: sim.Game(Piece, Pit_Input, Piece_World, Pit_Events, sim.No_Commands, sim.No_Setup, sim.No_Profile, 1)

PIECE_RAMP := level.Shape {
	kind      = .Mesh,
	rot       = {0, 0, 0, 1},
	points    = {{0, 0, 0}, {4, 2, 0}, {4, 2, 4}, {0, 0, 4}},
	triangles = {{0, 2, 1}, {0, 3, 2}},
	materials = {{}},
}

@(test)
a_level_shape_made_in_a_tick_is_built_once :: proc(t: ^testing.T) {
	game := Piece_Game {
		name = "piece",
		version = "1",
		tick_hz = 64,
		world_create = proc(_: u64, _: []sim.Level_File, _: sim.No_Setup) -> ^Piece_World {
			piece_world := new(Piece_World)
			piece_world.phys = physics.create({tick_hz = 64})
			ok: bool
			piece_world.ramp, ok = physics.build_level_shape(piece_world.phys, &PIECE_RAMP)
			assert(ok)
			return piece_world
		},
		world_destroy = proc(piece_world: ^Piece_World) {
			physics.destroy(piece_world.phys)
			free(piece_world)
		},
		extra = proc(piece_world: ^Piece_World) -> sim.Extra {return physics.extra(piece_world.phys, Piece)},
		tick = proc(t: ^sim.Tick(Piece_Game)) {
			world := t.world.phys
			if t.number == 10 {
				t.state.piece = physics.create_body(world, physics.body_def(.Static, {0, 0, 0}))
				physics.create_level_shape(world, t.state.piece, physics.default_shape_def(), t.world.ramp)
			}
			physics.step(world)
		},
	}
	run := headless.run_begin(&game, 1, window = 8)
	defer headless.run_end(&run)
	for _ in u32(1) ..= 40 {
		inputs := sim.Inputs(Piece_Game) {
			present = {0},
		}
		headless.run_step(&run, &inputs)
	}
	testing.expect_value(t, run.mismatches, 0)
	testing.expect_value(t, len(run.simulation.world.phys.level_meshes), 1)
	hit, ok := physics.world_cast_ray_closest(run.simulation.world.phys, {2, 10, 2}, {0, -20, 0})
	testing.expect(t, ok && hit.body == physics.link(run.simulation.state.piece), "the ramp is there")
}

// A game with levels whose init enters none would run with no static geometry (everything falls through the floor
// the host shows): its first physics.step says so.
@(test)
a_world_with_levels_steps_only_after_a_level_change :: proc(t: ^testing.T) {
	context.allocator = runtime.default_allocator() // the assert ends the test before the world is freed: untracked
	world := pit_world_create(1, pit_levels[:])
	defer PIT.world_destroy(world)
	testing.expect_assert_message(
		t,
		"physics: the game has levels but its init entered none (physics.level_change(t, world, Level_Id.X))",
	)
	physics.step(world.phys)
}
