extends Control

@onready var swatch: ColorRect = %Swatch
@onready var players_label: Label = %Players
@onready var balls_label: Label = %Balls


func _ready() -> void:
	Unified.data.hud.changed.connect(_on_hud_changed)
	_on_hud_changed()


func _on_hud_changed() -> void:
	swatch.color = Unified.data.hud.color
	players_label.text = "Players: %d" % Unified.data.hud.players
	balls_label.text = "Balls: %d" % Unified.data.hud.balls
