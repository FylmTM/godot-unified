// The overlay, top right: the panel toggles, the graph-group toggles, the stats (10 Hz) and the graphs (every
// frame). Clicks go through it to the game, except on its buttons.
//
// Every graph shares one time axis, real time: each frame takes a width proportional to how long it lasted (the
// last FRAME_SPAN_MS), so a hitch covers as much of a graph as the time it cost, and the graphs line up with each
// other. A pixel column shows the frames that overlap it: the frame graph and stacks their longest frame, lines
// their largest value, marks any. Graphs belong to groups ("frame", "sim", "net", a game's own) the overlay toggles;
// only "frame" starts shown. Samples are recorded whatever is shown.
package devui

import "core:fmt"
import "core:strings"
import gd "unified:gdext"
import "unified:gdext/gdi"

@(private)
OVERLAY_W :: 250
@(private)
FRAME_H :: 34
@(private)
GRAPH_H :: 20 // the plot area of a line or stack graph, under its legend band
@(private)
LANE_H :: 5
@(private)
LEGEND_H :: 13
@(private)
FRAME_SPAN_MS :: 2000
@(private)
FRAME_HIST :: 4096 // frames kept (> FRAME_SPAN_MS at 2000 fps)
@(private)
MAX_W :: 600 // graph width cap (points)
@(private)
MAX_PARTS :: 4

@(private)
PALETTE := [MAX_PARTS]gd.Color{{0.36, 0.62, 0.95, 1}, {0.95, 0.6, 0.25, 1}, {0.45, 0.8, 0.45, 1}, {0.75, 0.5, 0.9, 1}}

@(private)
Graph_Kind :: enum u8 {
	Frame, // the frame time, coloured against the budget
	Lines,
	Stack,
	Marks,
}

@(private)
Graph :: struct {
	name:    string,
	kind:    Graph_Kind,
	group:   int,
	n:       int, // lines, parts or lanes
	lo, hi:  f32, // Lines: the scale (lo == hi: from 0 to a round value above the largest shown)
	ring:    [FRAME_HIST][MAX_PARTS]f32, // by frame index (Marks: 1 = set)
	written: int, // the frame index last written (a frame without a sample reads 0)
	last:    [MAX_PARTS]f32, // the latest values (Marks: the count since the last text update)
	ctl:     gd.Control,
	ci:      gd.RID, // our own canvas item under the control's (Godot never clears it)
	title:   gd.Label,
	legend:  [MAX_PARTS]gd.Label,
	names:   [MAX_PARTS]string,
}

@(private)
Group :: struct {
	name:   string,
	shown:  bool,
	toggle: gd.Button,
}

@(private)
Overlay :: struct {
	panel:   gd.PanelContainer,
	box:     gd.VBoxContainer,
	buttons: gd.VBoxContainer, // the toggle rows (the only part of the overlay that takes clicks)
	toggles: [Panel_Kind]gd.Button,
	gbar:    gd.HBoxContainer, // the group toggles
	stats:   gd.Label,
	text:    strings.Builder,
	frames:  [FRAME_HIST]f32, // ms, by frame index
	frame_n: int,
	graphs:  [dynamic]^Graph,
	groups:  [dynamic]Group,
	// per pixel column, the frames overlapping it (first ..= last, absolute indices; first > last: none)
	cols:    [MAX_W][2]int,
	w:       int,
	// scratch arrays (the RenderingServer copies them)
	points:  gd.PackedVector2Array,
	colors:  gd.PackedColorArray,
	indices: gd.PackedInt32Array,
	empty_v: gd.PackedVector2Array,
	empty_i: gd.PackedInt32Array,
	empty_f: gd.PackedFloat32Array,
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
	o.buttons = add(o.box, gd.VBoxContainer_new())
	gd.Control_set_mouse_filter(o.buttons, .MOUSE_FILTER_IGNORE)
	gd.Control_set_h_size_flags(o.buttons, .SIZE_SHRINK_END)
	prow := add(o.buttons, gd.HBoxContainer_new())
	gd.BoxContainer_set_alignment(prow, .ALIGNMENT_END)
	gd.Control_set_mouse_filter(prow, .MOUSE_FILTER_IGNORE)
	names := [Panel_Kind]string {
		.Inspector  = "inspect",
		.Conditions = "conditions",
		.Events     = "events",
		.Note       = "note",
	}
	for k in Panel_Kind {
		b := button(prow, names[k], proc(user: rawptr, _: []^gd.Variant) -> gd.Variant {
				k := Panel_Kind(uintptr(user))
				if k == .Note && !s.panels[k].open do note_open()
				else do panel_open(k, !s.panels[k].open)
				return {}
			}, rawptr(uintptr(k)))
		gd.BaseButton_set_toggle_mode(b, true)
		gd.Control_set_theme_type_variation(b, "DevToggle")
		o.toggles[k] = b
	}
	o.gbar = add(o.buttons, gd.HBoxContainer_new())
	gd.BoxContainer_set_alignment(o.gbar, .ALIGNMENT_END)
	gd.Control_set_mouse_filter(o.gbar, .MOUSE_FILTER_IGNORE)
	o.stats = label(o.box, "")
	gd.Control_add_theme_font_override(o.stats, "font", s.mono)
	o.points = gd.PackedVector2Array_new0()
	o.colors = gd.PackedColorArray_new0()
	o.indices = gd.PackedInt32Array_new0()
	o.empty_v = gd.PackedVector2Array_new0()
	o.empty_i = gd.PackedInt32Array_new0()
	o.empty_f = gd.PackedFloat32Array_new0()
	graph_make("frame ms", .Frame, "frame", 1)
}

