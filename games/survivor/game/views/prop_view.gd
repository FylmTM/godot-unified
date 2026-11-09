extends GameView
## Crates and barrels: the host sets position and the full physics rotation (they tumble); pop in when spawned
## (barrels respawn after exploding), shrink away when despawned.

## Scale up from nothing when spawned (off for static decoration, e.g. the menu backdrop).
@export var pop_in := true

@onready var _body: Node3D = $Body
var _age := 0.0
var _exit: Tween


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


func _sim_event(event: StringName, _data: Dictionary) -> void:
	if event == &"despawned":
		set_process(false)
		_exit = create_tween()
		_exit.tween_property(_body, "scale", Vector3.ONE * 0.01, 0.15)
	elif event == &"revived":  # a rollback brought it back within the linger time
		if _exit != null:
			_exit.kill()
		_body.scale = Vector3.ONE
