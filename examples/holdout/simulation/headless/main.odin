// holdout's headless binary: the modes of src/headless/README.md (`-- help` lists them) on the holdout game, through
// unified:headless/modes; its standard benchmark (Game.benches) holds the last wave at ENEMY_CAP enemies.
package main

import "unified:headless/modes"

import g "../holdout"

main :: proc() {
	modes.run(&g.GAME)
}
