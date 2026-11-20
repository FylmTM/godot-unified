class_name Hud
extends Control
## The scene, the counts, the keys and a crosshair, from the session's data (Unified.data.hud), which is the newest
## prediction: nothing here must be final.

const KEYS := "WASD fly, Space / Ctrl up and down, mouse look (click to capture, Esc to release)\nLMB hold: grab (Q / E closer / farther)   RMB: shoot   F: spawn (G: shape)   X: explode   C: drive (Driving)\n[ ] or PgUp / PgDn: scene   R: reset the scene"

@onready var _swatch: ColorRect = %Swatch
@onready var _scene: Label = %Scene
@onready var _counts: Label = %Counts
@onready var _shape: Label = %Shape
@onready var _crosshair: Label = %Crosshair


func _ready() -> void:
	(%Keys as Label).text = KEYS
	Unified.data.hud.changed.connect(_on_hud_changed)
	_on_hud_changed()
	show_shape(0)


## The spawn tool's next shape.
func show_shape(shape: int) -> void:
	_shape.text = "Spawn: %s" % String(EnumShape.name(shape)).capitalize()


func _on_hud_changed() -> void:
	var hud := Unified.data.hud
	_swatch.color = hud.color
	_scene.text = "%d / %d  %s" % [hud.scene + 1, EnumLevel.names().size(), String(EnumLevel.name(hud.scene)).capitalize()]
	_counts.text = "%d players   %d bodies (%d awake)" % [hud.players, hud.bodies, hud.awake]
	_crosshair.modulate = Color(1, 0.9, 0.3) if hud.holding else Color(1, 1, 1, 0.8)
	_crosshair.visible = not hud.driving
