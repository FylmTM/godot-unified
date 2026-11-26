extends Node3D

@onready var marker: UnifiedView = $UnifiedView
# View_Remote3D (ext/ext.odin): set by the host before _ready, and anew each time it changes.
var data: ViewRemote3d:
	set(value):
		data = value
		tick = value.tick
		if int(value.trail[0]) != tick or int(value.trail[-1]) != tick + value.trail.size() - 1:
			torn += 1
var tick := 0  # data.tick: the tick its data is of (on the verified timeline, its sample's)
var torn := 0  # data set whose trail isn't its tick's (ext/ext.odin's View_Remote3D): not one sample's whole data
var shown_early := false  # visible before it had data: posed without a sample
# [x, data tick, the session's verified tick, the frame's delta (s), the frame's number] each frame it shows, until it
# despawns
var poses: Array[Array] = []
var events: Array[Array] = []  # [event, state, the frame's pose ([x, data tick]), the frame before's (or [])]
var despawns := 0
var despawn_tick := -1  # its data tick when it despawned
var despawn_session_tick := -1  # the session's newest tick then
var despawn_frame: Array = []  # [the session's verified tick, the frame's delta (s), the frame's number] then
var arrived: Array[Array] = []  # this frame's events, waiting for its pose
## What it saw, kept up to date and outliving it (the test takes it once): shown_early, poses, despawns, despawn_tick,
## despawn_session_tick, despawn_frame.
var record := {shown_early = false, poses = poses, despawns = 0}


# The host posed it (and set its data) before any other node's _process (its own runs at priority -1000).
func _process(delta: float) -> void:
	if not visible:
		return
	if tick == 0:
		shown_early = true
		record.shown_early = true
	var before: Array = poses[-1] if not poses.is_empty() else []
	if despawns == 0:
		poses.append([position.x, tick, Unified.session.verified_tick, delta, Engine.get_process_frames()])
	for e in arrived:
		events.append([e[0], e[1], [position.x, tick], before])
	arrived.clear()


func _sim_despawned() -> void:
	despawns += 1
	despawn_tick = tick
	despawn_session_tick = Unified.session.tick
	despawn_frame = [Unified.session.verified_tick, get_process_delta_time(), Engine.get_process_frames()]
	record.merge({despawns = despawns, despawn_tick = despawn_tick, despawn_session_tick = despawn_session_tick,
		despawn_frame = despawn_frame}, true)


func _sim_event(event: UnifiedEvent, state: UnifiedSession.EventState) -> void:
	arrived.append([event, state])
