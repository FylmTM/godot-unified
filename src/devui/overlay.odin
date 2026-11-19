// The overlay, in a corner of the game window (top right until its corner button moves it to the next): the panel
// toggles, the graph-group toggles, the stats (10 Hz) and the graphs (every frame). Clicks go through it to the game,
// except on its buttons.
//
// Every graph shares one time axis, real time: each frame takes a width proportional to how long it lasted (the
// last FRAME_SPAN_MS), so a hitch covers as much of a graph as the time it cost, and the graphs line up with each
// other. A pixel column shows the frames that overlap it: the frame graph and stacks their longest frame, lines
// their largest value, marks any. Graphs belong to groups ("frame", "sim", "net", a game's own) the overlay toggles;
// only "frame" starts shown. Samples are recorded whatever is shown. Each graph's legend gives its parts' average per
// frame over the last second (marks: how many per second).
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
HIST_STEP_MS :: 0.1 // the frame-time histogram's bucket width
@(private)
HIST_BUCKETS :: 2000 // 0 to 200 ms; longer frames count in the last bucket (the max is kept exactly)

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
	ring:    [FRAME_HIST][MAX_PARTS]f32, // by frame index (Marks: 1 = set)
	written: int, // the frame index last written (a frame without a sample reads 0)
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
	panel:         gd.PanelContainer,
	box:           gd.VBoxContainer,
	buttons:       gd.VBoxContainer, // the toggle rows (the only part of the overlay that takes clicks)
	toggles:       [Panel_Kind]gd.Button,
	gbar:          gd.HBoxContainer, // the group toggles
	corner:        int, // where the overlay sits: 0 top right, 1 top left, 2 bottom left, 3 bottom right
	grid:          gd.GridContainer, // the stat lines: key, value
	keys:          [dynamic]gd.Label,
	vals:          [dynamic]gd.Label,
	// The value column only grows (numbers changing width don't move the overlay), until the set of lines changes.
	val_w:         f32,
	keys_id:       u64, // the shown lines' keys, hashed
	// frame times since the session started (or the frames line was clicked): its first line
	frames_button: gd.Button,
	hist:          [HIST_BUCKETS]u32,
	hist_n:        int,
	hist_max:      f32,
	frames:        [FRAME_HIST]f32, // ms, by frame index
	ends:          [FRAME_HIST]f64, // when each frame ended, ms since the first (the time axis)
	now_ms:        f64,
	frame_n:       int,
	graphs:        [dynamic]^Graph,
	groups:        [dynamic]Group,
	// per pixel column, the frames overlapping it (first ..= last, absolute indices; first > last: none)
	cols:          [MAX_W][2]int,
	w:             int,
	// scratch arrays (the RenderingServer copies them)
	points:        gd.PackedVector2Array,
	colors:        gd.PackedColorArray,
	indices:       gd.PackedInt32Array,
	empty_v:       gd.PackedVector2Array,
	empty_i:       gd.PackedInt32Array,
	empty_f:       gd.PackedFloat32Array,
}

