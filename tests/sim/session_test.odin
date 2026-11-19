// Setup and Profile: the session's Setup beside the seed (world_create, init, every tick, a copy each), a member's
// Profile in Players from its join tick, read as every peer reads bytes from another machine.
package test_sim

import "core:strings"
import "core:testing"

import "../toy"
import "unified:sim"

Pick_Mode :: enum u8 {
	Calm,
	Wild,
}

Pick_Setup :: struct {
	mode:  Pick_Mode,
	waves: u8,
	loud:  bool,
	_pad:  u8,
	scale: f32,
}

Pick_Kind :: enum u8 {
	Gunner,
	Runner,
	Tank,
}

Pick_Profile :: struct {
	kind: Pick_Kind,
	hue:  u8,
	_pad: [2]u8,
}

Pick_Data :: struct {
	kind:  Pick_Kind, // the Profile's on the tick it arrived
	_pad:  [3]u8,
	ticks: u32,
}

Pick_World :: struct {
	setup: Pick_Setup, // what world_create got
}

Pick_State :: struct {
	players:    sim.Players(Pick_Data, Pick_Profile, toy.Input, 4),
	init_mode:  Pick_Mode,
	tick_mode:  Pick_Mode,
	world_mode: Pick_Mode,
	_pad:       u8,
	written:    u32, // ticks that saw an earlier tick's write to t.setup (never)
}

Pick_Event :: union {
	sim.Event_Player_Joined,
	sim.Event_Player_Left,
}

Pick :: sim.Game(Pick_State, toy.Input, Pick_World, Pick_Event, sim.No_Commands, Pick_Setup, Pick_Profile, 4)

PICK := Pick {
	name = "pick",
	version = "1",
	tick_hz = 64,
	setup = {mode = .Calm, waves = 3},
	world_create = proc(seed: u64, content: []u8, setup: Pick_Setup) -> ^Pick_World {
		world := new(Pick_World)
		world.setup = setup
		return world
	},
	init = proc(t: ^sim.Tick(Pick)) {
		t.state.init_mode = t.setup.mode
	},
	tick = proc(t: ^sim.Tick(Pick)) {
		t.state.tick_mode = t.setup.mode
		t.state.world_mode = t.world.setup.mode
		if t.setup.waves == 99 do t.state.written += 1
		t.setup.waves = 99 // the tick's copy only
		for player in t.player_changes.arrived {
			sim.player_data(t, player).kind = sim.player_profile(t, player).kind
		}
		players := sim.iterate_present(t)
		for data in sim.next(&players) do data.ticks += 1
	},
}

// One tick of the Pick game with `slots` present and these joins ({slot, member} with its Profile).
Pick_Join :: struct {
	slot, member: int,
	profile:      Pick_Profile,
}

pick_step :: proc(simulation: ^sim.Sim(Pick), slots: sim.Slots, joins: ..Pick_Join) {
	inputs: sim.Inputs(Pick)
	inputs.present = slots
	for join in joins do sim.join(&inputs, join.slot, join.member, join.profile)
	sim.step(simulation, &inputs)
}

// The Setup reaches world_create, init and every tick; the game's own when create is given none; a write in tick code
// changes that tick's copy and nothing else.
@(test)
the_setup_reaches_world_init_and_every_tick :: proc(t: ^testing.T) {
	defaulted := sim.create(&PICK, 1)
	defer sim.destroy(defaulted)
	testing.expect_value(t, defaulted.setup, PICK.setup)

	simulation := sim.create(&PICK, 1, Pick_Setup{mode = .Wild, waves = 5, scale = 1.5})
	defer sim.destroy(simulation)
	testing.expect_value(t, simulation.world.setup.mode, Pick_Mode.Wild)
	testing.expect_value(t, simulation.state.init_mode, Pick_Mode.Wild)
	for _ in 0 ..< 5 do pick_step(simulation, {})
	testing.expect_value(t, simulation.state.tick_mode, Pick_Mode.Wild)
	testing.expect_value(t, simulation.state.world_mode, Pick_Mode.Wild)
	testing.expect_value(t, simulation.state.written, 0)
	testing.expect_value(t, simulation.setup.waves, 5)
}

// A member's Profile is in Players on its join tick (the game reads it there: no swap a tick later); a returning
// member brings a new one and keeps its data; an unknown handle reads the zero Profile.
@(test)
a_profile_arrives_with_its_join_and_is_replaced_by_the_next :: proc(t: ^testing.T) {
	simulation := sim.create(&PICK, 2)
	defer sim.destroy(simulation)
	players := &simulation.state.players
	pick_step(simulation, {0, 1}, {0, 11, {kind = .Tank, hue = 4}}, {1, 12, {kind = .Runner}})
	tank, runner := sim.player_in_slot(players, 0), sim.player_in_slot(players, 1)
	testing.expect_value(t, sim.player_profile(players, tank), Pick_Profile{kind = .Tank, hue = 4})
	testing.expect_value(t, sim.player_data(players, tank).kind, Pick_Kind.Tank)
	testing.expect_value(t, sim.player_data(players, runner).kind, Pick_Kind.Runner)
	testing.expect_value(t, sim.player_profile(simulation, runner).kind, Pick_Kind.Runner)
	testing.expect_value(t, sim.player_profile(players, sim.Player{}), Pick_Profile{})

	pick_step(simulation, {1}) // the tank leaves: its Profile stays while it is remembered
	testing.expect_value(t, sim.player_profile(players, tank).kind, Pick_Kind.Tank)
	ticks := sim.player_data(players, tank).ticks
	pick_step(simulation, {1, 2}, {2, 11, {kind = .Gunner, hue = 9}}) // back, as another character
	testing.expect_value(t, sim.player_in_slot(players, 2), tank)
	testing.expect_value(t, sim.player_profile(players, tank), Pick_Profile{kind = .Gunner, hue = 9})
	testing.expect_value(t, sim.player_data(players, tank).ticks, ticks + 1) // its data kept
}

