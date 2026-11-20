// What a game declares: plain data, the unions and tick rate (game_violation), and what compat tells apart.
package test_sim

import "base:intrinsics"
import "core:strings"
import "core:testing"

import "../toy"
import "unified:sim"

Padded :: struct {
	small: u8,
	large: u32,
}

With_Pointer :: struct {
	pointer: ^int,
}

Sized :: struct {
	f: i64,
	a: i8,
	b: u8,
	c: i16,
	d: u32be,
	e: f32,
	g: enum u16 {
		A,
	},
	h: bit_set[0 ..< 16;u16],
	i: [8]u8,
}

Flags :: struct {
	on:   bool,
	_pad: [3]u8,
	more: b32,
}

@(test)
plain_data_check :: proc(t: ^testing.T) {
	testing.expect_value(t, sim.plain_violation(type_info_of(toy.State)), "")
	testing.expect_value(t, sim.plain_violation(type_info_of(toy.Input)), "")
	testing.expect_value(t, sim.wire_violation(type_info_of(toy.Input)), "")
	testing.expect_value(t, sim.plain_violation(type_info_of(Sized)), "")
	testing.expect(t, sim.wire_violation(type_info_of(Sized)) != "", "Sized holds an f32: not an Input")
	// A padding error names the struct and the bytes, inside the field that holds it too.
	testing.expect_value(
		t,
		sim.plain_violation(type_info_of(Padded), "Padded"),
		"Padded.large: Padded has 3 bytes of implicit padding before this field (add `_pad: [3]u8` before it, or reorder)",
	)
	End_Padded :: struct {
		large: u32,
		small: u8,
	}
	Holder :: struct {
		items: [2]End_Padded,
	}
	testing.expect_value(
		t,
		sim.plain_violation(type_info_of(Holder), "State"),
		"State.items: End_Padded has 3 bytes of implicit padding at its end (add `_pad: [3]u8` as its last field)",
	)
	// Every hole in one report, each struct's once however many fields hold it: one run lists every `_pad` to add.
	Many_Holes :: struct {
		first:  Padded,
		second: Padded,
		tail:   [2]End_Padded,
		flag:   u8,
		count:  u64,
	}
	testing.expect_value(
		t,
		sim.plain_violation(type_info_of(Many_Holes), "State"),
		"State.first.large: Padded has 3 bytes of implicit padding before this field (add `_pad: [3]u8` before it, or reorder); " +
		"State.tail: End_Padded has 3 bytes of implicit padding at its end (add `_pad: [3]u8` as its last field); " +
		"State.count: Many_Holes has 7 bytes of implicit padding before this field (add `_pad: [7]u8` before it, or reorder)",
	)
	testing.expect(t, sim.plain_violation(type_info_of(With_Pointer)) != "")
	testing.expect(t, sim.plain_violation(type_info_of([]u8)) != "")
	// Platform-sized integers and any float but f32, also inside an enum, a bit_set or an array.
	Default_Enum :: enum {
		A,
	}
	Distinct_Int :: distinct int
	for type in ([]typeid{int, uint, uintptr, f64, f16, Default_Enum, bit_set[0 ..< 8;int], [2]f64, Distinct_Int}) {
		testing.expectf(t, sim.plain_violation(type_info_of(type)) != "", "%v accepted in the state", type)
	}
	// Bools and floats: in the state, yes; in an Input (from another machine), no.
	testing.expect_value(t, sim.plain_violation(type_info_of(Flags)), "")
	testing.expect(t, sim.wire_violation(type_info_of(Flags)) != "")
	testing.expect(t, sim.wire_violation(type_info_of([4]b8)) != "")
	testing.expect_value(t, sim.plain_violation(type_info_of([2]f32)), "")
	testing.expect(t, sim.wire_violation(type_info_of([2]f32)) != "")
	testing.expect(t, sim.layout_hash(toy.State) != sim.layout_hash(Padded))
}

