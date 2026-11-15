extends Node2D
## A warp gate. The host sets its position and `charge` from Gate_View: 0 ready .. 1 just used. A ring of the
## sim's `gate_radius` that dims while charging (an arc shows the recharge), with a slow swirl inside.

## Gate_View (simulation/extension), set by the host when it changes.
var charge := 0.0:
	set(v):
		if v > charge + 0.25:
			_burst = 1.0  # just used
		charge = v

var _r := 25.6  ## the sim's gate radius, in pixels
var _t := 0.0
var _burst := 0.0


func _ready() -> void:
	var radius: float = Game.constants.get("gate_radius", 0.8)
	_r = radius * Game.px_per_m
	_t = float(($UnifiedView as UnifiedView).entity) * 1.7  # gates swirl out of step


func _process(delta: float) -> void:
	_t += delta
	_burst = maxf(_burst - delta * 2.0, 0.0)
	queue_redraw()


func _draw() -> void:
	var ready_frac := clampf(1.0 - charge, 0.0, 1.0)
	var on := charge <= 0.0
	var col := UiTheme.CYAN
	var a := 1.0 if on else 0.25 + 0.25 * ready_frac
	draw_circle(Vector2.ZERO, _r, Color(col, 0.08 + 0.1 * a))
	draw_arc(Vector2.ZERO, _r, 0.0, TAU, 40, Color(col, a), 3.0, true)
	if not on:
		draw_arc(Vector2.ZERO, _r + 6.0, -PI / 2.0, -PI / 2.0 + TAU * ready_frac, 40, Color(col, 0.6), 2.0, true)
	# the swirl: three arcs turning, faster when charged
	var spin := _t * (2.4 if on else 0.6)
	for k in 3:
		var a0 := spin + k * TAU / 3.0
		draw_arc(Vector2.ZERO, _r * 0.6, a0, a0 + 1.2, 12, Color(col, a * 0.7), 2.0, true)
	if _burst > 0.0:
		draw_arc(Vector2.ZERO, _r * (1.0 + (1.0 - _burst) * 1.5), 0.0, TAU, 40, Color(Color.WHITE, _burst), 3.0, true)
