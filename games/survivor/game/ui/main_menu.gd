extends Node
## The main menu's backdrop: the arena with crates and barrels where the sim places them (`Game.constants.items`),
## resting on the floor (visual only, nothing simulates them here). The menu itself is the games' shared one.

## A body's centre at rest: a 1 m box, a 0.4 m capsule with a 0.3 m half-height.
const REST_Y := {"crate": 0.5, "barrel": 0.7}


func _ready() -> void:
	var items: Array = Game.constants.get("items", [])
	for i in items.size():
		var item: Dictionary = items[i]
		var pos: Vector3 = item.position
		var view: Node3D = (load("res://game/views/%s.tscn" % item.kind) as PackedScene).instantiate()
		view.position = Vector3(pos.x, REST_Y[item.kind], pos.z)
		view.rotation.y = i * 0.7
		view.set(&"pop_in", false)
		$Props.add_child(view)
