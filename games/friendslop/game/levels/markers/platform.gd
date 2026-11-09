@tool
extends Node3D
## Level marker: a kinematic platform the sim moves along its Path3D child (offsets from the first point), or
## that stays put. `trigger` (a plate, bell or switch) starts it, or for mode "follow" holds it forward.

const UNIFIED_KIND := "platform"

@export var size := Vector3(1.5, 0.25, 1.5):  ## half extents
	set(v):
		size = v
		if is_inside_tree():
			_build()
@export var seconds := 2.0  ## per leg
@export var wait := 0.5  ## at each point
@export_enum("ping_pong", "loop", "once", "follow") var mode := "ping_pong"
@export var smooth := true
@export var trigger: NodePath
@export var color := Greybox.PLATFORM


func _ready() -> void:
	_build()


func _build() -> void:
	Greybox.set_mesh(self, Greybox.box(size * 2.0), color)
