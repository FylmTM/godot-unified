// deckbuilder's headless binary: the modes of src/headless/README.md (`-- help` lists them) on the game with the
// `quick` tuning, which the scripted player crosses the act in; `--game deckbuilder` runs the game as played.
package main

import "unified:headless/modes"

import g "../deckbuilder"

main :: proc() {
	modes.run(&g.GAME_QUICK, variants = {&g.GAME}) // --game deckbuilder: the `play` tuning, as the game runs it
}
