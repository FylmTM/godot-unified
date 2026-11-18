// friendslop's headless binary: the modes of src/headless/SPEC.md on the game (`-- help` lists them), through
// unified:headless/modes, on the level the game embeds (friendslop.GAME.content); `--level FILE` loads another.
package main

import "../friendslop"
import "unified:headless/modes"

main :: proc() {
	modes.run(&friendslop.GAME, {
		bench = {
			what  = "friendslop on the park level (Box3D characters and joints)",
			ticks = 600,
		},
	})
}
