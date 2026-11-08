extends GameView
## Crates and barrels: follow the sim position and yaw; pop in when spawned (barrels respawn after exploding).

## Scale up from nothing when spawned (off for static decoration, e.g. the menu backdrop).
@export var pop_in := true

@onready var _body: Node3D = $Body
var _age := 0.0


func _ready() -> void:
	if pop_in:
		_body.scale = Vector3.ONE * 0.01
	else:
		set_process(false)


func _process(delta: float) -> void:
	_age += delta
	var t := clampf(_age / 0.3, 0.0, 1.0)
	_body.scale = Vector3.ONE * (1.0 + 0.25 * sin(t * PI)) * t
	if t >= 1.0:
		set_process(false)


func _sim_update(_pos: Vector3, yaw: float, _alpha: float) -> void:
	rotation.y = yaw
