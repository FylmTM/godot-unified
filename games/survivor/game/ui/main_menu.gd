extends Node
## The main menu's backdrop: the arena with crates and barrels where the sim places them (`Unified.constants.items`),
## resting on the floor (visual only, nothing simulates them here). The menu itself is menu.tscn.

## A body's centre at rest by item kind: a 1 m box, a 0.4 m capsule with a 0.3 m half-height.
const REST_Y := {EnumItemKind.CRATE: 0.5, EnumItemKind.BARREL: 0.7}

@onready var _props: Node3D = $Props


func _ready() -> void:
	var items := Unified.constants.items
	for i in items.size():
		var item: DataItemSpot = items[i]
		var pos := item.position
		var kind := item.kind
		var rest_y: float = REST_Y.get(kind, 0.5)
		var scene := "res://game/views/%s.tscn" % EnumItemKind.name(kind)  # the view kind is named like the item kind
		var view := (load(scene) as PackedScene).instantiate() as SurvivorPropView
		view.position = Vector3(pos.x, rest_y, pos.z)
		view.rotation.y = i * 0.7
		view.pop_in = false
		_props.add_child(view)