@(test)
inputs_compare_as_bytes :: proc(t: ^testing.T) {
	Float_Input :: struct {
		x: f32,
	}
	Float_State :: struct {
		players: sim.Players(u8, sim.No_Profile, Float_Input, 2),
	}
	a, b: sim.Inputs(
		sim.Game(Float_State, Float_Input, toy.World, toy.Event, toy.Cmd, sim.No_Setup, sim.No_Profile, 2),
	)
	a.present = {0}
	b.present = {0}
	b.replaced = {0}
	testing.expect(t, sim.inputs_same(&a, &b)) // `replaced` is informational
	b.input[0].x = -0.0
	testing.expect(t, !sim.inputs_same(&a, &b)) // -0.0 == +0.0 as floats, not as bytes
	nan := transmute(f32)u32(0x7FC0_0000)
	a.input[0].x = nan
	b.input[0].x = nan
	testing.expect(t, sim.inputs_same(&a, &b)) // NaN != NaN as floats
	b.present = {0, 1}
	testing.expect(t, !sim.inputs_same(&a, &b))
}

// An Extra that steps at another rate than the game (physics.Settings.tick_hz) is refused; one with none is not.
@(test)
extra_rate_check :: proc(t: ^testing.T) {
	testing.expect_value(t, sim.extra_violation(&toy.GAME, {tick_hz = toy.HZ}), "")
	testing.expect_value(t, sim.extra_violation(&toy.GAME, {}), "")
	testing.expect_value(
		t,
		sim.extra_violation(&toy.GAME, {tick_hz = toy.HZ / 2}),
		"toy: its Extra steps at 32 Hz, the game at 64 Hz (physics.Settings.tick_hz must be Game.tick_hz)",
	)
}

// sim.game_violation of a toy with these unions and this tick rate.
declared :: proc($Cmd, $Event: typeid, tick_hz := 64) -> string {
	game := sim.Game(toy.State, toy.Input, toy.World, Event, Cmd, sim.No_Setup, toy.Profile, toy.PLAYERS) {
		name    = "toy",
		tick_hz = tick_hz,
	}
	return sim.game_violation(&game)
}

Cmd_Padded :: struct {
	small: u8,
	large: u32,
}

Cmd_Max :: struct {
	bytes: [sim.COMMAND_MAX]u8,
}

Cmd_Too_Big :: struct {
	bytes: [sim.COMMAND_MAX + 1]u8,
}

Bump :: struct {
	amount: i32,
}

Cmd_Bump :: struct {
	amount: i32,
}

Event_Padded :: struct {
	player: sim.Player,
	speed:  u8, // one byte of padding after it
}

Event_Pointer :: struct {
	at: ^int,
}

Event_Ticked :: struct {
	tick: u32, // every event carries its tick already (and its kind and id)
}

