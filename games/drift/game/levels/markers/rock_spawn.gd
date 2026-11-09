extends Marker2D
## Where a wave's rocks come from, in turn, drifting along `dir` (any length; the sim normalises it).

const UNIFIED_KIND := "rock_spawn"

@export var dir := Vector2(0, 1)