@(private)
build_overlay :: proc() {
	overlay := &s.overlay
	overlay.panel = add(s.layer, gd.PanelContainer_new())
	gd.Control_set_theme(overlay.panel, s.theme)
	gd.Control_set_theme_type_variation(overlay.panel, "DevOverlay")
	gd.Control_set_mouse_filter(overlay.panel, .MOUSE_FILTER_IGNORE)
	gd.Control_set_custom_minimum_size(overlay.panel, {OVERLAY_W, 0})
	overlay.box = add(overlay.panel, gd.VBoxContainer_new())
	gd.Control_add_theme_constant_override(overlay.box, "separation", 6)
	gd.Control_set_mouse_filter(overlay.box, .MOUSE_FILTER_IGNORE)
	overlay.buttons = add(overlay.box, gd.VBoxContainer_new())
	gd.Control_set_mouse_filter(overlay.buttons, .MOUSE_FILTER_IGNORE)
	gd.Control_set_h_size_flags(overlay.buttons, .SIZE_SHRINK_END)
	button_row := add(overlay.buttons, gd.HBoxContainer_new())
	gd.BoxContainer_set_alignment(button_row, .ALIGNMENT_END)
	gd.Control_set_mouse_filter(button_row, .MOUSE_FILTER_IGNORE)
	corner_button := button(button_row, "◳", proc(_: rawptr, _: []^gd.Variant) -> gd.Variant {
		s.overlay.corner = (s.overlay.corner + 1) % 4
		overlay_place()
		return {}
	})
	gd.Control_set_theme_type_variation(corner_button, "DevToggle")
	gd.Control_set_tooltip_text(corner_button, "move to the next corner")
	names := [Panel_Kind]string {
		.Inspector  = "inspect",
		.Input      = "input",
		.Conditions = "conditions",
		.Events     = "events",
		.Commands   = "commands",
		.Note       = "note",
	}
	for kind in Panel_Kind {
		toggle := button(button_row, names[kind], proc(user: rawptr, _: []^gd.Variant) -> gd.Variant {
				kind := Panel_Kind(uintptr(user))
				if kind == .Note && !s.panels[kind].open do note_open()
				else do panel_open(kind, !s.panels[kind].open)
				return {}
			}, rawptr(uintptr(kind)))
		gd.BaseButton_set_toggle_mode(toggle, true)
		gd.Control_set_theme_type_variation(toggle, "DevToggle")
		overlay.toggles[kind] = toggle
	}
	overlay.gbar = add(overlay.buttons, gd.HBoxContainer_new())
	gd.BoxContainer_set_alignment(overlay.gbar, .ALIGNMENT_END)
	gd.Control_set_mouse_filter(overlay.gbar, .MOUSE_FILTER_IGNORE)
	overlay.grid = add(overlay.box, gd.GridContainer_new())
	gd.GridContainer_set_columns(overlay.grid, 2)
	gd.Control_set_mouse_filter(overlay.grid, .MOUSE_FILTER_IGNORE)
	gd.Control_add_theme_constant_override(overlay.grid, "h_separation", 8)
	gd.Control_add_theme_constant_override(overlay.grid, "v_separation", 0)
	frames_key := label(overlay.grid, "frames")
	gd.Control_set_theme_type_variation(frames_key, "DevKey")
	gd.Control_add_theme_font_override(frames_key, "font", s.mono)
	overlay.frames_button = button(
	overlay.grid,
	"",
	proc(_: rawptr, _: []^gd.Variant) -> gd.Variant {
		frames_reset()
		frames_text() // not stats_update: the stat lines were cleared at the end of the last frame
		return {}
	},
	)
	gd.Control_set_theme_type_variation(overlay.frames_button, "DevTitleButton")
	gd.Control_add_theme_font_override(overlay.frames_button, "font", s.mono)
	gd.Button_set_text_alignment(overlay.frames_button, .HORIZONTAL_ALIGNMENT_LEFT)
	overlay.points = gd.PackedVector2Array_new0()
	overlay.colors = gd.PackedColorArray_new0()
	overlay.indices = gd.PackedInt32Array_new0()
	overlay.empty_v = gd.PackedVector2Array_new0()
	overlay.empty_i = gd.PackedInt32Array_new0()
	overlay.empty_f = gd.PackedFloat32Array_new0()
	graph_make("frame", .Frame, "frame", 1)
}

@(private)
overlay_shutdown :: proc() {
	overlay := &s.overlay
	for graph in overlay.graphs {
		gd.RenderingServer_free_rid(s.rs, graph.ci)
		delete(graph.name)
		for name in graph.names do delete(name)
		free(graph)
	}
	delete(overlay.graphs)
	for entry in overlay.groups do delete(entry.name)
	delete(overlay.groups)
	delete(overlay.keys)
	delete(overlay.vals)
	gd.PackedVector2Array_destroy(&overlay.points)
	gd.PackedColorArray_destroy(&overlay.colors)
	gd.PackedInt32Array_destroy(&overlay.indices)
	gd.PackedVector2Array_destroy(&overlay.empty_v)
	gd.PackedInt32Array_destroy(&overlay.empty_i)
	gd.PackedFloat32Array_destroy(&overlay.empty_f)
}