// What game_violation accepts and refuses: commands are plain data without padding, 0..COMMAND_MAX bytes, names
// unique; events are 0..EVENT_MAX bytes and may be padded but hold no pointer and no field named tick, kind or id;
// neither union is #no_nil; the tick rate is a power of two, 32..128; the State is plain data.
@(test)
declarations_are_checked :: proc(t: ^testing.T) {
	Case :: struct {
		what:    string,
		refusal: string, // "": accepted; else a part of the reason
	}
	Joined :: sim.Event_Player_Joined
	Left :: sim.Event_Player_Left
	cases := []Case {
		{declared(toy.Cmd, toy.Event), ""},
		{
			declared(union {
					Cmd_Max,
				}, toy.Event),
			"",
		},
		{
			declared(union {
					Cmd_Padded,
				}, toy.Event),
			"padding",
		},
		{
			declared(union {
					Cmd_Too_Big,
				}, toy.Event),
			"bytes",
		},
		{
			declared(union {
					struct{},
				}, toy.Event),
			"",
		}, // an empty command: zero bytes
		{
			declared(toy.Cmd, union {
					Joined,
					Left,
					struct{},
				}),
			"",
		}, // an empty event: the kind alone says what happened
		{
			declared(toy.Cmd, union {
					Joined,
					struct {
						data: [sim.EVENT_MAX + 1]u8,
					},
				}),
			"bytes",
		}, // an event over EVENT_MAX bytes
		{
			declared(union {
					string,
				}, toy.Event),
			"commands",
		},
		{
			declared(union {
					Bump,
					Cmd_Bump,
				}, toy.Event),
			"named",
		}, // "bump" twice: the prefix goes
		{declared(Cmd_Bump, toy.Event), "not a union"},
		{
			declared(toy.Cmd, union {
					Joined,
					Left,
					Event_Padded,
				}),
			"",
		},
		{
			declared(toy.Cmd, union {
					Joined,
					Left,
					Event_Pointer,
				}),
			"events",
		},
		{
			declared(toy.Cmd, union #no_nil {
					Joined,
					Left,
				}),
			"#no_nil",
		},
		{
			declared(toy.Cmd, union {
					Joined,
					Left,
					Event_Ticked,
				}),
			"`tick`",
		},
		{declared(toy.Cmd, toy.Event, 60), "tick_hz"},
		{declared(toy.Cmd, toy.Event, 256), "tick_hz"},
		{declared(toy.Cmd, toy.Event, 16), "tick_hz"},
	}
	for test_case, i in cases {
		if test_case.refusal == "" {
			testing.expectf(t, test_case.what == "", "case %d refused: %s", i, test_case.what)
		} else {
			testing.expectf(
				t,
				strings.contains(test_case.what, test_case.refusal),
				"case %d: %q, wanted a refusal naming %q",
				i,
				test_case.what,
				test_case.refusal,
			)
		}
	}
	Float_State :: struct {
		players: sim.Players(u8, sim.No_Profile, Float_Input, toy.PLAYERS),
		at:      f64,
	}
	Float_Input :: struct {
		x: f32,
	}
	floats := sim.Game(
		Float_State,
		Float_Input,
		toy.World,
		toy.Event,
		toy.Cmd,
		sim.No_Setup,
		sim.No_Profile,
		toy.PLAYERS,
	) {
		name    = "floats",
		tick_hz = 64,
	}
	testing.expect(t, strings.contains(sim.game_violation(&floats), "the State is not plain data"))
}

// compat_of of a toy with these unions, Input and State (the toy's name, version and tick rate).
compat_with :: proc($State, $Input, $Event, $Cmd: typeid) -> u64 {
	Profile :: sim.part(intrinsics.type_field_type(State, "players"), 1)
	game := sim.Game(State, Input, toy.World, Event, Cmd, toy.Setup, Profile, toy.PLAYERS) {
		name    = toy.GAME.name,
		version = toy.GAME.version,
		tick_hz = toy.GAME.tick_hz,
		levels  = toy.GAME.levels,
	}
	return sim.compat_of(&game)
}

Renamed :: struct {
	at:     [2]f32,
	normal: [3]f32,
	weight: f32,
	count:  i16,
	shape:  toy.Shape,
	shapes: toy.Shapes,
	loud:   bool,
	_pad:   [3]u8,
}

Other_Input :: struct {
	dx, dy:  i8,
	buttons: u16,
}

Other_State :: struct {
	players: sim.Players(toy.Player_Data, sim.No_Profile, Other_Input, toy.PLAYERS),
}

