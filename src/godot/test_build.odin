// A test build (ODIN_TEST) compiles godot.init empty, so a game's tests import its extension for its Glue
// (install_problems) without compiling the whole host for the game: a large State copied by value makes that slow.
// The host is generic over the game, and an import used only inside generic procs counts as unused until something
// instantiates them, so this file does it once, for a game of one empty player: never called, it costs next to
// nothing to compile and keeps the package whole under -vet.
package godot

@(require) import "unified:sim" // used only in a test build (and linked anyway: the host is built on it)

when ODIN_TEST {
	@(private = "file")
	Vet_Input :: struct {
		x: u8,
	}

	@(private = "file")
	Vet_State :: struct {
		players: sim.Players(sim.No_World, sim.No_Profile, Vet_Input, 1),
	}

	@(private = "file")
	Vet_Event :: union {
		sim.Event_Player_Joined,
		sim.Event_Player_Left,
	}

	@(private = "file")
	Vet_Game :: sim.Game(
		Vet_State,
		Vet_Input,
		sim.No_World,
		Vet_Event,
		sim.No_Commands,
		sim.No_Setup,
		sim.No_Profile,
		1,
	)

	@(private = "file")
	Vet_View :: enum u8 {
		None,
	}

	@(private = "file")
	vet_host :: proc() {
		@(static) game: Vet_Game
		install(&game, Glue(Vet_Game, Vet_View, Vet_View){})
	}
}
