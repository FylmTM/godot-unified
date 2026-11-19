// friendslop's headless binary: the modes of src/headless/README.md on the game (`-- help` lists them), through
// unified:headless/modes, on the levels the game embeds (GAME.levels); `--level NAME=FILE` replaces one.
package main

import "unified:headless/modes"

import g "../friendslop"

main :: proc() {
	modes.run(&g.GAME)
}
