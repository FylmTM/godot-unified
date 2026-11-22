extends Node2D
## The view bench's player view: hears every event the way an effect would (it counts them) and keeps none, so the
## host refills one object per class instead of making one per event.

var events := 0


func _sim_event(_event: UnifiedEvent, _state: UnifiedSession.EventState) -> void:
	events += 1
