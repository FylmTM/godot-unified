class_name Palette
## The arena's colours, shared by the views, the crowds' shaders and the effects. The heroes' colours are the UI's
## (UiTheme.PLAYER_COLORS), the sizes the sim's (Unified.constants).

## By EnumEnemyKind: grunt, runner, brute.
const ENEMY_COLORS: Array[Color] = [Color(0.55, 0.8, 0.35), Color(0.95, 0.7, 0.25), Color(0.7, 0.35, 0.9)]
## By EnumSource, what dealt a hit: bolt, lightning, blast (damage numbers and hit sparks).
const SOURCE_COLORS: Array[Color] = [Color(1, 1, 1), Color(0.6, 0.85, 1.0), Color(1.0, 0.6, 0.25)]
const FLOOR := Color(0.09, 0.1, 0.12)
const GRID := Color(0.14, 0.15, 0.18)
const WALL := Color(0.4, 0.42, 0.5)
const ARC := Color(0.7, 0.9, 1.0)
const BLAST := Color(1.0, 0.65, 0.3)
const GEM := Color(0.4, 0.95, 1.0)
const LEVEL_UP := Color(1.0, 0.95, 0.5)
