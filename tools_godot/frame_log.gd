class_name UnifiedFrameLog
extends RefCounted
## Frame times for a tool run with `--frames`: every frame's time, tagged with what happened in it (steps, the first
## of each sim event, what the script tags), and a report of the hitches (frames over HITCH_MS) and the worst frame
## after each first use ("FIRST <tag>": a first draw can compile a shader or rasterize glyphs).
##
## A drawn frame is also split in two: its scene process, from the tool's `_process` (the main loop's, before any
## node's) to RenderingServer's `frame_pre_draw` (every script's and node's process, deferred calls, the view sync),
## and its render draw, `frame_pre_draw` to `frame_post_draw`. The rest of the frame is the physics ticks before the
## process and the wait for the next frame. Godot's `Performance.TIME_PROCESS` counts the draw as process time, so it
## cannot tell a script's cost from the renderer's: this split can. A headless run draws no frame (Godot calls no
## draw without a window that can draw), so it has no split.

const HITCH_MS := 25.0

var _frame_us := PackedInt32Array()
## Each frame's scene process and render draw, -1 in a frame not drawn.
var _process_us := PackedInt32Array()
var _draw_us := PackedInt32Array()
## Frame index -> the tags seen during it.
var _tags: Dictionary[int, Array] = {}
## Tags seen so far, for "FIRST <tag>".
var _seen: Dictionary[String, bool] = {}
## This frame's start (the tool's `_process`), its `frame_pre_draw`, and its split so far (-1: not yet).
var _last_us := 0
var _pre_draw_us := 0
var _frame_process_us := -1
var _frame_draw_us := -1


func _init() -> void:
	RenderingServer.frame_pre_draw.connect(_on_pre_draw)
	RenderingServer.frame_post_draw.connect(_on_post_draw)


## Called once per frame, first thing in the main loop's process.
func frame() -> void:
	var now := Time.get_ticks_usec()
	if _last_us != 0:
		_frame_us.append(now - _last_us)
		var drawn := _frame_draw_us >= 0  # a frame_pre_draw with no frame_post_draw counts as not drawn
		_process_us.append(_frame_process_us if drawn else -1)
		_draw_us.append(_frame_draw_us if drawn else -1)
	_last_us = now
	_frame_process_us = -1
	_frame_draw_us = -1


func tag(t: String) -> void:
	var i := _frame_us.size()
	if not _tags.has(i):
		_tags[i] = []
	if not _tags[i].has(t):
		_tags[i].append(t)


## Tags `t`, as "FIRST <t>" the first time.
func tag_first(t: String) -> void:
	tag(t if _seen.has(t) else "FIRST " + t)
	_seen[t] = true


func seen(t: String) -> bool:
	return _seen.has(t)


## The frame-time summary (p50, p99, max; then over the drawn frames the scene process's and the render draw's) plus
## every hitch with its split, what happened in it and the three frames before ([-1] = one frame earlier: work
## started there, a new material say, is drawn and measured in the next frame). Also printed. A hitch's process_ms
## and draw_ms are null in a frame not drawn.
func report() -> Dictionary:
	var sorted := _frame_us.duplicate()
	sorted.sort()
	var n := sorted.size()
	if n == 0:
		return {}
	var processes := PackedInt32Array()
	var draws := PackedInt32Array()
	for i in n:
		if _process_us[i] >= 0:
			processes.append(_process_us[i])
			draws.append(_draw_us[i])
	processes.sort()
	draws.sort()
	var hitches: Array[Dictionary] = []
	for i in n:
		var ms := _frame_us[i] / 1000.0
		if ms < HITCH_MS:
			continue
		var tags: Array[String] = []
		for j in range(i - 3, i + 1):
			for t: String in _tags.get(j, []):
				tags.append("%s%s" % ["" if j == i else "[%d] " % (j - i), t])
		if ms > 990.0 and ms < 1030.0:  # Metal waits up to 1 s for a drawable while the window is hidden or covered
			tags.append("~1 s: window hidden or covered?")
		var hitch := {"frame": i, "ms": snappedf(ms, 0.1), "tags": tags, "process_ms": null, "draw_ms": null}
		if _process_us[i] >= 0:
			hitch.process_ms = snappedf(_process_us[i] / 1000.0, 0.1)
			hitch.draw_ms = snappedf(_draw_us[i] / 1000.0, 0.1)
		hitches.append(hitch)
	var split := "drawn %d" % processes.size()
	if not processes.is_empty():
		split += ": process p50 %.1f ms, p99 %.1f ms, max %.1f ms, draw p50 %.1f ms, p99 %.1f ms, max %.1f ms" % [
			_pct(processes, 0.5), _pct(processes, 0.99), _pct(processes, 1.0), _pct(draws, 0.5), _pct(draws, 0.99),
			_pct(draws, 1.0)]
	print("frames: %d, p50 %.1f ms, p99 %.1f ms, max %.1f ms, %d over %.0f ms; %s" % [n, _pct(sorted, 0.5),
		_pct(sorted, 0.99), _pct(sorted, 1.0), hitches.size(), HITCH_MS, split])
	for h in hitches:
		var tags: Array[String] = h.tags
		var parts := "not drawn"
		if h.process_ms != null:
			parts = "process %.1f, draw %.1f" % [h.process_ms, h.draw_ms]
		print("  hitch  frame %5d  %6.1f ms  %s  %s" % [h.frame, h.ms, parts, ", ".join(PackedStringArray(tags))])
	# The worst of the four frames from each first use: a first draw is measured in the same or the next frame.
	var firsts := {}
	for i: int in _tags:
		for t: String in _tags[i]:
			if t.begins_with("FIRST "):
				var worst := 0
				for j in range(i, mini(i + 4, n)):
					worst = maxi(worst, _frame_us[j])
				firsts[t.trim_prefix("FIRST ")] = snappedf(worst / 1000.0, 0.1)
	print("first uses (worst frame of 4): " + ", ".join(firsts.keys().map(
		func(k: String) -> String: return "%s %.1f" % [k, firsts[k]])))
	var out := {"count": n, "p50_ms": _pct(sorted, 0.5), "p99_ms": _pct(sorted, 0.99), "max_ms": _pct(sorted, 1.0),
		"drawn": processes.size(), "hitches": hitches, "firsts": firsts}
	if not processes.is_empty():
		out.merge({"process_p50_ms": _pct(processes, 0.5), "process_p99_ms": _pct(processes, 0.99),
			"process_max_ms": _pct(processes, 1.0), "draw_p50_ms": _pct(draws, 0.5), "draw_p99_ms": _pct(draws, 0.99),
			"draw_max_ms": _pct(draws, 1.0)})
	return out


func _on_pre_draw() -> void:
	_pre_draw_us = Time.get_ticks_usec()
	if _last_us != 0:
		_frame_process_us = _pre_draw_us - _last_us


func _on_post_draw() -> void:
	if _frame_process_us >= 0:
		_frame_draw_us = Time.get_ticks_usec() - _pre_draw_us


# The `q` quantile of `sorted` (microseconds), in ms.
static func _pct(sorted: PackedInt32Array, q: float) -> float:
	return sorted[mini(sorted.size() - 1, int(q * sorted.size()))] / 1000.0
