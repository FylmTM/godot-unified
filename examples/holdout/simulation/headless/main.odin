// holdout's headless binary: the modes of src/headless/README.md (`-- help` lists them) on the holdout game, through
// unified:headless/modes; its standard benchmark holds the last wave at ENEMY_CAP enemies (Game.bench_prepare).
package main

import "unified:headless/modes"

import g "../holdout"

main :: proc() {
	modes.run(&g.GAME, bench = {what = "holdout holding the last wave's enemies", entities = g.ENEMY_CAP, ticks = 600})
}