@(private)
overlay_shutdown :: proc() {
	o := &s.overlay
	for g in o.graphs {
		gd.RenderingServer_free_rid(s.rs, g.ci)
		delete(g.name)
		for n in g.names do delete(n)
		free(g)
	}
	delete(o.graphs)
	for gr in o.groups do delete(gr.name)
	delete(o.groups)
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

// ---- graphs: creation and samples

@(private)
group_index :: proc(name: string) -> int {
	o := &s.overlay
	for gr, i in o.groups do if gr.name == name do return i
	gr := Group {
		name  = strings.clone(name),
		shown = name == "frame",
	}
	gr.toggle = button(o.gbar, name, proc(user: rawptr, _: []^gd.Variant) -> gd.Variant {
			i := int(uintptr(user))
			gr := &s.overlay.groups[i]
			gr.shown = !gr.shown
			gd.BaseButton_set_pressed_no_signal(gr.toggle, gr.shown)
			for g in s.overlay.graphs do if g.group == i do gd.CanvasItem_set_visible(g.ctl, gr.shown)
			return {}
		}, rawptr(uintptr(len(o.groups))))
	gd.BaseButton_set_toggle_mode(gr.toggle, true)
	gd.BaseButton_set_pressed_no_signal(gr.toggle, gr.shown)
	gd.Control_set_theme_type_variation(gr.toggle, "DevToggle")
	append(&o.groups, gr)
	return len(o.groups) - 1
}

@(private)
graph_find :: proc(name: string) -> ^Graph {
	for g in s.overlay.graphs do if g.name == name do return g
	return nil
}

// A graph control: the drawing underneath, the title and legend (one label per part) on top.
@(private)
graph_make :: proc(name: string, kind: Graph_Kind, group: string, n: int) -> ^Graph {
	o := &s.overlay
	g := new(Graph)
	g.name = strings.clone(name)
	g.kind = kind
	g.group = group_index(group)
	g.n = clamp(n, 1, MAX_PARTS)
	g.written = -1
	g.ctl = add(o.box, gd.Control_new())
	gd.Control_set_custom_minimum_size(g.ctl, {OVERLAY_W, graph_h(g)})
	gd.Control_set_h_size_flags(g.ctl, .SIZE_EXPAND_FILL)
	gd.Control_set_mouse_filter(g.ctl, .MOUSE_FILTER_IGNORE)
	gd.CanvasItem_set_visible(g.ctl, o.groups[g.group].shown)
	g.ci = gd.RenderingServer_canvas_item_create(s.rs)
	gd.RenderingServer_canvas_item_set_parent(s.rs, g.ci, gd.CanvasItem_get_canvas_item(g.ctl))
	row := add(g.ctl, gd.HBoxContainer_new())
	gd.Control_set_position(row, {2, -1})
	gd.Control_set_mouse_filter(row, .MOUSE_FILTER_IGNORE)
	gd.Control_add_theme_constant_override(row, "separation", 6)
	g.title = label(row, kind == .Frame ? "" : name)
	gd.Control_set_theme_type_variation(g.title, "DevGraphLabel")
	if kind != .Frame {
		for i in 0 ..< MAX_PARTS {
			g.legend[i] = label(row, "")
			gd.Control_set_theme_type_variation(g.legend[i], "DevGraphLabel")
			gd.Control_add_theme_color_override(g.legend[i], "font_color", PALETTE[i])
		}
	}
	append(&o.graphs, g)
	return g
}

@(private)
graph_h :: proc(g: ^Graph) -> f32 {
	switch g.kind {
	case .Frame:
		return FRAME_H
	case .Marks:
		return LEGEND_H + f32(MAX_PARTS) * LANE_H
	case .Lines, .Stack:
	}
	return LEGEND_H + GRAPH_H
}

// This frame's sample row of `g` (zeroed when first touched in a frame).
@(private)
graph_slot :: proc(g: ^Graph) -> ^[MAX_PARTS]f32 {
	n := s.overlay.frame_n
	row := &g.ring[n % FRAME_HIST]
	if g.written != n {
		row^ = {}
		g.written = n
	}
	return row
}

@(private)
graph_names :: proc(g: ^Graph, legend: []string) {
	for name, i in legend[:min(len(legend), g.n)] do g.names[i] = strings.clone(name)
}

@(private)
graph_lines :: proc(name: string, values: []f32, legend: []string, lo, hi: f32, group: string) {
	g := graph_find(name)
	if g == nil {
		g = graph_make(name, .Lines, group, len(values))
		g.lo, g.hi = lo, hi
		graph_names(g, legend)
	}
	row := graph_slot(g)
	for v, i in values[:min(len(values), g.n)] {
		row[i] = v
		g.last[i] = v
	}
}

@(private)
graph_stack :: proc(name: string, parts: []f32, legend: []string, group: string) {
	g := graph_find(name)
	if g == nil {
		g = graph_make(name, .Stack, group, len(parts))
		graph_names(g, legend)
	}
	row := graph_slot(g)
	for v, i in parts[:min(len(parts), g.n)] {
		row[i] = max(v, 0)
		g.last[i] = v
	}
}

@(private)
graph_mark :: proc(strip, lane: string, group: string) {
	g := graph_find(strip)
	if g == nil {
		g = graph_make(strip, .Marks, group, 1)
		g.n = 0
	}
	i := 0
	for i < g.n && g.names[i] != lane do i += 1
	if i == g.n {
		if g.n == MAX_PARTS do return
		g.names[i] = strings.clone(lane)
		g.n += 1
	}
	graph_slot(g)[i] = 1
	g.last[i] += 1
}

// Before the frame index advances: frames without a sample read 0.
@(private)
frame_time_add :: proc(ms: f32) {
	o := &s.overlay
	for g in o.graphs do if g.kind != .Frame do graph_slot(g)
	o.frames[o.frame_n % FRAME_HIST] = ms
	o.frame_n += 1
}

// ---- drawing

@(private)
overlay_update :: proc(slow: bool) {
	o := &s.overlay
	if slow {
		b := &o.text
		strings.builder_reset(b)
		last, avg, worst := frame_summary()
		fmt.sbprintf(b, "frame %5.2f ms  avg %5.2f  max %5.1f  ui %.2f", last, avg, worst, s.ui_ms)
		for line in s.stats do fmt.sbprintf(b, "\n%s", line)
		gd.Label_set_text(o.stats, strings.to_string(b^))
		for g in o.graphs do if o.groups[g.group].shown do graph_text(g)
	}
	o.w = clamp(int(gd.Control_get_size(o.graphs[0].ctl).x), 1, MAX_W)
	map_columns()
	for g in o.graphs {
		if !o.groups[g.group].shown do continue
		switch g.kind {
		case .Frame:
			draw_frame(g)
		case .Stack:
			draw_stack(g)
		case .Lines:
			draw_lines(g)
		case .Marks:
			draw_marks(g)
		}
	}
}

@(private)
graph_text :: proc(g: ^Graph) {
	switch g.kind {
	case .Frame:
	case .Stack:
		total: f32
		for i in 0 ..< g.n do total += g.last[i]
		gd.Label_set_text(g.title, fmt.tprintf("%s %s", g.name, num(total)))
		for i in 0 ..< g.n do gd.Label_set_text(g.legend[i], fmt.tprintf("%s %s", g.names[i], num(g.last[i])))
	case .Lines:
		if g.n == 1 {
			gd.Label_set_text(g.title, fmt.tprintf("%s %s", g.name, num(g.last[0])))
		} else {
			for i in 0 ..< g.n do gd.Label_set_text(g.legend[i], fmt.tprintf("%s %s", g.names[i], num(g.last[i])))
		}
	case .Marks:
		// each lane's count since the last update
		for i in 0 ..< g.n {
			n := int(g.last[i])
			gd.Label_set_text(g.legend[i], n > 0 ? fmt.tprintf("%s %d", g.names[i], n) : g.names[i])
			g.last[i] = 0
		}
	}
}

// A short number: about 3 significant digits.
@(private)
num :: proc(v: f32) -> string {
	a := abs(v)
	switch {
	case a >= 100:
		return fmt.tprintf("%.0f", v)
	case a >= 10:
		return fmt.tprintf("%.1f", v)
	}
	return fmt.tprintf("%.2f", v)
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

// Which frames each pixel column covers, newest at the right edge.
@(private)
map_columns :: proc() {
	o := &s.overlay
	for c in 0 ..< o.w do o.cols[c] = {1, 0}
	px_per_ms := f32(o.w) / FRAME_SPAN_MS
	x := f32(o.w)
	for i := o.frame_n - 1; i >= max(0, o.frame_n - FRAME_HIST) && x > 0; i -= 1 {
		x0 := x - o.frames[i % FRAME_HIST] * px_per_ms
		for c in max(int(x0), 0) ..< min(int(x + 0.999), o.w) {
			if o.cols[c][0] > o.cols[c][1] do o.cols[c] = {i, i}
			else do o.cols[c][0] = i
		}
		x = x0
	}
}

// The smallest of 1, 2, 5 x 10^k at or above v.
@(private)
nice_ceil :: proc(v: f32) -> f32 {
	if v <= 0 do return 1
	step: f32 = 1
	for step < v do step *= 10
	for step / 10 >= v do step /= 10
	if step / 5 >= v do return step / 5
	if step / 2 >= v do return step / 2
	return step
}

@(private)
FRAME_SCALES := [?]f32{2, 4.17, 8.33, 16.67, 33.33, 66.67, 133.3, 1000}

@(private)
draw_frame :: proc(g: ^Graph) {
	o := &s.overlay
	cols: [MAX_W]f32 // each column's longest frame
	worst: f32
	for c in 0 ..< o.w {
		for i in o.cols[c][0] ..= o.cols[c][1] do cols[c] = max(cols[c], o.frames[i % FRAME_HIST])
		worst = max(worst, cols[c])
	}
	top := FRAME_SCALES[len(FRAME_SCALES) - 1]
	for t in FRAME_SCALES {
		if worst <= t {
			top = t
			break
		}
	}
	quads_begin()
	for ms, c in cols[:o.w] {
		if ms <= 0 do continue
		col :=
			ms <= 16.7 ? gd.Color{0.4, 0.78, 0.45, 1} : ms <= 33.4 ? gd.Color{0.95, 0.75, 0.3, 1} : gd.Color{0.95, 0.35, 0.3, 1}
		h := min(ms / top, 1) * FRAME_H
		quad(f32(c), FRAME_H - h, 1, h, col)
	}
	quads_end(g)
	if top > 16.67 { 	// the 60 Hz budget, when it is on the scale
		y := FRAME_H - 16.67 / top * FRAME_H
		gd.RenderingServer_canvas_item_add_rect(s.rs, g.ci, {{0, y}, {f32(o.w), 1}}, {1, 1, 1, 0.25})
	}
}

@(private)
draw_stack :: proc(g: ^Graph) {
	o := &s.overlay
	best: [MAX_W]int // per column, the frame with the largest total
	top: f32
	for c in 0 ..< o.w {
		best[c] = -1
		bt: f32
		for i in o.cols[c][0] ..= o.cols[c][1] {
			t: f32
			for p in 0 ..< g.n do t += g.ring[i % FRAME_HIST][p]
			if t > bt {
				bt = t
				best[c] = i
			}
		}
		top = max(top, bt)
	}
	top = nice_ceil(top)
	quads_begin()
	for c in 0 ..< o.w {
		if best[c] < 0 do continue
		row := &g.ring[best[c] % FRAME_HIST]
		y := f32(LEGEND_H + GRAPH_H)
		for p in 0 ..< g.n {
			h := row[p] / top * GRAPH_H
			if h <= 0 do continue
			y -= h
			quad(f32(c), y, 1, h, PALETTE[p])
		}
	}
	quads_end(g)
}

@(private)
draw_lines :: proc(g: ^Graph) {
	o := &s.overlay
	vals: [MAX_W][MAX_PARTS]f32 // per column, each line's largest value
	has: [MAX_W]bool
	top: f32
	for c in 0 ..< o.w {
		for i in o.cols[c][0] ..= o.cols[c][1] {
			for p in 0 ..< g.n {
				v := g.ring[i % FRAME_HIST][p]
				vals[c][p] = has[c] ? max(vals[c][p], v) : v
				top = max(top, v)
			}
			has[c] = true
		}
	}
	lo, hi := g.lo, g.hi
	if lo == hi do lo, hi = 0, nice_ceil(top)
	gd.RenderingServer_canvas_item_clear(s.rs, g.ci)
	gd.RenderingServer_canvas_item_add_rect(s.rs, g.ci, {{0, 0}, {f32(o.w), LEGEND_H}}, {0, 0, 0, 0.45})
	gd.RenderingServer_canvas_item_add_rect(s.rs, g.ci, {{0, LEGEND_H}, {f32(o.w), GRAPH_H}}, {0, 0, 0, 0.3})
	gd.PackedColorArray_resize(&o.colors, 1)
	for p in 0 ..< g.n {
		gd.PackedVector2Array_resize(&o.points, o.w)
		pts := ([^]gd.Vector2)(gdi.packed_vector2_array_operator_index(&o.points, 0))
		n := 0
		for c in 0 ..< o.w {
			if !has[c] do continue
			v := clamp(vals[c][p], lo, hi)
			pts[n] = {f32(c), LEGEND_H + GRAPH_H - (v - lo) / (hi - lo) * (GRAPH_H - 1)}
			n += 1
		}
		if n < 2 do continue
		gd.PackedVector2Array_resize(&o.points, n)
		(^gd.Color)(gdi.packed_color_array_operator_index(&o.colors, 0))^ = PALETTE[p]
		gd.RenderingServer_canvas_item_add_polyline(s.rs, g.ci, o.points, o.colors, 1)
	}
}

@(private)
draw_marks :: proc(g: ^Graph) {
	o := &s.overlay
	quads_begin()
	for c in 0 ..< o.w {
		for p in 0 ..< g.n {
			for i in o.cols[c][0] ..= o.cols[c][1] {
				if g.ring[i % FRAME_HIST][p] > 0 {
					quad(f32(c), LEGEND_H + f32(p) * LANE_H, 1, LANE_H - 1, PALETTE[p])
					break
				}
			}
		}
	}
	quads_end(g)
}

// ---- batched quads: one triangle array per graph per frame

@(private)
quad_n: int

@(private)
quads_begin :: proc() {
	quad_n = 0
	o := &s.overlay
	gd.PackedVector2Array_resize(&o.points, MAX_W * MAX_PARTS * 4)
	gd.PackedColorArray_resize(&o.colors, MAX_W * MAX_PARTS * 4)
	gd.PackedInt32Array_resize(&o.indices, MAX_W * MAX_PARTS * 6)
}

// At most MAX_W * MAX_PARTS per graph (one per column and part).
@(private)
quad :: proc(x, y, w, h: f32, col: gd.Color) {
	o := &s.overlay
	if quad_n >= MAX_W * MAX_PARTS do return
	pts := ([^]gd.Vector2)(gdi.packed_vector2_array_operator_index(&o.points, 0))
	cls := ([^]gd.Color)(gdi.packed_color_array_operator_index(&o.colors, 0))
	idx := ([^]i32)(gdi.packed_int32_array_operator_index(&o.indices, 0))
	v := quad_n * 4
	pts[v + 0], pts[v + 1], pts[v + 2], pts[v + 3] = {x, y}, {x + w, y}, {x + w, y + h}, {x, y + h}
	for k in 0 ..< 4 do cls[v + k] = col
	b := i32(v)
	idx[quad_n * 6 + 0], idx[quad_n * 6 + 1], idx[quad_n * 6 + 2] = b, b + 1, b + 2
	idx[quad_n * 6 + 3], idx[quad_n * 6 + 4], idx[quad_n * 6 + 5] = b, b + 2, b + 3
	quad_n += 1
}

@(private)
quads_end :: proc(g: ^Graph) {
	o := &s.overlay
	gd.RenderingServer_canvas_item_clear(s.rs, g.ci)
	band: f32 = g.kind == .Frame ? 0 : LEGEND_H
	if band > 0 do gd.RenderingServer_canvas_item_add_rect(s.rs, g.ci, {{0, 0}, {f32(o.w), band}}, {0, 0, 0, 0.45})
	gd.RenderingServer_canvas_item_add_rect(s.rs, g.ci, {{0, band}, {f32(o.w), graph_h(g) - band}}, {0, 0, 0, 0.3})
	if quad_n == 0 do return
	gd.PackedVector2Array_resize(&o.points, quad_n * 4)
	gd.PackedColorArray_resize(&o.colors, quad_n * 4)
	gd.PackedInt32Array_resize(&o.indices, quad_n * 6)
	gd.RenderingServer_canvas_item_add_triangle_array(
		s.rs,
		g.ci,
		o.indices,
		o.points,
		o.colors,
		o.empty_v,
		o.empty_i,
		o.empty_f,
		{},
	)
}