// In its corner of the game window (◳ moves it on when the game's own UI is there).
@(private)
overlay_place :: proc() {
	gd.Control_reset_size(s.overlay.panel) // shrink to fit: graphs and lines come and go
	size := gd.Control_get_size(s.overlay.panel)
	right := s.overlay.corner == 0 || s.overlay.corner == 3
	bottom := s.overlay.corner >= 2
	gd.Control_set_position(s.overlay.panel, {right ? s.view.x - size.x - 4 : 4, bottom ? s.view.y - size.y - 4 : 4})
}

// The stat lines as a grid: a dim key, a monospace value (rows are kept and reused). The first line is the frame
// times since the session started.
@(private)
stats_update :: proc() {
	overlay := &s.overlay
	frames_text()
	for len(overlay.keys) < len(s.stats) {
		key_label := label(overlay.grid, "")
		gd.Control_set_theme_type_variation(key_label, "DevKey")
		gd.Control_add_theme_font_override(key_label, "font", s.mono)
		value_label := label(overlay.grid, "")
		gd.Control_add_theme_font_override(value_label, "font", s.mono)
		append(&overlay.keys, key_label)
		append(&overlay.vals, value_label)
	}
	for i in 0 ..< len(overlay.keys) {
		used := i < len(s.stats)
		gd.CanvasItem_set_visible(overlay.keys[i], used)
		gd.CanvasItem_set_visible(overlay.vals[i], used)
		if used {
			gd.Label_set_text(overlay.keys[i], s.stats[i][0])
			gd.Label_set_text(overlay.vals[i], s.stats[i][1])
		}
	}
	// The value column's width only grows while the same lines are shown (FNV-1a over their keys).
	keys_id: u64 = 0xcbf29ce484222325
	for line in s.stats {
		for byte in transmute([]u8)line[0] do keys_id = (keys_id ~ u64(byte)) * 0x100000001b3
		keys_id = (keys_id ~ 0xff) * 0x100000001b3
	}
	if keys_id != overlay.keys_id {
		overlay.keys_id = keys_id
		overlay.val_w = 0
	}
	width := gd.Control_get_minimum_size(overlay.frames_button).x
	for i in 0 ..< len(s.stats) do width = max(width, gd.Control_get_minimum_size(overlay.vals[i]).x)
	overlay.val_w = max(overlay.val_w, width)
	gd.Control_set_custom_minimum_size(overlay.frames_button, {overlay.val_w, 0})
}

// The frames line: p50, p99 and max since frames_reset.
@(private)
frames_text :: proc() {
	overlay := &s.overlay
	p50, p99 := frames_percentile(0.5), frames_percentile(0.99)
	gd.Button_set_text(
		overlay.frames_button,
		overlay.hist_n == 0 ? "-" : fmt.tprintf("p50 %s  p99 %s  max %s ms", num(p50), num(p99), num(overlay.hist_max)),
	)
}

// Restarts the frames line (p50, p99, max): the host calls it when a session starts; a click on the line does too.
frames_reset :: proc() {
	if !s.inited do return
	overlay := &s.overlay
	overlay.hist = {}
	overlay.hist_n, overlay.hist_max = 0, 0
}

// The frame time at or below which `fraction` of the frames since the reset were (a bucket's upper edge).
@(private)
frames_percentile :: proc(fraction: f32) -> f32 {
	overlay := &s.overlay
	if overlay.hist_n == 0 do return 0
	want := max(int(f32(overlay.hist_n) * fraction + 0.999), 1)
	seen := 0
	for count, bucket in overlay.hist {
		seen += int(count)
		if seen >= want do return min(f32(bucket + 1) * HIST_STEP_MS, overlay.hist_max)
	}
	return overlay.hist_max
}

// Whether the overlay shows the graph group `name`: a host shows a group's stat lines with its graphs.
group_shown :: proc(name: string) -> bool {
	if !s.inited do return false
	for entry in s.overlay.groups do if entry.name == name do return entry.shown
	return false
}

