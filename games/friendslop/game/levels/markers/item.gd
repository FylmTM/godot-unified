@tool
extends Node3D
## Level marker: a dynamic item the sim owns, drawn at the size the sim simulates it (Unified.constants.item_sizes,
## from the sim's ITEM_SPECS). Its visuals move to the item's sim view at runtime.

const UNIFIED_KIND := "item"
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
	var size := Vector3.ONE
	for entry: DataItemSize in Unified.constants.item_sizes:
		if EnumItemKind.name(entry.kind) == kind:
			size = entry.size
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
