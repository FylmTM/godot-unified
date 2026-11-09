extends Node2D
## A 2D level marker for the exporter fixture (level_2d.tscn): typed exported properties, Vector2 among them.

const UNIFIED_KIND := "spawn"

@export var push := Vector2(3, -4)
@export var speed := 2.5
@export var lives := 3
@export var label := "left"
@export var goal: NodePath
