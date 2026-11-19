class_name SurvivorPropView
extends Node3D
## Crates and barrels: the sim's item views and the level's item markers. As a view the host sets position and the
## full physics rotation (they tumble); it pops in when spawned (barrels respawn after exploding) and shrinks away
## when despawned. Placed in a level (game/levels/arena.tscn) it is an `item` marker: the sim creates the item where it
## stands, and the play scene removes it (the item's view draws it).

const UNIFIED_KIND := "item"

## The item's kind (the sim's Item_Kind, lowercased): set by each view scene, never on an instance.
@export_enum("crate", "barrel") var kind := "crate"

@onready var _body: Node3D = $Body
var _age := 0.0
var _exit: Tween


func _ready() -> void:
	_body.scale = Vector3.ONE * 0.01


func _process(delta: float) -> void:
	_age += delta
	var t := clampf(_age / 0.3, 0.0, 1.0)
	_body.scale = Vector3.ONE * (1.0 + 0.25 * sin(t * PI)) * t
	if t >= 1.0:
		set_process(false)


func _sim_despawned() -> void:
	set_process(false)
	_exit = create_tween()
	_exit.tween_property(_body, "scale", Vector3.ONE * 0.01, 0.15)


## A rollback brought it back within the linger time.
func _sim_revived() -> void:
	if _exit != null:
		_exit.kill()
	_body.scale = Vector3.ONE