// compat_of tells builds apart by what they compute with: the name, version and tick rate, the unions (the same
// structs as other kinds, or the same layout under another name), the Input and State layouts, the levels, the
// library's version and Box3D pin; the same types give the same value.
@(test)
compat_tells_builds_apart :: proc(t: ^testing.T) {
	compat := sim.compat_of(&toy.GAME)
	testing.expect(t, compat != 0)
	with :: proc(field: string, value: string) -> u64 {
		game := toy.GAME
		switch field {
		case "name":
			game.name = value
		case "version":
			game.version = value
		case "tick_hz":
			game.tick_hz = 128
		}
		return sim.compat_of(&game)
	}
	Case :: struct {
		what:  string,
		value: u64,
	}
	other_levels := toy.GAME
	other_levels.levels = {toy.GAME.levels[0], {"cave", {1, 2, 4}}}
	no_levels := toy.GAME
	no_levels.levels = nil
	differ := []Case {
		{"another version", with("version", "a version the toy never has")},
		{"another name", with("name", "toy-variant")},
		{"another tick rate", with("tick_hz", "")},
		{
			"fewer events",
			compat_with(toy.State, toy.Input, union {
					sim.Event_Player_Joined,
					sim.Event_Player_Left,
				}, toy.Cmd),
		},
		{
			"commands as other kinds",
			compat_with(toy.State, toy.Input, toy.Event, union {
					toy.Cmd_Mark,
					toy.Cmd_Bump,
					toy.Cmd_Clear_Bumps,
				}),
		},
		{
			"fewer commands",
			compat_with(toy.State, toy.Input, toy.Event, union {
					toy.Cmd_Bump,
					toy.Cmd_Mark,
				}),
		},
		{
			"a command renamed",
			compat_with(toy.State, toy.Input, toy.Event, union {
					toy.Cmd_Bump,
					Renamed,
					toy.Cmd_Clear_Bumps,
				}),
		},
		{"another Input of the same size", compat_with(Other_State, Other_Input, toy.Event, toy.Cmd)},
		{"a level's other bytes", sim.compat_of(&other_levels)},
		{"no levels", sim.compat_of(&no_levels)},
		{"another library version", sim.compat_of(&toy.GAME, {version = sim.LIBRARY_VERSION + 1})},
		{"another Box3D pin", sim.compat_of(&toy.GAME, {box3d = "another-r1"})},
	}
	for test_case, i in differ {
		testing.expectf(t, test_case.value != compat, "%s: the toy's compat", test_case.what)
		for before in differ[:i] {
			testing.expectf(
				t,
				test_case.value != before.value,
				"%s: the same compat as %s",
				test_case.what,
				before.what,
			)
		}
	}
	testing.expect_value(t, compat_with(toy.State, toy.Input, toy.Event, union {
				toy.Cmd_Bump,
				toy.Cmd_Mark,
				toy.Cmd_Clear_Bumps,
				toy.Cmd_Travel,
				toy.Cmd_Pause,
				toy.Cmd_Trail,
			}), compat)
	testing.expect_value(t, sim.compat_of(&toy.GAME), compat) // stable
	testing.expect_value(t, sim.content_hash(nil), 0)
}

// A Profile's enum must declare a member of value 0, as an Input's: a malformed or absent Profile reads as the zero
// one, which would hold an undeclared value (`STATS[profile.role]` out of bounds on every peer).
Role_No_Zero :: enum u8 {
	Tank   = 1,
	Healer = 2,
}

Role_Profile :: struct {
	role: Role_No_Zero,
}

Role_State :: struct {
	players: sim.Players(u32, Role_Profile, toy.Input, 1),
}

Role_Game :: sim.Game(Role_State, toy.Input, sim.No_World, toy.Event, sim.No_Commands, sim.No_Setup, Role_Profile, 1)

@(test)
a_profile_enum_without_a_zero_member_is_refused :: proc(t: ^testing.T) {
	game := Role_Game {
		name = "roles",
		version = "1",
		tick_hz = 64,
		tick = proc(t: ^sim.Tick(Role_Game)) {},
	}
	reason := sim.game_violation(&game)
	testing.expectf(t, strings.contains(reason, "Profile") && strings.contains(reason, "0"), "%q", reason)
}

// A Clock must be a field of the State itself: one inside a nested struct would never run (game time would be the tick
// number, and set_paused would assert inside a tick on every peer).
Nested_Clock_State :: struct {
	players: sim.Players(u32, sim.No_Profile, toy.Input, 1),
	match:   struct {
		clock: sim.Clock,
	},
}

Nested_Clock_Game :: sim.Game(
	Nested_Clock_State,
	toy.Input,
	sim.No_World,
	toy.Event,
	sim.No_Commands,
	sim.No_Setup,
	sim.No_Profile,
	1,
)

@(test)
a_clock_in_a_nested_struct_is_refused :: proc(t: ^testing.T) {
	game := Nested_Clock_Game {
		name = "nested",
		version = "1",
		tick_hz = 64,
		tick = proc(t: ^sim.Tick(Nested_Clock_Game)) {},
	}
	reason := sim.game_violation(&game)
	testing.expectf(t, strings.contains(reason, "`match` holds a sim.Clock"), "%q", reason)
}

