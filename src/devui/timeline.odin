// The Timeline panel: a replay session's controls (the host's replay: src/godot/README.md, Replays): the playhead's
// tick on a seek slider, step back, play or pause, step forward, the speed, and how the recording's checkpoints
// compare. Game-agnostic: the host passes what to show every frame (timeline) and gets what was asked.
package devui

import "core:fmt"
import gd "unified:gdext"

// What a replay shows (the host's, every frame while one runs).
Timeline :: struct {
	tick, first, last: u32,
	paused:            bool,
	speed:             f32,
	checkpoints:       int, // compared so far
	agreed, diverged:  u32, // the last that agreed, the first that didn't (0: none)
	other_build:       bool,
}

// What the panel asked for this frame (zero: nothing).
Timeline_Request :: struct {
	toggle_pause: bool,
	step:         int, // ticks, negative back
	seek:         i64, // a tick (-1: none)
	speed:        f32, // 0: unchanged
}

@(private)
TIMELINE_SPEEDS := [?]f32{0.25, 0.5, 1, 2, 4}

@(private)
Timeline_Panel :: struct {
	built:    bool,
	opened:   bool, // opened once for this replay
	slider:   gd.HSlider,
	play:     gd.Button,
	speed:    gd.Button,
	info:     gd.Label,
	request:  Timeline_Request,
	shown:    Timeline,
	updating: bool, // the host's values are being set: the slider's value_changed is not the user's
}

@(private)
build_timeline :: proc() {
	panel := &s.timeline
	box := gd.VBoxContainer_new()
	row := add(box, gd.HBoxContainer_new())
	button(row, "◀ 1", proc(_: rawptr, _: []^gd.Variant) -> gd.Variant {
		s.timeline.request.step -= 1
		return {}
	})
	panel.play = button(row, "play", proc(_: rawptr, _: []^gd.Variant) -> gd.Variant {
		s.timeline.request.toggle_pause = !s.timeline.request.toggle_pause
		return {}
	})
	button(row, "1 ▶", proc(_: rawptr, _: []^gd.Variant) -> gd.Variant {
		s.timeline.request.step += 1
		return {}
	})
	panel.speed = button(row, "1x", proc(_: rawptr, _: []^gd.Variant) -> gd.Variant {
		next := TIMELINE_SPEEDS[0]
		for speed, i in TIMELINE_SPEEDS do if speed == s.timeline.shown.speed && i + 1 < len(TIMELINE_SPEEDS) do next = TIMELINE_SPEEDS[i + 1]
		s.timeline.request.speed = next
		return {}
	})
	panel.slider = add(box, gd.HSlider_new())
	gd.Control_set_h_size_flags(panel.slider, .SIZE_EXPAND_FILL)
	gd.Control_set_focus_mode(panel.slider, .FOCUS_NONE)
	gd.Range_set_step(panel.slider, 1)
	on(panel.slider, "value_changed", proc(_: rawptr, args: []^gd.Variant) -> gd.Variant {
		value, _ := gd.from_variant(f64, args[0])
		s.timeline.request.seek = i64(value)
		return {}
	})
	panel.info = label(box, "")
	panel.request.seek = -1
	panel.built = true
	panel_make(.Timeline, "Timeline", {8, 300, 420, 96}, box)
}

// Shows a replay's state in the Timeline panel (opening it the first frame of a replay) and returns what the panel
// asked for since the last call. Nothing without the dev UI.
timeline :: proc(view: Timeline) -> (request: Timeline_Request) {
	request.seek = -1
	if !s.inited || !s.timeline.built do return
	panel := &s.timeline
	if !panel.opened {
		panel.opened = true
		panel_open(.Timeline, true)
	}
	request = panel.request
	panel.request = {
		seek = -1,
	}
	if view == panel.shown do return
	panel.shown = view
	panel.updating = true
	gd.Range_set_max(panel.slider, f64(view.last - view.first)) // ticks from the first: the slider's minimum stays 0
	gd.Range_set_value_no_signal(panel.slider, f64(view.tick - view.first))
	panel.updating = false
	gd.Button_set_text(panel.play, view.paused ? "play" : "pause")
	gd.Button_set_text(panel.speed, fmt.tprintf("%vx", view.speed))
	checks := "no checkpoints yet"
	switch {
	case view.diverged != 0:
		checks = fmt.tprintf("diverged at %d (agreed to %d)", view.diverged, view.agreed)
	case view.checkpoints > 0:
		checks = fmt.tprintf("%d checkpoints agree (to %d)", view.checkpoints, view.agreed)
	}
	gd.Label_set_text(
		panel.info,
		fmt.tprintf(
			"tick %d of %d..%d   %s%s",
			view.tick,
			view.first,
			view.last,
			checks,
			view.other_build ? "   (recorded by another build)" : "",
		),
	)
	return
}

// The replay ended: the panel opens again on the next one.
timeline_end :: proc() {
	if !s.inited do return
	s.timeline.opened = false
	panel_open(.Timeline, false)
}
