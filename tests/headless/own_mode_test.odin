// A game's own headless mode (modes.run's `own_modes`): its options struct, parsed with modes.parse and shown by
// modes.usage, the way the library's modes take theirs.
package test_headless

import "../toy"
import "core:testing"

import "unified:headless/modes"

@(private = "file")
Count_Options :: struct {
	rounds: int `args:"required" hint:"R"`,
	label:  string,
	fast:   bool,
}

@(private = "file")
g_parsed: Count_Options

@(private = "file")
COUNT_MODE :: modes.Mode(toy.Game) {
	name = "count",
	options = Count_Options,
	help = "a game's own mode",
	run = proc(game: ^toy.Game, args: ^modes.Args) -> bool {
		options := Count_Options {
			label = "plain",
		}
		modes.parse(args, &options)
		modes.in_range(args, "rounds", options.rounds, 1, 9)
		g_parsed = options
		return true
	},
}

@(test)
a_games_own_mode_parses_its_options_struct :: proc(t: ^testing.T) {
	testing.expect_value(t, modes.usage(COUNT_MODE.options), "--rounds R [--label S] [--fast]")
	game := toy.GAME
	args := modes.Args {
		mode = COUNT_MODE.name,
		argv = {"--rounds", "3", "--fast"},
	}
	testing.expect(t, COUNT_MODE.run(&game, &args))
	testing.expect_value(t, g_parsed, Count_Options{rounds = 3, label = "plain", fast = true})
	args.argv = {"--rounds=4", "--label", "named"}
	testing.expect(t, COUNT_MODE.run(&game, &args))
	testing.expect_value(t, g_parsed, Count_Options{rounds = 4, label = "named"})
}
