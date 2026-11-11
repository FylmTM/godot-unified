// The Netsim, Events and F3 note panels.
package devui

import "core:fmt"
import "core:os"
import "core:time"
import gd "unified:gdext"
import "unified:gdext/gdi"

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
	box := gd.VBoxContainer_new()
	row := add(box, gd.HBoxContainer_new())
	n.enabled = check(row, "on")
	on(n.enabled, "toggled", proc(_: rawptr, args: []^gd.Variant) -> gd.Variant {
		netsim.enabled, _ = gd.from_variant(bool, args[0])
		netsim_changed = true
		return {}
	})
	PRESETS := [4]string{"LAN", "WAN", "bad Wi-Fi", "off"}
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
	for sl, i in NET_SLIDERS {
		line := add(box, gd.HBoxContainer_new())
		l := label(line, sl.name)
		gd.Control_set_custom_minimum_size(l, {48, 0})
		h := add(line, gd.HSlider_new())
		gd.Control_set_h_size_flags(h, .SIZE_EXPAND_FILL)
		gd.Control_set_v_size_flags(h, .SIZE_SHRINK_CENTER)
		gd.Control_set_focus_mode(h, .FOCUS_NONE)
		gd.Range_set_max(h, sl.max)
		gd.Range_set_step(h, i == 2 ? 0.1 : 1)
		on(h, "value_changed", proc(user: rawptr, args: []^gd.Variant) -> gd.Variant {
				v, _ := gd.from_variant(f64, args[0])
				netsim_field(int(uintptr(user)))^ = f32(v)
				netsim_changed = true
				netsim_labels()
				return {}
			}, rawptr(uintptr(i)))
		n.sliders[i] = h
		n.values[i] = label(line, "")
		gd.Control_set_custom_minimum_size(n.values[i], {48, 0})
	}
	panel_make(.Netsim, "Netsim", {380, 40, 300, 106}, box)
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
	e.tree = gd.Tree_new()
	gd.Tree_set_columns(e.tree, 2)
	gd.Tree_set_column_expand(e.tree, 0, false)
	gd.Tree_set_column_custom_minimum_width(e.tree, 0, 48)
	gd.Tree_set_hide_root(e.tree, true)
	gd.Control_set_focus_mode(e.tree, .FOCUS_NONE)
	e.root = gd.Tree_create_item(e.tree)
	panel_make(.Events, "Events", {8, 520, 480, 170}, e.tree)
	// in the title bar: the count and "follow"
	bar := s.panels[.Events].extras
	e.count = label(bar, "")
	e.follow = check(bar, "follow")
	gd.BaseButton_set_pressed_no_signal(e.follow, true)
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
		if last.ptr == nil do return // the tree refuses rows inside its own mouse handling: next frame
		gd.TreeItem_set_text(last, 0, fmt.tprint(r.tick))
		gd.TreeItem_set_text(last, 1, string(r.msg[:r.len]))
		e.rows += 1
		e.shown = i + 1
	}
	for e.rows > LOG_ROWS {
		gdi.object_destroy(gd.TreeItem_get_first_child(e.root).ptr)
		e.rows -= 1
	}
	gd.Label_set_text(e.count, fmt.tprint(s.log_n))
	if gd.BaseButton_is_pressed(e.follow) && last.ptr != nil do gd.Tree_scroll_to_item(e.tree, last)
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
NOTE_THUMB_W :: 640 // the screenshot kept for the note (it scales with the panel, aspect kept)

@(private)
build_note :: proc() {
	n := &s.note
	box := gd.VBoxContainer_new()
	n.thumb = add(box, gd.TextureRect_new())
	gd.TextureRect_set_expand_mode(n.thumb, .EXPAND_IGNORE_SIZE)
	gd.TextureRect_set_stretch_mode(n.thumb, .STRETCH_KEEP_ASPECT_CENTERED)
	gd.Control_set_custom_minimum_size(n.thumb, {160, 90})
	gd.Control_set_v_size_flags(n.thumb, .SIZE_EXPAND_FILL)
	gd.Control_set_stretch_ratio(n.thumb, 3)
	n.text = add(box, gd.TextEdit_new())
	gd.TextEdit_set_placeholder(n.text, "what happened?")
	gd.Control_set_custom_minimum_size(n.text, {160, 54})
	gd.Control_set_v_size_flags(n.text, .SIZE_EXPAND_FILL)
	// Enter sends, Ctrl+Enter is TextEdit's own new line. The signal comes before TextEdit handles the key.
	on(n.text, "gui_input", proc(_: rawptr, args: []^gd.Variant) -> gd.Variant {
		k := event_arg(gd.InputEventKey, args, "InputEventKey")
		if k.ptr == nil || !gd.InputEvent_is_pressed(k) do return {}
		key := gd.InputEventKey_get_keycode(k)
		if (key == .KEY_ENTER || key == .KEY_KP_ENTER) && !gd.InputEventWithModifiers_is_command_or_control_pressed(k) {
			gd.Control_accept_event(s.note.text)
			note_send()
		}
		return {}
	})
	row := add(box, gd.HBoxContainer_new())
	n.tag_bug = check(row, "bug")
	n.sent_l = label(row, "")
	gd.Control_set_h_size_flags(n.sent_l, .SIZE_EXPAND_FILL)
	button(row, "send", proc(_: rawptr, _: []^gd.Variant) -> gd.Variant {note_send(); return {}})
	panel_make(.Note, "Feedback", {300, 40, 560, 440}, box)
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
	gd.Image_resize(img, NOTE_THUMB_W, NOTE_THUMB_W * h / max(w, 1))
	if n.tex.ptr == nil {
		n.tex = gd.ImageTexture_create_from_image(img)
	} else {
		gd.ImageTexture_set_image(n.tex, img)
	}
	gd.TextureRect_set_texture(n.thumb, n.tex)
	visible = true
	if !s.shown do set_shown(true)
	panel_open(.Note, true)
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
	gd.Label_set_text(n.sent_l, fmt.tprintf("sent %d", n.sent))
	gd.TextEdit_set_text(n.text, "")
	panel_open(.Note, false)
	delete(n.png)
	n.png = ""
}
