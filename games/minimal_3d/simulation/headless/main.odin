package main

import "unified:headless/modes"

import g "../minimal_3d"

main :: proc() {
	// No standard benchmark yet (`uni bench` runs only the game's sessions): once the game has a population worth
	// timing, pass `bench = {...}` with a Game.bench_prepare that builds it (src/headless/README.md).
	modes.run(&g.GAME)
}
