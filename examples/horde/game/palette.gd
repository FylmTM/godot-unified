class_name Palette
## The horde's colours and sizes, shared by every view and effect.

const SLOT_COLORS: Array[Color] = [
	Color(0.35, 0.75, 1.0),
	Color(1.0, 0.55, 0.35),
	Color(0.55, 1.0, 0.45),
	Color(1.0, 0.85, 0.3),
]
const ENEMY_COLORS: Array[Color] = [Color(0.55, 0.8, 0.35), Color(0.95, 0.7, 0.25), Color(0.7, 0.35, 0.9)]
const ENEMY_RADIUS: Array[float] = [0.35, 0.28, 0.6]  # sim units (tuning.odin's ENEMY_STATS)
const HERO_RADIUS := 0.4
const SOURCE_COLORS: Array[Color] = [Color(1, 1, 1), Color(0.6, 0.85, 1.0), Color(1.0, 0.6, 0.25)]
const FLOOR := Color(0.09, 0.1, 0.12)
const GRID := Color(0.14, 0.15, 0.18)
const ARENA_HALF := 30.0
