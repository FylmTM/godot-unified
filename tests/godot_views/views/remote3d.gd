extends Node3D

@onready var marker: UnifiedView = $UnifiedView
# View_Remote3D (ext/ext.odin): set by the host before _ready, and anew each time it changes.
var data: ViewRemote3d:
	set(value):
		data = value
		tick = value.tick
var tick := 0  # data.tick: the tick its data is of (on the verified timeline, its sample's)
var shown_early := false  # visible before it had data: posed without a sample
var poses: Array[Array] = []  # [x, data tick, the session's verified tick] each frame it shows, until it despawns
var events: Array[Array] = []  # [event, state, the frame's pose ([x, data tick]), the frame before's (or [])]
var despawns := 0
var despawn_tick := -1  # its data tick when it despawned
var despawn_session_tick := -1  # the session's newest tick then
var arrived: Array[Array] = []  # this frame's events, waiting for its pose


# The host posed it (and set its data) before any other node's _process (its own runs at priority -1000).
func _process(_delta: float) -> void:
	if not visible:
		return
	if tick == 0:
		shown_early = true
	var before: Array = poses[-1] if not poses.is_empty() else []
	if despawns == 0:
		poses.append([position.x, tick, Unified.session.verified_tick])
	for e in arrived:
		events.append([e[0], e[1], [position.x, tick], before])
	arrived.clear()


func _sim_despawned() -> void:
	despawns += 1
	despawn_tick = tick
	despawn_session_tick = Unified.session.tick


func _sim_event(event: UnifiedEvent, state: UnifiedSession.EventState) -> void:
	arrived.append([event, state])
