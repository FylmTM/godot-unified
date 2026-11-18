// friendslop's headless binary: the modes of src/headless/SPEC.md on the game (`-- help` lists them), through
// unified:headless/modes. The level is embedded (the committed export of game/levels/park.tscn); `--level FILE`
// loads another.
package main

import "../friendslop"
import "unified:headless/modes"

main :: proc() {
	modes.run(&friendslop.GAME, {
		content = #load("../../game/levels/park.level"),
		bench = {
			what  = "friendslop on the park level (Box3D characters and joints)",
			ticks = 600,
		},
	})
}