@(private)
overlay_sync_toggles :: proc() {
	for kind in Panel_Kind do gd.BaseButton_set_pressed_no_signal(s.overlay.toggles[kind], s.panels[kind].open)
}

// ---- graphs: creation and samples

@(private)
group_index :: proc(name: string) -> int {
	overlay := &s.overlay
	for entry, i in overlay.groups do if entry.name == name do return i
	entry := Group {
		name  = strings.clone(name),
		shown = name == "frame",
	}
	entry.toggle = button(overlay.gbar, name, proc(user: rawptr, _: []^gd.Variant) -> gd.Variant {
			i := int(uintptr(user))
			entry := &s.overlay.groups[i]
			entry.shown = !entry.shown
			gd.BaseButton_set_pressed_no_signal(entry.toggle, entry.shown)
			for graph in s.overlay.graphs do if graph.group == i do gd.CanvasItem_set_visible(graph.ctl, entry.shown)
			overlay_place()
			return {}
		}, rawptr(uintptr(len(overlay.groups))))
	gd.BaseButton_set_toggle_mode(entry.toggle, true)
	gd.BaseButton_set_pressed_no_signal(entry.toggle, entry.shown)
	gd.Control_set_theme_type_variation(entry.toggle, "DevToggle")
	append(&overlay.groups, entry)
	return len(overlay.groups) - 1
}

@(private)
graph_find :: proc(name: string) -> ^Graph {
	for graph in s.overlay.graphs do if graph.name == name do return graph
	return nil
}

// A graph control: the drawing underneath, the title and legend (one label per part) on top.
@(private)
graph_make :: proc(name: string, kind: Graph_Kind, group: string, count: int) -> ^Graph {
	overlay := &s.overlay
	graph := new(Graph)
	graph.name = strings.clone(name)
	graph.kind = kind
	graph.group = group_index(group)
	graph.n = clamp(count, 1, MAX_PARTS)
	graph.written = -1
	graph.ctl = add(overlay.box, gd.Control_new())
	gd.Control_set_custom_minimum_size(graph.ctl, {OVERLAY_W, graph_h(graph)})
	gd.Control_set_h_size_flags(graph.ctl, .SIZE_EXPAND_FILL)
	gd.Control_set_mouse_filter(graph.ctl, .MOUSE_FILTER_IGNORE)
	gd.CanvasItem_set_visible(graph.ctl, overlay.groups[graph.group].shown)
	graph.ci = gd.RenderingServer_canvas_item_create(s.rs)
	gd.RenderingServer_canvas_item_set_parent(s.rs, graph.ci, gd.CanvasItem_get_canvas_item(graph.ctl))
	row := add(graph.ctl, gd.HBoxContainer_new())
	gd.Control_set_position(row, {2, -1})
	gd.Control_set_mouse_filter(row, .MOUSE_FILTER_IGNORE)
	gd.Control_add_theme_constant_override(row, "separation", 6)
	graph.title = label(row, name)
	gd.Control_set_theme_type_variation(graph.title, "DevGraphLabel")
	if kind != .Frame {
		for i in 0 ..< MAX_PARTS {
			graph.legend[i] = label(row, "")
			gd.Control_set_theme_type_variation(graph.legend[i], "DevGraphLabel")
			gd.Control_add_theme_color_override(graph.legend[i], "font_color", PALETTE[i])
		}
	}
	append(&overlay.graphs, graph)
	return graph
}

@(private)
graph_h :: proc(graph: ^Graph) -> f32 {
	switch graph.kind {
	case .Frame:
		return LEGEND_H + FRAME_H
	case .Marks:
		return LEGEND_H + f32(MAX_PARTS) * LANE_H
	case .Lines, .Stack:
	}
	return LEGEND_H + GRAPH_H
}

// This frame's sample row of `g` (zeroed when first touched in a frame).
@(private)
graph_slot :: proc(graph: ^Graph) -> ^[MAX_PARTS]f32 {
	frame := s.overlay.frame_n
	row := &graph.ring[frame % FRAME_HIST]
	if graph.written != frame {
		row^ = {}
		graph.written = frame
	}
	return row
}