// A game's own type whose name starts like sim's (Active_Level_Banner) is not taken for sim.Active_Level.
Active_Level_Banner :: struct {
	shown_at: u32,
}

Banner_State :: struct {
	banner: Active_Level_Banner,
}

@(test)
a_game_type_named_like_active_level_is_not_a_level :: proc(t: ^testing.T) {
	testing.expect_value(t, sim.levels_violation("banner", type_info_of(Banner_State), nil), "")
}

// A dev build and a public build of a game with dev commands refuse each other (compat's dev bit); a game without
// dev commands is the same build either way.
@(test)
the_dev_bit_splits_builds_of_a_game_with_dev_commands :: proc(t: ^testing.T) {
	testing.expect(t, sim.has_dev_commands(Dev_Cmd))
	testing.expect(t, sim.compat_of(&DEV_GAME) != sim.compat_of(&DEV_GAME, {public = true}))
	testing.expect_value(t, sim.compat_of(&toy.GAME, {public = true}), sim.compat_of(&toy.GAME))
}

Cmd_Add :: struct {
	amount: u32,
}

Cmd_Dev_Add :: struct {
	amount: u32,
}

Dev_Cmd :: union {
	Cmd_Add,
	Cmd_Dev_Add,
}

Dev_State :: struct {
	players: sim.Players(toy.Player_Data, sim.No_Profile, toy.Input, 2),
	plain:   u32,
	dev:     u32,
	order:   [8]u32, // the commands in the order read (a dev one as 1000 + its amount)
	read:    u32,
	_pad:    u32,
}

Dev_Game :: sim.Game(Dev_State, toy.Input, sim.No_World, toy.Event, Dev_Cmd, sim.No_Setup, sim.No_Profile, 2)

DEV_GAME := Dev_Game {
	name = "dev_commands",
	version = "1",
	tick_hz = 64,
	tick = proc(t: ^sim.Tick(Dev_Game)) {
		players := sim.iterate_present(t)
		for _, player in sim.next(&players) {
			for sent in sim.commands(t, player) {
				switch command in sent {
				case Cmd_Add:
					t.state.plain += command.amount
					t.state.order[t.state.read % 8] = command.amount
				case Cmd_Dev_Add:
					t.state.dev += command.amount
					t.state.order[t.state.read % 8] = 1000 + command.amount
				}
				t.state.read += 1
			}
		}
	},
}

// A public build leaves every dev command out, whoever sends it, and applies the others in their order; a dev build
// applies all of them. The public side runs here by clearing the Sim's dev_commands (no second compile).
@(test)
a_public_build_applies_no_dev_command :: proc(t: ^testing.T) {
	for public in ([]bool{false, true}) {
		simulation := sim.create(&DEV_GAME, 1)
		defer sim.destroy(simulation)
		testing.expect_value(t, simulation.dev_commands, sim.DEV)
		if public do simulation.dev_commands = false
		inputs: sim.Inputs(Dev_Game)
		sim.seat(&inputs, simulation, 0, 1)
		sim.seat(&inputs, simulation, 1, 2)
		testing.expect(t, sim.add_command(&inputs, 0, Cmd_Add{1}))
		testing.expect(t, sim.add_command(&inputs, 0, Cmd_Dev_Add{2}))
		testing.expect(t, sim.add_command(&inputs, 0, Cmd_Add{3}))
		testing.expect(t, sim.add_command(&inputs, 0, Cmd_Dev_Add{4}))
		testing.expect(t, sim.add_command(&inputs, 1, Cmd_Dev_Add{5}))
		sim.step(simulation, &inputs)
		state := &simulation.state
		testing.expect_value(t, state.plain, 4)
		if public {
			testing.expect_value(t, state.dev, 0)
			testing.expect_value(t, state.read, 2)
			testing.expect(t, state.order[0] == 1 && state.order[1] == 3, "the others in their order")
		} else {
			testing.expect_value(t, state.dev, 11)
			testing.expect_value(t, state.read, 5)
		}
	}
}
