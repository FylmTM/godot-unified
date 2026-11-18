// friendslop's headless binary: the modes of src/headless/SPEC.md on the game (`-- help` lists them), through
// unified:headless/modes, on the level the game embeds (GAME.content); `--level FILE` loads another.
package main

import "unified:headless/modes"

import g "../friendslop"

main :: proc() {
	modes.run(&g.GAME, {
		bench = {
			what  = "friendslop on the park level (Box3D characters and joints)",
			ticks = 600,
		},
	})
}
