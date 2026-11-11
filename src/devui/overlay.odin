// The overlay, top right: the panel toggles, the stats (10 Hz), the frame-time graph and the plots (every frame).
// Clicks go through it to the game, except on its buttons.
//
// The frame-time graph puts real time on the x axis: each frame is a bar as wide as it lasted and as tall as it
// lasted, so a hitch covers as much of the graph as the time it cost (with the frame index on the x axis, a 100 ms
// stall is one thin bar among hundreds of fast frames). The graph shows the last FRAME_SPAN_MS; each pixel column
// shows the longest frame that overlaps it.
package devui

import "core:fmt"
import "core:strings"
import gd "unified:gdext"
import "unified:gdext/gdi"

@(private)
OVERLAY_W :: 250
@(private)
GRAPH_H :: 34
@(private)
PLOT_H :: 24
@(private)
FRAME_SPAN_MS :: 2000
@(private)
MAX_W :: 600 // graph width cap (points)
@(private)
FRAME_HIST :: 4096 // frames kept (> FRAME_SPAN_MS at 2000 fps)

@(private)
Graph :: struct {
	name:     string,
	min, max: f32,
	values:   [OVERLAY_W]f32,
	head:     int,
	last:     f32,
	label:    gd.Label,
	ctl:      gd.Control,
	ci:       gd.RID, // our own canvas item under the control's (Godot never clears it)
}

@(private)
Overlay :: struct {
	panel:     gd.PanelContainer,
	buttons:   gd.HBoxContainer,
	toggles:   [Panel_Kind]gd.Button,
	stats:     gd.Label,
	text:      strings.Builder,
	frame_ctl: gd.Control,
	frame_ci:  gd.RID,
	frames:    [FRAME_HIST]f32, // ms, a ring
	frame_n:   int,
	graphs:    [dynamic]Graph,
	box:       gd.VBoxContainer,
	// scratch arrays (the RenderingServer copies them)
	points:    gd.PackedVector2Array,
	colors:    gd.PackedColorArray,
	indices:   gd.PackedInt32Array,
	empty_v:   gd.PackedVector2Array,
	empty_i:   gd.PackedInt32Array,
	empty_f:   gd.PackedFloat32Array,
}

@(private)
build_overlay :: proc() {
	o := &s.overlay
	o.panel = add(s.layer, gd.PanelContainer_new())
	gd.Control_set_theme(o.panel, s.theme)
	gd.Control_set_theme_type_variation(o.panel, "DevOverlay")
	gd.Control_set_mouse_filter(o.panel, .MOUSE_FILTER_IGNORE)
	gd.Control_set_custom_minimum_size(o.panel, {OVERLAY_W, 0})
	o.box = add(o.panel, gd.VBoxContainer_new())
	gd.Control_set_mouse_filter(o.box, .MOUSE_FILTER_IGNORE)
	o.buttons = add(o.box, gd.HBoxContainer_new())
	gd.BoxContainer_set_alignment(o.buttons, .ALIGNMENT_END)
	gd.Control_set_mouse_filter(o.buttons, .MOUSE_FILTER_IGNORE)
	gd.Control_set_h_size_flags(o.buttons, .SIZE_SHRINK_END)
	names := [Panel_Kind]string {
		.Inspector = "inspect",
		.Netsim    = "netsim",
		.Events    = "events",
		.Note      = "note",
	}
	for k in Panel_Kind {
		b := button(o.buttons, names[k], proc(user: rawptr, _: []^gd.Variant) -> gd.Variant {
				k := Panel_Kind(uintptr(user))
				if k == .Note && !s.panels[k].open do note_open()
				else do panel_open(k, !s.panels[k].open)
				return {}
			}, rawptr(uintptr(k)))
		gd.BaseButton_set_toggle_mode(b, true)
		gd.Control_set_theme_type_variation(b, "DevToggle")
		o.toggles[k] = b
	}
	o.stats = label(o.box, "")
	gd.Control_add_theme_font_override(o.stats, "font", s.mono)
	frame_graph := add(o.box, gd.Control_new())
	o.frame_ctl = frame_graph
	gd.Control_set_custom_minimum_size(frame_graph, {OVERLAY_W, GRAPH_H})
	gd.Control_set_h_size_flags(frame_graph, .SIZE_EXPAND_FILL)
	gd.Control_set_mouse_filter(frame_graph, .MOUSE_FILTER_IGNORE)
	o.frame_ci = gd.RenderingServer_canvas_item_create(s.rs)
	gd.RenderingServer_canvas_item_set_parent(s.rs, o.frame_ci, gd.CanvasItem_get_canvas_item(frame_graph))
	o.points = gd.PackedVector2Array_new0()
	o.colors = gd.PackedColorArray_new0()
	o.indices = gd.PackedInt32Array_new0()
	o.empty_v = gd.PackedVector2Array_new0()
	o.empty_i = gd.PackedInt32Array_new0()
	o.empty_f = gd.PackedFloat32Array_new0()
}

