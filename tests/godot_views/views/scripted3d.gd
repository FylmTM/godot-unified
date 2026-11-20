extends Node3D

## Where its script puts it instead of the sim's pose (the view policy script-poses this kind).
const OWN_POSITION := Vector3(-7, 0, 7)

var poses := 0
var sim_position := Vector3.INF
var sim_rotation := Quaternion.IDENTITY


# The host hands the pose over instead of setting it (GLUE.views: .Scripted3D = {policy = {pose = .Script}}).
func _sim_pose(new_position: Vector3, new_rotation: Quaternion) -> void:
	poses += 1
	sim_position = new_position
	sim_rotation = new_rotation


func _process(_delta: float) -> void:
	position = OWN_POSITION
