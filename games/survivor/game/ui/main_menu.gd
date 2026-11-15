extends Node
## The main menu's backdrop: the arena with crates and barrels where the sim places them (`Game.constants.items`),
## resting on the floor (visual only, nothing simulates them here). The menu itself is the games' shared one.

## A body's centre at rest: a 1 m box, a 0.4 m capsule with a 0.3 m half-height.
const REST_Y := {"crate": 0.5, "barrel": 0.7}

@onready var _props: Node3D = $Props


func _ready() -> void:
	var items: Array = Game.constants.get("items", [])
	for i in items.size():
		var item: Dictionary = items[i]
		var pos: Vector3 = item.get("position", Vector3.ZERO)
		var kind: String = item.get("kind", "crate")
		var rest_y: float = REST_Y.get(kind, 0.5)
		var view := (load("res://game/views/%s.tscn" % kind) as PackedScene).instantiate() as SurvivorPropView
		view.position = Vector3(pos.x, rest_y, pos.z)
		view.rotation.y = i * 0.7
		view.pop_in = false
		_props.add_child(view)
