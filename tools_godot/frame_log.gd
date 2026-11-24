class_name UnifiedFrameLog
extends RefCounted
## Frame times for a tool run with `--frames`: every frame's time, tagged with what happened in it (steps, the first
## of each sim event, what the script tags), and a report of the hitches (frames over HITCH_MS) and the worst frame
## after each first use ("FIRST <tag>": a first draw can compile a shader or rasterize glyphs).

const HITCH_MS := 25.0

var _frame_us := PackedInt32Array()
## Frame index -> the tags seen during it.
var _tags: Dictionary[int, Array] = {}
## Tags seen so far, for "FIRST <tag>".
var _seen: Dictionary[String, bool] = {}
var _last_us := 0


## Called once per frame.
func frame() -> void:
	var now := Time.get_ticks_usec()
	if _last_us != 0:
		_frame_us.append(now - _last_us)
	_last_us = now


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


## The frame-time summary plus every hitch with what happened in it and the three frames before ([-1] = one frame
## earlier: work started there, a new material say, is drawn and measured in the next frame). Also printed.
func report() -> Dictionary:
	var sorted := _frame_us.duplicate()
	sorted.sort()
	var n := sorted.size()
	if n == 0:
		return {}
	var pct := func(q: float) -> float: return sorted[mini(n - 1, int(q * n))] / 1000.0
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
		hitches.append({"frame": i, "ms": snappedf(ms, 0.1), "tags": tags})
	print("frames: %d, p50 %.1f ms, p99 %.1f ms, max %.1f ms, %d over %.0f ms" % [n, pct.call(0.5), pct.call(0.99),
		sorted[n - 1] / 1000.0, hitches.size(), HITCH_MS])
	for h in hitches:
		var tags: Array[String] = h.tags
		print("  hitch  frame %5d  %6.1f ms  %s" % [h.frame, h.ms, ", ".join(PackedStringArray(tags))])
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
	return {"count": n, "p50_ms": pct.call(0.5), "p99_ms": pct.call(0.99), "max_ms": sorted[n - 1] / 1000.0,
		"hitches": hitches, "firsts": firsts}
