@tool
extends Node3D
## Level marker: a dynamic item the sim owns (kinds and sizes: ITEM_SPECS in simulation/friendslop/world.odin).
## Its visuals move to the item's sim view at runtime.

const UNIFIED_KIND := "item"
## Must match the sim's ITEM_SPECS (validate compares them with the game library's constants()).
const SIZES := {
	"crate": Vector3(0.7, 0.7, 0.7),
	"ball": Vector3(0.6, 0.6, 0.6),
	"cube": Vector3(0.8, 0.8, 0.8),
	"key": Vector3(0.3, 0.5, 0.3),
	"heavy": Vector3(1.4, 0.8, 0.9),
	"trophy": Vector3(0.5, 0.8, 0.5),
}
const COLORS := {
	"crate": Greybox.CRATE,
	"ball": Greybox.BALL,
	"cube": Greybox.CUBE,
	"key": Greybox.KEY,
	"heavy": Greybox.HEAVY,
	"trophy": Greybox.TROPHY,
}

@export_enum("crate", "ball", "cube", "key", "heavy", "trophy") var kind := "crate":
	set(v):
		kind = v
		if is_inside_tree():
			_build()


func _ready() -> void:
	_build()


func _build() -> void:
	var size: Vector3 = SIZES.get(kind, Vector3.ONE)
	var c: Color = COLORS.get(kind, Color.WHITE)
	if kind == "ball":
		Greybox.set_mesh(self, Greybox.sphere(size.x * 0.5), c)
	else:
		Greybox.set_mesh(self, Greybox.box(size), c, Vector3.ZERO, 0.6 if kind in ["key", "trophy"] else 0.0)
	if kind == "heavy":
		for i in 2:
			var h := Greybox.set_mesh(self, Greybox.box(Vector3(0.1, 0.12, 0.5)), Color(0.25, 0.25, 0.3),
				Vector3((size.x * 0.5 + 0.05) * (1 - 2 * i), 0, 0), 0.0, "GreyboxHandle%d" % i)
			h.name = "GreyboxHandle%d" % i
