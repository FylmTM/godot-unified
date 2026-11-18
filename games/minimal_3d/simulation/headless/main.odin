package main

import "unified:headless/modes"

import g "../minimal_3d"

main :: proc() {
	// No standard benchmark yet: once the game has a population worth timing, pass `bench = {...}` with a
	// Game.bench_prepare that builds it (src/headless/SPEC.md).
	modes.run(&g.GAME)
}
