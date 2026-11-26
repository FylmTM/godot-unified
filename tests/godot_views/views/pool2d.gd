extends Node2D
# A pooled view kind (its marker's `pool`; ext/ext.odin's pool_views): one key a period, gone for two ticks in it
# (revived), a one-tick key beside it (two of the kind at once), events to its key and the key before. Every instance
# writes what happens to it into one log that outlives it, so the test reads reuses it never saw a frame of.

## In order, one entry a callback: {what (ready, reused, despawned, revived, cancelled, event, nulled), id (the
## instance), key (the marker's then), serial (the data's, -1: none), position, player, visible, inside, old_null
## (the last data set replaced null), target and from (an event's key and player), msec and usec (when), frame_usec
## (when its frame began), nested (the key its data's nested struct and array hold: [area.corner.x, keys[0], keys[1]],
## [] for none)}.
static var log: Array[Dictionary] = []
## When the current frame began (Time.get_ticks_usec; the test sets it from SceneTree.process_frame): before the host
## read its clock for the frame's lingers.
static var frame_usec := 0

var _old_null := false

# View_Pool2D (ext/ext.odin): set before _ready, to null when the view goes into the pool, and anew on its reuse.
var data: ViewPool2d:
	set(value):
		if value == null:
			_note("nulled")
		else:
			_old_null = data == null
		data = value

@onready var marker: UnifiedView = $UnifiedView


func _ready() -> void:
	_note("ready")


func _sim_reused() -> void:
	_note("reused")


# The host no longer poses it: moved away, as an exit animation would; a reuse must pose it anew.
func _sim_despawned() -> void:
	_note("despawned")
	position = Vector2(-999, -999)


func _sim_revived() -> void:
	_note("revived")


func _sim_cancelled() -> void:
	_note("cancelled")


# The schedule's events (their player POOL_EVENT_PLAYER, routed by Glue.event_key to the key in position.x) and, while
# it shows the local player, that player's (by the player route).
func _sim_event(event: UnifiedEvent, _state: UnifiedSession.EventState) -> void:
	var spawned := event as EventSpawned
	if spawned != null:
		_note("event", roundi(spawned.position.x / Unified.view_scale), spawned.player)


func _note(what: String, target: int = 0, from: int = 0) -> void:
	log.append({what = what, id = get_instance_id(), key = marker.key if marker else -1,
		serial = data.serial if data else -1, position = position, player = marker.player if marker else -1,
		visible = visible, inside = is_inside_tree(), old_null = _old_null, target = target, from = from,
		msec = Time.get_ticks_msec(), usec = Time.get_ticks_usec(), frame_usec = frame_usec,
		nested = [roundi(data.area.corner.x), data.keys[0], data.keys[1]] if data else []})