@(private)
graph_names :: proc(graph: ^Graph, legend: []string) {
	for name, i in legend[:min(len(legend), graph.n)] do graph.names[i] = strings.clone(name)
}

@(private)
graph_lines :: proc(name: string, values: []f32, legend: []string, group: string) {
	graph := graph_find(name)
	if graph == nil {
		graph = graph_make(name, .Lines, group, len(values))
		graph_names(graph, legend)
	}
	row := graph_slot(graph)
	for value, i in values[:min(len(values), graph.n)] do row[i] = value
}

@(private)
graph_stack :: proc(name: string, parts: []f32, legend: []string, group: string) {
	graph := graph_find(name)
	if graph == nil {
		graph = graph_make(name, .Stack, group, len(parts))
		graph_names(graph, legend)
	}
	row := graph_slot(graph)
	for value, i in parts[:min(len(parts), graph.n)] do row[i] = max(value, 0)
}

@(private)
graph_mark :: proc(strip, lane: string, group: string) {
	graph := graph_find(strip)
	if graph == nil {
		graph = graph_make(strip, .Marks, group, 1)
		graph.n = 0
	}
	i := 0
	for i < graph.n && graph.names[i] != lane do i += 1
	if i == graph.n {
		if graph.n == MAX_PARTS do return
		graph.names[i] = strings.clone(lane)
		graph.n += 1
	}
	graph_slot(graph)[i] = 1
}

// Before the frame index advances: frames without a sample read 0.
@(private)
frame_time_add :: proc(ms: f32) {
	overlay := &s.overlay
	for graph in overlay.graphs do if graph.kind != .Frame do graph_slot(graph)
	overlay.frames[overlay.frame_n % FRAME_HIST] = ms
	overlay.hist[min(int(ms / HIST_STEP_MS), HIST_BUCKETS - 1)] += 1
	overlay.hist_n += 1
	overlay.hist_max = max(overlay.hist_max, ms)
	overlay.now_ms += f64(ms)
	overlay.ends[overlay.frame_n % FRAME_HIST] = overlay.now_ms
	overlay.frame_n += 1
}

// ---- drawing

@(private)
overlay_update :: proc(slow: bool) {
	overlay := &s.overlay
	if slow {
		stats_update()
		for graph in overlay.graphs do if overlay.groups[graph.group].shown do graph_text(graph)
	}
	overlay.w = clamp(int(gd.Control_get_size(overlay.graphs[0].ctl).x), 1, MAX_W)
	map_columns()
	for graph in overlay.graphs {
		if !overlay.groups[graph.group].shown do continue
		switch graph.kind {
		case .Frame:
			draw_frame(graph)
		case .Stack:
			draw_stack(graph)
		case .Lines:
			draw_lines(graph)
		case .Marks:
			draw_marks(graph)
		}
	}
}

@(private)
graph_text :: proc(graph: ^Graph) {
	switch graph.kind {
	case .Frame:
		last, avg, worst, fps := frame_summary()
		gd.Label_set_text(
			graph.title,
			fmt.tprintf("%.0f fps   frame %.2f ms   avg %.2f   max %.1f", fps, last, avg, worst),
		)
	case .Stack:
		// per-frame averages over the last second (one frame alone may have no tick at all)
		mean, _ := recent(graph)
		total: f32
		for i in 0 ..< graph.n do total += mean[i]
		gd.Label_set_text(graph.title, fmt.tprintf("%s %s", graph.name, num(total)))
		for i in 0 ..< graph.n do gd.Label_set_text(graph.legend[i], fmt.tprintf("%s %s", graph.names[i], num(mean[i])))
	case .Lines:
		mean, _ := recent(graph)
		if graph.n == 1 {
			gd.Label_set_text(graph.title, fmt.tprintf("%s %s", graph.name, num(mean[0])))
		} else {
			for i in 0 ..< graph.n do gd.Label_set_text(graph.legend[i], fmt.tprintf("%s %s", graph.names[i], num(mean[i])))
		}
	case .Marks:
		// each lane's count in the last second
		_, counts := recent(graph)
		for i in 0 ..< graph.n {
			gd.Label_set_text(
				graph.legend[i],
				counts[i] > 0 ? fmt.tprintf("%s %d/s", graph.names[i], counts[i]) : graph.names[i],
			)
		}
	}
}

