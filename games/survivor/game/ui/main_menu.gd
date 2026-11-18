extends Node
## The main menu's backdrop: the arena with crates and barrels resting where the sim places them
## (`Unified.constants.items`; visual only, nothing simulates them here). The menu itself is menu.tscn.

@onready var _props: Node3D = $Props


func _ready() -> void:
	var items := Unified.constants.items
	for i in items.size():
		var item: DataItemSpot = items[i]
		var scene := "res://game/views/%s.tscn" % EnumItemKind.name(item.kind)  # the view kind is named like the item kind
		var view := (load(scene) as PackedScene).instantiate() as SurvivorPropView
		view.position = item.position
		view.rotation.y = i * 0.7
		view.pop_in = false
		_props.add_child(view)