// A Profile from another machine is read the way every peer reads it: an enum outside its values makes it the zero
// Profile, on every peer alike, while the caller's inputs stay as sent; inputs_same tells two Profiles apart beside a
// join record and ignores one beside none.
@(test)
a_malformed_profile_reads_as_the_zero_profile :: proc(t: ^testing.T) {
	a, b := sim.create(&PICK, 3), sim.create(&PICK, 3)
	defer sim.destroy(a)
	defer sim.destroy(b)
	inputs: sim.Inputs(Pick)
	inputs.present = {0}
	sim.join(&inputs, 0, 1, Pick_Profile{kind = .Tank, hue = 7})
	(cast(^u8)&inputs.profiles[0].kind)^ = 77 // no Pick_Kind
	sent := inputs
	sim.step(a, &inputs)
	sim.step(b, &sent)
	player := sim.player_in_slot(a, 0)
	testing.expect_value(t, sim.player_profile(a, player), Pick_Profile{})
	testing.expect_value(t, sim.checksum(a), sim.checksum(b))
	testing.expect_value(t, (cast(^u8)&inputs.profiles[0].kind)^, 77)

	other := inputs
	other.profiles[0].hue = 1
	testing.expect(t, !sim.inputs_same(&inputs, &other), "another Profile beside a join record")
	other = inputs
	other.joins[0] = 0
	same := other
	same.profiles[0] = {}
	testing.expect(t, sim.inputs_same(&other, &same), "a Profile beside no join record means nothing")
}

// game_violation refuses a Setup or Profile that is not a plain struct without padding, one over its limit, and a
// default Setup that does not read as sent; setup_violation says why a session's Setup does not.
@(test)
setups_and_profiles_are_checked_like_commands :: proc(t: ^testing.T) {
	Padded :: struct {
		a: u8,
		b: u32,
	}
	Large :: struct {
		bytes: [sim.SETUP_MAX + 1]u8,
	}
	Fat :: struct {
		bytes: [sim.PROFILE_MAX + 1]u8,
	}
	Fat_State :: struct {
		players: sim.Players(u8, Fat, toy.Input, 2),
	}
	padded := sim.Game(Pick_State, toy.Input, sim.No_World, Pick_Event, sim.No_Commands, Padded, Pick_Profile, 4) {
		name    = "padded",
		tick_hz = 64,
	}
	large := sim.Game(Pick_State, toy.Input, sim.No_World, Pick_Event, sim.No_Commands, Large, Pick_Profile, 4) {
		name    = "large",
		tick_hz = 64,
	}
	fat := sim.Game(Fat_State, toy.Input, sim.No_World, Pick_Event, sim.No_Commands, sim.No_Setup, Fat, 2) {
		name    = "fat",
		tick_hz = 64,
	}
	testing.expect(t, strings.contains(sim.game_violation(&padded), "implicit padding"))
	testing.expect(t, strings.contains(sim.game_violation(&large), "at most 512"))
	testing.expect(t, strings.contains(sim.game_violation(&fat), "at most 64"))
	testing.expect_value(t, sim.game_violation(&PICK), "")

	unread := PICK
	(cast(^u8)&unread.setup.mode)^ = 5
	testing.expect(t, strings.contains(sim.game_violation(&unread), "Game.setup holds an enum"))
	setup := Pick_Setup{}
	(cast(^u8)&setup.loud)^ = 2
	testing.expect(t, strings.contains(sim.setup_violation(&PICK, &setup), "a bool"))
	setup = {}
	(cast(^u32)&setup.scale)^ = 0x7FC0_0000 // a NaN
	testing.expect(t, strings.contains(sim.setup_violation(&PICK, &setup), "not finite"))
	setup = {}
	testing.expect_value(t, sim.setup_violation(&PICK, &setup), "")
}

// Without a Profile the State keeps none: Players' profile field and its pad take no bytes.
@(test)
no_profile_takes_no_bytes :: proc(t: ^testing.T) {
	Without :: sim.Players(u32, sim.No_Profile, toy.Input, 3)
	testing.expect_value(t, offset_of(Without, data), offset_of(Without, profile))
	With :: sim.Players(u32, Pick_Profile, toy.Input, 3)
	testing.expect_value(t, offset_of(With, data) % 8, 0)
	testing.expect_value(t, sim.plain_violation(type_info_of(With)), "")
}
