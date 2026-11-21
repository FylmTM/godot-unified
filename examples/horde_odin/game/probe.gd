class_name Probe
extends Node
## The render experiment's measurement (the same file in every horde_* example): with `-- --measure <file.json>` it
## adds heroes (`--heroes N`, scripted local players), waits `--warmup-s`, samples every frame for `--measure-s`, writes
## the results as JSON and quits. `--unlocked` turns vsync off and lifts the frame cap, so frame times show the cost.
##
## Per frame: the wall time between frames, the main loop's process time, the viewport's CPU and GPU render times,
## draw calls, Godot objects created (the ObjectDB validator counter's step: every Object made, RefCounted ones
## included), live objects and nodes, and static memory (its rises summed: a lower bound on the bytes allocated).

const VALIDATOR_SHIFT := 24  # ObjectID: validator << OBJECTDB_SLOT_MAX_COUNT_BITS | slot
const VALIDATOR_MASK := (1 << 39) - 1

var _out := ""
var _warmup_s := 5.0
var _measure_s := 20.0
var _heroes := 1
var _unlocked := false
var _session: UnifiedSession

var _phase := 0  # 0: waiting for the session, 1: warming up, 2: measuring, 3: done
var _t0 := 0
var _last_us := 0
var _last_validator := 0
var _last_static := 0
var _frames: Array[Dictionary] = []


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var i := 0
	while i < args.size():
		match args[i]:
			"--measure":
				_out = args[i + 1]
				i += 1
			"--warmup-s":
				_warmup_s = args[i + 1].to_float()
				i += 1
			"--measure-s":
				_measure_s = args[i + 1].to_float()
				i += 1
			"--heroes":
				_heroes = args[i + 1].to_int()
				i += 1
			"--unlocked":
				_unlocked = true
		i += 1
	if _out == "":
		set_process(false)
		return
	process_priority = 1000  # after everything else this frame
	if _unlocked:
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		Engine.max_fps = 0
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)


## The session the probe adds heroes to and quits through.
func attach(session: UnifiedSession) -> void:
	_session = session


func _process(_delta: float) -> void:
	var now := Time.get_ticks_usec()
	match _phase:
		0:
			if _session != null and _session.running and _session.local_player != 0:
				for k in _heroes - 1:
					_session.add_local_player()
				_phase = 1
				_t0 = now
		1:
			if now - _t0 >= int(_warmup_s * 1e6):
				_phase = 2
				_t0 = now
				_last_us = now
				_last_validator = _validator()
				_last_static = Performance.get_monitor(Performance.MEMORY_STATIC) as int
		2:
			_sample(now)
			if now - _t0 >= int(_measure_s * 1e6):
				_phase = 3
				_finish()


func _validator() -> int:
	var probe := Object.new()
	var id := probe.get_instance_id()
	probe.free()
	return (id >> VALIDATOR_SHIFT) & VALIDATOR_MASK


func _sample(now: int) -> void:
	var validator := _validator()
	var mem := Performance.get_monitor(Performance.MEMORY_STATIC) as int
	var viewport := get_viewport().get_viewport_rid()
	_frames.append({
		"frame_us": now - _last_us,
		"process_ms": Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
		"render_cpu_ms": RenderingServer.viewport_get_measured_render_time_cpu(viewport) + RenderingServer.get_frame_setup_time_cpu(),
		"render_gpu_ms": RenderingServer.viewport_get_measured_render_time_gpu(viewport),
		"draw_calls": Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
		"objects_made": validator - _last_validator - 1,  # less the probe's own
		"objects": Performance.get_monitor(Performance.OBJECT_COUNT),
		"nodes": Performance.get_monitor(Performance.OBJECT_NODE_COUNT),
		"static_mem": mem,
		"static_rise": maxi(mem - _last_static, 0),
		"enemies": _enemies(),
	})
	_last_us = now
	_last_validator = validator
	_last_static = mem


# The HUD's enemy count when the example has session data (-1: none: the all-Odin example has no Data_Hud).
func _enemies() -> int:
	var data: Object = Unified.get(&"data")
	if data == null:
		return -1
	var hud: Object = data.get(&"hud")
	if hud == null:
		return -1
	var count: int = hud.get(&"enemies")
	return count


func _finish() -> void:
	var result := {
		"example": ProjectSettings.get_setting("application/config/name"),
		"frames": _frames.size(),
		"seconds": _measure_s,
		"heroes": _heroes,
		"unlocked": _unlocked,
		"frame_ms": _stats("frame_us", 0.001),
		"process_ms": _stats("process_ms", 1.0),
		"render_cpu_ms": _stats("render_cpu_ms", 1.0),
		"render_gpu_ms": _stats("render_gpu_ms", 1.0),
		"draw_calls": _stats("draw_calls", 1.0),
		"objects_made_per_s": _sum("objects_made") / _measure_s,
		"static_rise_mb_per_s": _sum("static_rise") / _measure_s / 1048576.0,
		"objects": _stats("objects", 1.0),
		"nodes": _stats("nodes", 1.0),
		"static_mem_mb": _stats("static_mem", 1.0 / 1048576.0),
		"enemies": _stats("enemies", 1.0),
		"fps": _frames.size() / _measure_s,
	}
	var file := FileAccess.open(_out, FileAccess.WRITE)
	file.store_string(JSON.stringify(result, "  "))
	file.close()
	print("probe: %s" % JSON.stringify(result))
	if _session != null:
		_session.quit(0)
	else:
		get_tree().quit()


func _sum(key: String) -> float:
	var total := 0.0
	for frame in _frames:
		var value: float = frame[key]
		total += value
	return total


func _stats(key: String, scale: float) -> Dictionary:
	var values: Array[float] = []
	for frame in _frames:
		var value: float = frame[key]
		values.append(value * scale)
	values.sort()
	if values.is_empty():
		return {}
	var total := 0.0
	for v in values:
		total += v
	return {
		"mean": total / values.size(),
		"p50": values[int(values.size() * 0.5)],
		"p95": values[mini(int(values.size() * 0.95), values.size() - 1)],
		"p99": values[mini(int(values.size() * 0.99), values.size() - 1)],
		"max": values[values.size() - 1],
	}
