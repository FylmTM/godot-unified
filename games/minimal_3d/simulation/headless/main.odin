package main

import "unified:headless/modes"

import g "../minimal_3d"

main :: proc() {
	modes.run(
		&g.GAME,
		{bench = {what = "minimal_3d with 4 players, a rollback at the prediction cap every tick", ticks = 600}},
	)
}
