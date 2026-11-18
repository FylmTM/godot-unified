// drift's headless binary: the modes of src/headless/SPEC.md on the game (`-- help` lists them), through
// unified:headless/modes, on the level the game embeds (drift.GAME.content); `--level FILE` loads another.
package main

import "../drift"
import "unified:headless/modes"

main :: proc() {
	modes.run(&drift.GAME, {
		bench = {
			what  = "drift on the arena (2D physics locked to a plane: ships, splitting rocks)",
			ticks = 1800,
		},
	})
}
