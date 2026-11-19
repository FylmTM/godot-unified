extends Node3D

@onready var body: MeshInstance3D = %Body

var color: Color:
	set(value):
		color = value
		(body.material_override as StandardMaterial3D).albedo_color = value

var _tween: Tween

# An effect goes on EMITTED (at once, predicted) and is undone on CANCELLED; what must happen once (a score, an
# unlock) goes on CONFIRMED, or a rollback can fire it twice (GUIDE.md). The squash is short enough to leave be.
func _sim_event(event: UnifiedEvent, state: UnifiedSession.EventState) -> void:
	if event is EventBallThrown and state == UnifiedSession.EVENT_EMITTED:
		if _tween:
			_tween.kill()
		body.scale = Vector3(1.25, 0.8, 1.25)
		_tween = create_tween()
		_tween.tween_property(body, "scale", Vector3.ONE, 0.25)