@(private)
overlay_shutdown :: proc() {
	o := &s.overlay
	for &g in o.graphs {
		gd.RenderingServer_free_rid(s.rs, g.ci)
		delete(g.name)
	}
	delete(o.graphs)
	gd.RenderingServer_free_rid(s.rs, o.frame_ci)
	strings.builder_destroy(&o.text)
	gd.PackedVector2Array_destroy(&o.points)
	gd.PackedColorArray_destroy(&o.colors)
	gd.PackedInt32Array_destroy(&o.indices)
	gd.PackedVector2Array_destroy(&o.empty_v)
	gd.PackedInt32Array_destroy(&o.empty_i)
	gd.PackedFloat32Array_destroy(&o.empty_f)
}

// Top right of the game window.
@(private)
overlay_place :: proc() {
	size := gd.Control_get_size(s.overlay.panel)
	gd.Control_set_position(s.overlay.panel, {s.view.x - size.x - 4, 4})
}

@(private)
overlay_sync_toggles :: proc() {
	for k in Panel_Kind do gd.BaseButton_set_pressed_no_signal(s.overlay.toggles[k], s.panels[k].open)
}

@(private)
frame_time_add :: proc(ms: f32) {
	o := &s.overlay
	o.frames[o.frame_n % FRAME_HIST] = ms
	o.frame_n += 1
}

@(private)
graph_add :: proc(name: string, v: f32, lo, hi: f32) {
	o := &s.overlay
	for &g in o.graphs {
		if g.name == name {
			g.values[g.head] = v
			g.head = (g.head + 1) % OVERLAY_W
			g.last = v
			return
		}
	}
	g := Graph {
		name = strings.clone(name),
		min  = lo,
		max  = hi,
		last = v,
		head = 1,
	}
	g.values[0] = v
	g.label = label(o.box, "")
	ctl := add(o.box, gd.Control_new())
	g.ctl = ctl
	gd.Control_set_custom_minimum_size(ctl, {OVERLAY_W, PLOT_H})
	gd.Control_set_h_size_flags(ctl, .SIZE_EXPAND_FILL)
	gd.Control_set_mouse_filter(ctl, .MOUSE_FILTER_IGNORE)
	g.ci = gd.RenderingServer_canvas_item_create(s.rs)
	gd.RenderingServer_canvas_item_set_parent(s.rs, g.ci, gd.CanvasItem_get_canvas_item(ctl))
	append(&o.graphs, g)
}

@(private)
overlay_update :: proc(slow: bool) {
	o := &s.overlay
	if slow {
		b := &o.text
		strings.builder_reset(b)
		last, avg, worst := frame_summary()
		fmt.sbprintf(b, "frame %5.2f ms  avg %5.2f  max %5.1f\nui %.2f ms", last, avg, worst, s.ui_ms)
		for line in s.stats do fmt.sbprintf(b, "\n%s", line)
		gd.Label_set_text(o.stats, strings.to_string(b^))
		for &g in o.graphs do gd.Label_set_text(g.label, fmt.tprintf("%s %.1f", g.name, g.last))
	}
	draw_frame_graph()
	for &g in o.graphs do draw_plot(&g)
}

// The last frame, and the average and longest of the last second.
@(private)
frame_summary :: proc() -> (last, avg, worst: f32) {
	o := &s.overlay
	if o.frame_n == 0 do return
	last = o.frames[(o.frame_n - 1) % FRAME_HIST]
	sum: f32
	n := 0
	for i := o.frame_n - 1; i >= max(0, o.frame_n - FRAME_HIST) && sum < 1000; i -= 1 {
		ms := o.frames[i % FRAME_HIST]
		sum += ms
		worst = max(worst, ms)
		n += 1
	}
	avg = sum / f32(max(n, 1))
	return
}

// The scale's top: the smallest of these that fits the longest frame shown (ms).
@(private)
FRAME_SCALES := [?]f32{2, 4.17, 8.33, 16.67, 33.33, 66.67, 133.3, 1000}

