@tool
extends Node3D
## Level marker for the sim's volumes and triggers: pads, plates, bells, switches, bumpers, checkpoints, the run's
## start and finish, player spawns. One script, the kind picked per node; static, so its visuals stay in place.

@export_enum("pad", "plate", "bell", "switch", "bumper", "checkpoint", "start", "finish", "spawn") var unified_kind := "pad":
	set(v):
		unified_kind = v
		set_meta("unified_kind", v)
		if is_inside_tree():
			_build()
@export var size := Vector3(0.75, 0.3, 0.75):  ## half extents of the volume
	set(v):
		size = v
		if is_inside_tree():
			_build()
@export var launch := Vector3(0, 12, 0)  ## pad: the velocity given
@export var mass := 15.0  ## plate: the mass that presses it
@export var radius := 0.5  ## bell
@export var strength := 9.0  ## bumper: knockback speed
@export var index := 0  ## checkpoint: order along the route
@export var slot := 0  ## spawn: player slot


func _ready() -> void:
	set_meta("unified_kind", unified_kind)
	_build()


func _build() -> void:
	match unified_kind:
		"pad":
			Greybox.set_mesh(self, Greybox.cylinder(maxf(size.x, size.z), 0.12), Greybox.PAD, Vector3(0, 0.06 - size.y, 0), 1.2)
		"plate":
			Greybox.set_mesh(self, Greybox.box(Vector3(size.x * 2.0, 0.1, size.z * 2.0)), Greybox.PLATE, Vector3(0, 0.05 - size.y, 0))
		"bell":
			Greybox.set_mesh(self, Greybox.sphere(radius), Greybox.BELL, Vector3.ZERO, 0.4)
		"switch":
			Greybox.set_mesh(self, Greybox.box(Vector3(0.4, 0.6, 0.4)), Greybox.SWITCH, Vector3.ZERO, 0.6)
		"bumper":
			Greybox.set_mesh(self, Greybox.cylinder(minf(size.x, size.z) * 0.8, size.y * 2.0), Greybox.BUMPER)
		"checkpoint", "start", "finish":
			Greybox.set_mesh(self, Greybox.box(Vector3(0.1, 2.0, 0.1)), Greybox.FLAG, Vector3(size.x, 1.0 - size.y, 0), 0.8)
			Greybox.set_mesh(self, Greybox.box(Vector3(0.1, 2.0, 0.1)), Greybox.FLAG, Vector3(-size.x, 1.0 - size.y, 0), 0.8, "Greybox2")
		"spawn":
			pass
