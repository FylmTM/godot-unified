package main

import "unified:headless/modes"

import g "../minimal_3d"

main :: proc() {
	modes.run(&g.GAME) // no standard benchmark: four capsules measure nothing
}