@(private)
draw_frame_graph :: proc() {
	o := &s.overlay
	w := clamp(int(gd.Control_get_size(o.frame_ctl).x), 1, MAX_W)
	cols_all: [MAX_W]f32
	cols := cols_all[:w]
	px_per_ms := f32(w) / FRAME_SPAN_MS
	x := f32(w)
	for i := o.frame_n - 1; i >= max(0, o.frame_n - FRAME_HIST) && x > 0; i -= 1 {
		ms := o.frames[i % FRAME_HIST]
		x0 := x - ms * px_per_ms
		for c in max(int(x0), 0) ..< min(int(x + 0.999), w) do cols[c] = max(cols[c], ms)
		x = x0
	}
	top := FRAME_SCALES[len(FRAME_SCALES) - 1]
	worst: f32
	for c in cols do worst = max(worst, c)
	for t in FRAME_SCALES {
		if worst <= t {
			top = t
			break
		}
	}
	n := 0
	for c in cols do if c > 0 do n += 1
	gd.PackedVector2Array_resize(&o.points, n * 4)
	gd.PackedColorArray_resize(&o.colors, n * 4)
	gd.PackedInt32Array_resize(&o.indices, n * 6)
	pts := ([^]gd.Vector2)(gdi.packed_vector2_array_operator_index(&o.points, 0))
	cls := ([^]gd.Color)(gdi.packed_color_array_operator_index(&o.colors, 0))
	idx := ([^]i32)(gdi.packed_int32_array_operator_index(&o.indices, 0))
	j := 0
	for ms, c in cols {
		if ms <= 0 do continue
		h := min(ms / top, 1) * GRAPH_H
		x0, x1 := f32(c), f32(c + 1)
		pts[j * 4 + 0] = {x0, GRAPH_H - h}
		pts[j * 4 + 1] = {x1, GRAPH_H - h}
		pts[j * 4 + 2] = {x1, GRAPH_H}
		pts[j * 4 + 3] = {x0, GRAPH_H}
		col :=
			ms <= 16.7 ? gd.Color{0.4, 0.78, 0.45, 1} : ms <= 33.4 ? gd.Color{0.95, 0.75, 0.3, 1} : gd.Color{0.95, 0.35, 0.3, 1}
		for v in 0 ..< 4 do cls[j * 4 + v] = col
		b := i32(j * 4)
		idx[j * 6 + 0], idx[j * 6 + 1], idx[j * 6 + 2] = b, b + 1, b + 2
		idx[j * 6 + 3], idx[j * 6 + 4], idx[j * 6 + 5] = b, b + 2, b + 3
		j += 1
	}
	ci := o.frame_ci
	gd.RenderingServer_canvas_item_clear(s.rs, ci)
	gd.RenderingServer_canvas_item_add_rect(s.rs, ci, {{0, 0}, {f32(w), GRAPH_H}}, {0, 0, 0, 0.3})
	if n > 0 {
		gd.RenderingServer_canvas_item_add_triangle_array(
			s.rs,
			ci,
			o.indices,
			o.points,
			o.colors,
			o.empty_v,
			o.empty_i,
			o.empty_f,
			{},
		)
	}
	// 60 Hz budget line, when it is on the scale
	if top > 16.67 {
		y := GRAPH_H - 16.67 / top * GRAPH_H
		gd.RenderingServer_canvas_item_add_rect(s.rs, ci, {{0, y}, {f32(w), 1}}, {1, 1, 1, 0.25})
	}
}

@(private)
draw_plot :: proc(g: ^Graph) {
	o := &s.overlay
	lo, hi := g.min, g.max
	if lo == hi { 	// auto scale
		lo, hi = max(f32), -max(f32)
		for v in g.values {
			lo = min(lo, v)
			hi = max(hi, v)
		}
		if hi <= lo do hi = lo + 1
	}
	gd.PackedVector2Array_resize(&o.points, OVERLAY_W)
	pts := ([^]gd.Vector2)(gdi.packed_vector2_array_operator_index(&o.points, 0))
	w := gd.Control_get_size(g.ctl).x
	for i in 0 ..< OVERLAY_W {
		v := clamp(g.values[(g.head + i) % OVERLAY_W], lo, hi)
		pts[i] = {f32(i) * w / (OVERLAY_W - 1), PLOT_H - (v - lo) / (hi - lo) * PLOT_H}
	}
	gd.PackedColorArray_resize(&o.colors, 1)
	(^gd.Color)(gdi.packed_color_array_operator_index(&o.colors, 0))^ = {0.55, 0.8, 1, 1}
	gd.RenderingServer_canvas_item_clear(s.rs, g.ci)
	gd.RenderingServer_canvas_item_add_rect(s.rs, g.ci, {{0, 0}, {w, PLOT_H}}, {0, 0, 0, 0.3})
	gd.RenderingServer_canvas_item_add_polyline(s.rs, g.ci, o.points, o.colors, 1)
}
