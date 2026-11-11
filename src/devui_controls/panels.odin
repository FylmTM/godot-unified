// The top bar, the overlay (stats and graphs), Netsim, the event log and the F3 note, as Godot controls.
package devui_controls

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import gd "unified:gdext"
import "unified:gdext/gdi"

// ---- top bar: the panel toggles, and "OS windows" (panels as native windows)

@(private)
build_bar :: proc() {
	s.bar = add(s.layer, gd.PanelContainer_new())
	gd.Control_set_theme(s.bar, s.theme)
	gd.Control_set_anchors_and_offsets_preset(s.bar, .PRESET_TOP_WIDE)
	row := add(s.bar, gd.HBoxContainer_new())
	label(row, "unified dev  (F1 hide, F3 note)")
	names := [Panel]string {
		.Inspector = "Inspector",
		.Netsim    = "Netsim",
		.Events    = "Events",
		.Note      = "",
	}
	for p in Panel {
		if names[p] == "" do continue
		b := button(row, names[p], proc(user: rawptr, _: []^gd.Variant) -> gd.Variant {
				p := Panel(uintptr(user))
				set_open(p, !s.open[p])
				return {}
			}, rawptr(uintptr(p)))
		gd.BaseButton_set_toggle_mode(b, true)
		gd.BaseButton_set_pressed_no_signal(b, s.open[p])
		s.toggles[p] = b
	}
	gd.BoxContainer_add_spacer(row, false)
	s.native_btn = button(row, "OS windows", proc(_: rawptr, _: []^gd.Variant) -> gd.Variant {
		set_native(!s.native)
		return {}
	})
	gd.BaseButton_set_toggle_mode(s.native_btn, true)
}

// Panels as OS windows or embedded ones. A native window's position is on the screen, an embedded one's in the
// game window: shift by the game window's position when switching.
@(private)
set_native :: proc(on: bool) {
	if on == s.native do return
	s.native = on
	origin := gd.Window_get_position(s.root)
	for p in Panel {
		w := s.windows[p]
		was := gd.Window_is_visible(w)
		gd.Window_set_visible(w, false)
		gd.Window_set_force_native(w, on)
		pos := gd.Window_get_position(w)
		d := on ? 1 : -1
		gd.Window_set_position(w, {pos.x + i32(d) * origin.x, pos.y + i32(d) * origin.y})
		gd.Window_set_visible(w, was)
	}
	gd.BaseButton_set_pressed_no_signal(s.native_btn, on)
}

// ---- overlay: stats (10 Hz) and graphs (every frame); clicks go through it to the game

@(private)
GRAPH_LEN :: 240
@(private)
GRAPH_H :: 36

@(private)
Graph :: struct {
	name:     string,
	min, max: f32,
	values:   [GRAPH_LEN]f32,
	head:     int,
	last:     f32,
	label:    gd.Label,
	ctl:      gd.Control,
	ci:       gd.RID, // our own canvas item under the control's (Godot never clears it)
}

@(private)
Overlay :: struct {
	panel:  gd.PanelContainer,
	box:    gd.VBoxContainer,
	stats:  gd.Label,
	text:   strings.Builder,
	graphs: [dynamic]Graph,
	points: gd.PackedVector2Array,
	colors: gd.PackedColorArray,
}

@(private)
build_overlay :: proc() {
	o := &s.overlay
	o.panel = add(s.layer, gd.PanelContainer_new())
	gd.Control_set_theme(o.panel, s.theme)
	gd.Control_set_position(o.panel, {8, 36})
	gd.Control_set_mouse_filter(o.panel, .MOUSE_FILTER_IGNORE)
	o.box = add(o.panel, gd.VBoxContainer_new())
	gd.Control_set_mouse_filter(o.box, .MOUSE_FILTER_IGNORE)
	o.stats = label(o.box, "")
	o.points = gd.PackedVector2Array_new0()
	o.colors = gd.PackedColorArray_new0()
	gd.PackedColorArray_resize(&o.colors, 1)
	(^gd.Color)(gdi.packed_color_array_operator_index(&o.colors, 0))^ = {0.55, 0.8, 1, 1}
}

@(private)
overlay_shutdown :: proc() {
	o := &s.overlay
	for &g in o.graphs {
		gd.RenderingServer_free_rid(s.rs, g.ci)
		delete(g.name)
	}
	delete(o.graphs)
	strings.builder_destroy(&o.text)
	gd.PackedVector2Array_destroy(&o.points)
	gd.PackedColorArray_destroy(&o.colors)
}

