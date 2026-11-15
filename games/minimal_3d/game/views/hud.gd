extends Control

@onready var swatch: ColorRect = %Swatch
@onready var players_label: Label = %Players
@onready var balls_label: Label = %Balls

var color: Color:
	set(value):
		color = value
		swatch.color = value

var players: int:
	set(value):
		players = value
		players_label.text = "Players: %d" % value

var balls: int:
	set(value):
		balls = value
		balls_label.text = "Balls: %d" % value