// A short number: about 3 significant digits.
@(private)
num :: proc(value: f32) -> string {
	magnitude := abs(value)
	switch {
	case magnitude >= 100:
		return fmt.tprintf("%.0f", value)
	case magnitude >= 10:
		return fmt.tprintf("%.1f", value)
	}
	return fmt.tprintf("%.2f", value)
}

// The last frame, and the average and longest of the last second, and how many frames it showed (per second).
@(private)
frame_summary :: proc() -> (last, avg, worst, fps: f32) {
	overlay := &s.overlay
	if overlay.frame_n == 0 do return
	last = overlay.frames[(overlay.frame_n - 1) % FRAME_HIST]
	sum: f32
	count := 0
	for i := overlay.frame_n - 1; i >= max(0, overlay.frame_n - FRAME_HIST) && sum < 1000; i -= 1 {
		ms := overlay.frames[i % FRAME_HIST]
		sum += ms
		worst = max(worst, ms)
		count += 1
	}
	avg = sum / f32(max(count, 1))
	fps = sum > 0 ? f32(count) * 1000 / sum : 0
	return
}

// Which frames each pixel column covers, newest at the right edge. Columns are fixed slices of absolute time (the
// frames' end times), so a column's frames don't change as the graph scrolls: it moves by whole columns instead of
// re-slicing every frame, which made the bars jump about.
@(private)
map_columns :: proc() {
	overlay := &s.overlay
	for column in 0 ..< overlay.w do overlay.cols[column] = {1, 0}
	ms_per_col := f64(FRAME_SPAN_MS) / f64(overlay.w)
	now_col := i64(overlay.now_ms / ms_per_col) // the column of the newest moment, drawn at the right edge
	for i := overlay.frame_n - 1; i >= max(0, overlay.frame_n - FRAME_HIST); i -= 1 {
		end := overlay.ends[i % FRAME_HIST]
		start := end - f64(overlay.frames[i % FRAME_HIST])
		last_col := i64(end / ms_per_col)
		if now_col - last_col >= i64(overlay.w) do break // older than the graph
		for col := i64(start / ms_per_col); col <= last_col; col += 1 {
			column := overlay.w - 1 - int(now_col - col)
			if column < 0 do continue
			if overlay.cols[column][0] > overlay.cols[column][1] do overlay.cols[column] = {i, i}
			else do overlay.cols[column][0] = i
		}
	}
}

// The smallest of 1, 2, 5 x 10^k at or above v.
@(private)
nice_ceil :: proc(value: f32) -> f32 {
	if value <= 0 do return 1
	step: f32 = 1
	for step < value do step *= 10
	for step / 10 >= value do step /= 10
	if step / 5 >= value do return step / 5
	if step / 2 >= value do return step / 2
	return step
}

@(private)
FRAME_SCALES := [?]f32{2, 4.17, 8.33, 16.67, 33.33, 66.67, 133.3, 1000}

@(private)
draw_frame :: proc(graph: ^Graph) {
	overlay := &s.overlay
	column_ms: [MAX_W]f32 // each column's longest frame
	worst: f32
	for column in 0 ..< overlay.w {
		for i in overlay.cols[column][0] ..= overlay.cols[column][1] do column_ms[column] = max(column_ms[column], overlay.frames[i % FRAME_HIST])
		worst = max(worst, column_ms[column])
	}
	top := FRAME_SCALES[len(FRAME_SCALES) - 1]
	for scale in FRAME_SCALES {
		if worst <= scale {
			top = scale
			break
		}
	}
	quads_begin()
	for ms, column in column_ms[:overlay.w] {
		if ms <= 0 do continue
		color :=
			ms <= 16.7 ? gd.Color{0.4, 0.78, 0.45, 1} : ms <= 33.4 ? gd.Color{0.95, 0.75, 0.3, 1} : gd.Color{0.95, 0.35, 0.3, 1}
		height := min(ms / top, 1) * FRAME_H
		quad(f32(column), LEGEND_H + FRAME_H - height, 1, height, color)
	}
	quads_end(graph)
	if top > 16.67 { 	// the 60 Hz budget, when it is on the scale
		y := LEGEND_H + FRAME_H - 16.67 / top * FRAME_H
		gd.RenderingServer_canvas_item_add_rect(s.rs, graph.ci, {{0, y}, {f32(overlay.w), 1}}, {1, 1, 1, 0.25})
	}
}