@(private)
graph_add :: proc(name: string, v: f32, lo, hi: f32) {
	o := &s.overlay
	for &g in o.graphs {
		if g.name == name {
			g.values[g.head] = v
			g.head = (g.head + 1) % GRAPH_LEN
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
	g.ctl = add(o.box, gd.Control_new())
	gd.Control_set_custom_minimum_size(g.ctl, {GRAPH_LEN, GRAPH_H})
	gd.Control_set_mouse_filter(g.ctl, .MOUSE_FILTER_IGNORE)
	g.ci = gd.RenderingServer_canvas_item_create(s.rs)
	gd.RenderingServer_canvas_item_set_parent(s.rs, g.ci, gd.CanvasItem_get_canvas_item(g.ctl))
	append(&o.graphs, g)
}

@(private)
overlay_update :: proc(slow: bool) {
	o := &s.overlay
	if slow {
		b := &o.text
		strings.builder_reset(b)
		fmt.sbprintf(b, "frame %.1f ms  ui %.2f ms", s.frame_ms, s.ui_ms)
		for line in s.stats do fmt.sbprintf(b, "\n%s", line)
		gd.Label_set_text(o.stats, strings.to_string(b^))
		for &g in o.graphs do gd.Label_set_text(g.label, fmt.tprintf("%s %.1f", g.name, g.last))
	}
	gd.PackedVector2Array_resize(&o.points, GRAPH_LEN)
	pts := ([^]gd.Vector2)(gdi.packed_vector2_array_operator_index(&o.points, 0))
	for &g in o.graphs {
		lo, hi := g.min, g.max
		if lo == hi { 	// auto scale
			lo, hi = max(f32), -max(f32)
			for v in g.values {
				lo = min(lo, v)
				hi = max(hi, v)
			}
			if hi <= lo do hi = lo + 1
		}
		for i in 0 ..< GRAPH_LEN {
			v := clamp(g.values[(g.head + i) % GRAPH_LEN], lo, hi)
			pts[i] = {f32(i), GRAPH_H - (v - lo) / (hi - lo) * GRAPH_H}
		}
		gd.RenderingServer_canvas_item_clear(s.rs, g.ci)
		gd.RenderingServer_canvas_item_add_rect(s.rs, g.ci, {{0, 0}, {GRAPH_LEN, GRAPH_H}}, {0, 0, 0, 0.35})
		gd.RenderingServer_canvas_item_add_polyline(s.rs, g.ci, o.points, o.colors, 1)
	}
}

// ---- netsim

@(private)
Netsim_Panel :: struct {
	enabled: gd.CheckBox,
	sliders: [3]gd.HSlider,
	values:  [3]gd.Label,
}

@(private)
NET_SLIDERS := [3]struct {
	name:   string,
	max:    f64,
	format: string,
}{{"latency", 300, "%.0f ms"}, {"jitter", 50, "%.0f ms"}, {"loss", 20, "%.1f %%"}}

@(private)
build_netsim :: proc() {
	n := &s.net
	box := add(make_window(.Netsim, "Netsim", {380, 40, 320, 190}), gd.VBoxContainer_new())
	n.enabled = add(box, gd.CheckBox_new())
	gd.Button_set_text(n.enabled, "enabled")
	on(n.enabled, "toggled", proc(_: rawptr, args: []^gd.Variant) -> gd.Variant {
		netsim.enabled, _ = gd.from_variant(bool, args[0])
		netsim_changed = true
		return {}
	})
	for sl, i in NET_SLIDERS {
		row := add(box, gd.HBoxContainer_new())
		l := label(row, sl.name)
		gd.Control_set_custom_minimum_size(l, {70, 0})
		h := add(row, gd.HSlider_new())
		gd.Control_set_h_size_flags(h, .SIZE_EXPAND_FILL)
		gd.Range_set_max(h, sl.max)
		gd.Range_set_step(h, i == 2 ? 0.1 : 1)
		on(h, "value_changed", proc(user: rawptr, args: []^gd.Variant) -> gd.Variant {
				v, _ := gd.from_variant(f64, args[0])
				field := netsim_field(int(uintptr(user)))
				field^ = f32(v)
				netsim_changed = true
				netsim_labels()
				return {}
			}, rawptr(uintptr(i)))
		n.sliders[i] = h
		n.values[i] = label(row, "")
		gd.Control_set_custom_minimum_size(n.values[i], {64, 0})
	}
	row := add(box, gd.HBoxContainer_new())
	PRESETS := [4]string{"LAN", "WAN", "Bad Wi-Fi", "Off"}
	for name, i in PRESETS {
		button(row, name, proc(user: rawptr, _: []^gd.Variant) -> gd.Variant {
				switch int(uintptr(user)) {
				case 0:
					netsim = {true, 2, 1, 0}
				case 1:
					netsim = {true, 60, 10, 1}
				case 2:
					netsim = {true, 140, 40, 6}
				case:
					netsim.enabled = false
				}
				netsim_changed = true
				netsim_sync()
				return {}
			}, rawptr(uintptr(i)))
	}
}

@(private)
netsim_field :: proc(i: int) -> ^f32 {
	switch i {
	case 0:
		return &netsim.latency_ms
	case 1:
		return &netsim.jitter_ms
	}
	return &netsim.loss_pct
}

// The widgets from `netsim` (the host or a preset changed it).
@(private)
netsim_sync :: proc() {
	n := &s.net
	gd.BaseButton_set_pressed_no_signal(n.enabled, netsim.enabled)
	for i in 0 ..< 3 do gd.Range_set_value_no_signal(n.sliders[i], f64(netsim_field(i)^))
	netsim_labels()
}

@(private)
netsim_labels :: proc() {
	for sl, i in NET_SLIDERS do gd.Label_set_text(s.net.values[i], fmt.tprintf(sl.format, netsim_field(i)^))
}

// ---- event log: a two-column Tree, rows appended as they come (the newest LOG_ROWS kept)

@(private)
Events_Panel :: struct {
	follow: gd.CheckBox,
	count:  gd.Label,
	tree:   gd.Tree,
	root:   gd.TreeItem,
	rows:   int, // rows in the tree
	shown:  int, // log_n when last synced
}

@(private)
build_events :: proc() {
	e := &s.events
	box := add(make_window(.Events, "Events", {8, 640, 540, 230}), gd.VBoxContainer_new())
	row := add(box, gd.HBoxContainer_new())
	e.follow = add(row, gd.CheckBox_new())
	gd.Button_set_text(e.follow, "follow")
	gd.BaseButton_set_pressed_no_signal(e.follow, true)
	e.count = label(row, "")
	e.tree = add(box, gd.Tree_new())
	gd.Control_set_v_size_flags(e.tree, .SIZE_EXPAND_FILL)
	gd.Tree_set_columns(e.tree, 2)
	gd.Tree_set_column_titles_visible(e.tree, true)
	gd.Tree_set_column_title(e.tree, 0, "tick")
	gd.Tree_set_column_title(e.tree, 1, "event")
	gd.Tree_set_column_expand(e.tree, 0, false)
	gd.Tree_set_column_custom_minimum_width(e.tree, 0, 70)
	gd.Tree_set_hide_root(e.tree, true)
	e.root = gd.Tree_create_item(e.tree)
}

@(private)
events_update :: proc() {
	e := &s.events
	if e.shown == s.log_n do return
	first := max(e.shown, s.log_n - LOG_ROWS)
	if s.log_n - e.shown > LOG_ROWS {
		gd.Tree_clear(e.tree)
		e.root = gd.Tree_create_item(e.tree)
		e.rows = 0
	}
	last: gd.TreeItem
	for i in first ..< s.log_n {
		r := &s.logs[i % LOG_ROWS]
		last = gd.Tree_create_item(e.tree, e.root)
		gd.TreeItem_set_text(last, 0, fmt.tprint(r.tick))
		gd.TreeItem_set_text(last, 1, string(r.msg[:r.len]))
		e.rows += 1
	}
	for e.rows > LOG_ROWS {
		gdi.object_destroy(gd.TreeItem_get_first_child(e.root).ptr)
		e.rows -= 1
	}
	e.shown = s.log_n
	gd.Label_set_text(e.count, fmt.tprintf("%d events", s.log_n))
	if gd.BaseButton_is_pressed(e.follow) do gd.Tree_scroll_to_item(e.tree, last)
}

// ---- F3 feedback note

@(private)
Note :: struct {
	thumb:   gd.TextureRect,
	text:    gd.TextEdit,
	tag_bug: gd.CheckBox,
	sent_l:  gd.Label,
	sent:    int,
	png:     string, // screenshot of this note, in the temp dir until sent
	tex:     gd.Ref(gd.ImageTexture),
}

@(private)
build_note :: proc() {
	n := &s.note
	m := make_window(.Note, "Feedback (F3)", {300, 80, 360, 420})
	box := add(m, gd.VBoxContainer_new())
	n.thumb = add(box, gd.TextureRect_new())
	label(box, "What happened? (Enter sends, Ctrl+Enter = new line)")
	n.text = add(box, gd.TextEdit_new())
	gd.Control_set_custom_minimum_size(n.text, {320, 80})
	gd.Control_set_v_size_flags(n.text, .SIZE_EXPAND_FILL)
	// the signal comes before TextEdit's own handling, so Enter can be taken here
	on(n.text, "gui_input", proc(_: rawptr, args: []^gd.Variant) -> gd.Variant {
		obj, _ := gd.from_variant(gd.Object, args[0])
		k := gd.object_cast(gd.InputEventKey, obj, "InputEventKey")
		if k.ptr == nil || !gd.InputEvent_is_pressed(k) do return {}
		key := gd.InputEventKey_get_keycode(k)
		if (key == .KEY_ENTER || key == .KEY_KP_ENTER) && !gd.InputEventWithModifiers_is_command_or_control_pressed(k) {
			gd.Control_accept_event(s.note.text)
			note_send()
		}
		return {}
	})
	n.tag_bug = add(box, gd.CheckBox_new())
	gd.Button_set_text(n.tag_bug, "tag as bug")
	row := add(box, gd.HBoxContainer_new())
	button(row, "Send", proc(_: rawptr, _: []^gd.Variant) -> gd.Variant {note_send(); return {}})
	button(row, "Cancel", proc(_: rawptr, _: []^gd.Variant) -> gd.Variant {set_open(.Note, false); return {}})
	n.sent_l = label(row, "")
}

@(private)
note_open :: proc() {
	n := &s.note
	// Capture before the note covers the frame.
	tex: gd.Ref(gd.ViewportTexture) = gd.Viewport_get_texture(s.root)
	defer gd.unref(tex)
	img := gd.Texture2D_get_image(tex)
	defer gd.unref(img)
	if img.ptr == nil do return
	delete(n.png)
	n.png = fmt.aprintf("%s/devui-f3-%d.png", gd.OS_get_cache_dir(gd.OS_singleton()), time.now()._nsec)
	gd.Image_save_png(img, n.png)
	w := gd.Image_get_width(img)
	h := gd.Image_get_height(img)
	gd.Image_resize(img, 320, 320 * h / max(w, 1))
	if n.tex.ptr == nil {
		n.tex = gd.ImageTexture_create_from_image(img)
	} else {
		gd.ImageTexture_set_image(n.tex, img)
	}
	gd.TextureRect_set_texture(n.thumb, n.tex)
	visible = true
	if !s.shown do set_shown(true)
	set_open(.Note, true)
	gd.Object_call_deferred(n.text, "grab_focus")
}

@(private)
note_shutdown :: proc() {
	if s.note.tex.ptr != nil do gd.unref(s.note.tex)
	delete(s.note.png)
}

@(private)
note_send :: proc() {
	n := &s.note
	text := gd.TextEdit_get_text(n.text)
	tag_bug := gd.BaseButton_is_pressed(n.tag_bug)
	stamp := time.now()
	y, mo, d := time.date(stamp)
	hh, mm, ss := time.clock(stamp)
	dir := fmt.tprintf("%s/%04d%02d%02d-%02d%02d%02d", s.cfg.feedback_dir, y, int(mo), d, hh, mm, ss)
	if err := os.make_directory_all(dir); err != nil {
		gd.print_error(fmt.tprintf("devui: cannot create %s: %v", dir, err))
		return
	}
	if n.png != "" do os.rename(n.png, fmt.tprintf("%s/screenshot.png", dir))
	body := fmt.tprintf("%s\n%s", tag_bug ? "[bug]" : "[note]", text)
	_ = os.write_entire_file(fmt.tprintf("%s/note.txt", dir), transmute([]u8)body)
	if s.cfg.on_feedback != nil do s.cfg.on_feedback(dir, text, tag_bug, s.cfg.user)
	gd.print(fmt.tprintf("devui: feedback saved to %s", dir))
	n.sent += 1
	gd.Label_set_text(n.sent_l, fmt.tprintf("sent: %d", n.sent))
	gd.TextEdit_set_text(n.text, "")
	set_open(.Note, false)
	delete(n.png)
	n.png = ""
}