@(private)
draw_stack :: proc(graph: ^Graph) {
	overlay := &s.overlay
	best: [MAX_W]int // per column, the frame with the largest total
	top: f32
	for column in 0 ..< overlay.w {
		best[column] = -1
		best_total: f32
		for i in overlay.cols[column][0] ..= overlay.cols[column][1] {
			total: f32
			for part in 0 ..< graph.n do total += graph.ring[i % FRAME_HIST][part]
			if total > best_total {
				best_total = total
				best[column] = i
			}
		}
		top = max(top, best_total)
	}
	top = nice_ceil(top)
	quads_begin()
	for column in 0 ..< overlay.w {
		if best[column] < 0 do continue
		row := &graph.ring[best[column] % FRAME_HIST]
		y := f32(LEGEND_H + GRAPH_H)
		for part in 0 ..< graph.n {
			height := row[part] / top * GRAPH_H
			if height <= 0 do continue
			y -= height
			quad(f32(column), y, 1, height, PALETTE[part])
		}
	}
	quads_end(graph)
}

@(private)
draw_lines :: proc(graph: ^Graph) {
	overlay := &s.overlay
	vals: [MAX_W][MAX_PARTS]f32 // per column, each line's largest value
	has: [MAX_W]bool
	top: f32
	for column in 0 ..< overlay.w {
		for i in overlay.cols[column][0] ..= overlay.cols[column][1] {
			for part in 0 ..< graph.n {
				value := graph.ring[i % FRAME_HIST][part]
				vals[column][part] = has[column] ? max(vals[column][part], value) : value
				top = max(top, value)
			}
			has[column] = true
		}
	}
	top = nice_ceil(top) // from 0 to a round value above the largest shown
	gd.RenderingServer_canvas_item_clear(s.rs, graph.ci)
	graph_back(graph)
	gd.PackedColorArray_resize(&overlay.colors, 1)
	for part in 0 ..< graph.n {
		gd.PackedVector2Array_resize(&overlay.points, overlay.w)
		pts := ([^]gd.Vector2)(gdi.packed_vector2_array_operator_index(&overlay.points, 0))
		count := 0
		for column in 0 ..< overlay.w {
			if !has[column] do continue
			pts[count] = {f32(column), LEGEND_H + GRAPH_H - vals[column][part] / top * (GRAPH_H - 1)}
			count += 1
		}
		if count < 2 do continue
		gd.PackedVector2Array_resize(&overlay.points, count)
		(^gd.Color)(gdi.packed_color_array_operator_index(&overlay.colors, 0))^ = PALETTE[part]
		gd.RenderingServer_canvas_item_add_polyline(s.rs, graph.ci, overlay.points, overlay.colors, 1)
	}
}

@(private)
draw_marks :: proc(graph: ^Graph) {
	overlay := &s.overlay
	quads_begin()
	for column in 0 ..< overlay.w {
		for part in 0 ..< graph.n {
			for i in overlay.cols[column][0] ..= overlay.cols[column][1] {
				if graph.ring[i % FRAME_HIST][part] > 0 {
					quad(f32(column), LEGEND_H + f32(part) * LANE_H, 1, LANE_H - 1, PALETTE[part])
					break
				}
			}
		}
	}
	quads_end(graph)
}

// ---- batched quads: one triangle array per graph per frame

@(private)
Quad :: struct {
	rect:  [4]f32, // x, y, width, height
	color: gd.Color,
}

// This graph's quads (at most one per column and part), gathered first so the packed arrays are sized once: a graph
// that draws as many quads as last frame resizes nothing.
@(private)
quads: [MAX_W * MAX_PARTS]Quad
@(private)
quad_n: int

@(private)
quads_begin :: proc() {
	quad_n = 0
}

@(private)
quad :: proc(x, y, width, height: f32, color: gd.Color) {
	if quad_n >= len(quads) do return
	quads[quad_n] = {{x, y, width, height}, color}
	quad_n += 1
}

@(private)
quads_end :: proc(graph: ^Graph) {
	overlay := &s.overlay
	gd.RenderingServer_canvas_item_clear(s.rs, graph.ci)
	graph_back(graph)
	if quad_n == 0 do return
	if int(gd.PackedVector2Array_size(&overlay.points)) != quad_n * 4 {
		gd.PackedVector2Array_resize(&overlay.points, quad_n * 4)
		gd.PackedColorArray_resize(&overlay.colors, quad_n * 4)
		gd.PackedInt32Array_resize(&overlay.indices, quad_n * 6)
	}
	pts := ([^]gd.Vector2)(gdi.packed_vector2_array_operator_index(&overlay.points, 0))
	colors := ([^]gd.Color)(gdi.packed_color_array_operator_index(&overlay.colors, 0))
	indices := ([^]i32)(gdi.packed_int32_array_operator_index(&overlay.indices, 0))
	for item, n in quads[:quad_n] {
		x, y, width, height := item.rect[0], item.rect[1], item.rect[2], item.rect[3]
		vertex := n * 4
		pts[vertex + 0], pts[vertex + 1], pts[vertex + 2], pts[vertex + 3] =
			{x, y}, {x + width, y}, {x + width, y + height}, {x, y + height}
		for k in 0 ..< 4 do colors[vertex + k] = item.color
		base := i32(vertex)
		indices[n * 6 + 0], indices[n * 6 + 1], indices[n * 6 + 2] = base, base + 1, base + 2
		indices[n * 6 + 3], indices[n * 6 + 4], indices[n * 6 + 5] = base, base + 2, base + 3
	}
	gd.RenderingServer_canvas_item_add_triangle_array(
		s.rs,
		graph.ci,
		overlay.indices,
		overlay.points,
		overlay.colors,
		overlay.empty_v,
		overlay.empty_i,
		overlay.empty_f,
		{},
	)
}

// A graph's background: a thin rule on top (it separates the graphs), the legend band, the plot area.
@(private)
graph_back :: proc(graph: ^Graph) {
	w := f32(s.overlay.w)
	gd.RenderingServer_canvas_item_add_rect(s.rs, graph.ci, {{0, 0}, {w, LEGEND_H}}, {1, 1, 1, 0.06})
	gd.RenderingServer_canvas_item_add_rect(s.rs, graph.ci, {{0, 0}, {w, 1}}, {1, 1, 1, 0.14})
	gd.RenderingServer_canvas_item_add_rect(
		s.rs,
		graph.ci,
		{{0, LEGEND_H}, {w, graph_h(graph) - LEGEND_H}},
		{0, 0, 0, 0.35},
	)
}

// Over the last second: each part's mean per frame, and how many frames had it set (marks).
@(private)
recent :: proc(graph: ^Graph) -> (mean: [MAX_PARTS]f32, count: [MAX_PARTS]int) {
	overlay := &s.overlay
	frames := 0
	for i := overlay.frame_n - 1; i >= max(0, overlay.frame_n - FRAME_HIST); i -= 1 {
		if overlay.now_ms - overlay.ends[i % FRAME_HIST] >= 1000 do break
		for part in 0 ..< graph.n {
			value := graph.ring[i % FRAME_HIST][part]
			mean[part] += value
			if value > 0 do count[part] += 1
		}
		frames += 1
	}
	for part in 0 ..< graph.n do mean[part] /= f32(max(frames, 1))
	return
}
