// The Conditions, Events and F3 note panels.
package devui

import "core:fmt"
import "core:os"
import "core:time"
import gd "unified:gdext"
import "unified:gdext/gdi"

// ---- conditions: a frame-rate cap and the network simulation, per direction

@(private)
Conditions_Panel :: struct {
	fps:     [len(FPS_CAPS)]gd.Button,
	cap:     int, // the current cap (0: none)
	enabled: gd.CheckBox,
	both:    gd.CheckBox, // the sliders move both directions together
	sliders: [2][3]gd.HSlider, // [up, down][latency, jitter, loss]
	values:  [2][3]gd.Label,
}

@(private)
FPS_CAPS := [?]int{0, 144, 60, 30, 15} // Engine.max_fps (0: none)

@(private)
NET_FIELDS := [3]struct {
	name:   string,
	max:    f64,
	step:   f64,
	format: string,
}{{"latency", 300, 1, "%.0f ms"}, {"jitter", 50, 1, "%.0f ms"}, {"loss", 20, 0.1, "%.1f %%"}}

@(private)
build_conditions :: proc() {
	conditions := &s.cond
	box := gd.VBoxContainer_new()
	row := add(box, gd.HBoxContainer_new())
	caption := label(row, "fps cap")
	gd.Control_set_custom_minimum_size(caption, {52, 0})
	for fps_cap, i in FPS_CAPS {
		fps_button := button(
			row,
			fps_cap == 0 ? "none" : fmt.tprint(fps_cap),
			proc(user: rawptr, _: []^gd.Variant) -> gd.Variant {
				s.cond.cap = FPS_CAPS[int(uintptr(user))]
				gd.Engine_set_max_fps(gd.Engine_singleton(), s.cond.cap)
				conditions_sync()
				return {}
			},
			rawptr(uintptr(i)),
		)
		gd.BaseButton_set_toggle_mode(fps_button, true)
		conditions.fps[i] = fps_button
	}
	row = add(box, gd.HBoxContainer_new())
	conditions.enabled = check(row, "netsim")
	on(conditions.enabled, "toggled", proc(_: rawptr, args: []^gd.Variant) -> gd.Variant {
		netsim.enabled, _ = gd.from_variant(bool, args[0])
		netsim_changed = true
		return {}
	})
	PRESETS := [4]string{"LAN", "WAN", "bad Wi-Fi", "off"}
	for name, i in PRESETS {
		button(row, name, proc(user: rawptr, _: []^gd.Variant) -> gd.Variant {
				preset: Netsim_Dir
				switch int(uintptr(user)) {
				case 0:
					preset = {2, 1, 0}
				case 1:
					preset = {60, 10, 1}
				case 2:
					preset = {140, 40, 6}
				case:
					netsim.enabled = false
					netsim_changed = true
					conditions_sync()
					return {}
				}
				netsim = {true, preset, preset}
				netsim_changed = true
				conditions_sync()
				return {}
			}, rawptr(uintptr(i)))
	}
	conditions.both = check(row, "both ways")
	gd.BaseButton_set_pressed_no_signal(conditions.both, true)
	head := add(box, gd.HBoxContainer_new())
	gd.Control_set_custom_minimum_size(label(head, ""), {52, 0})
	for name in ([]string{"up (to the relay)", "down"}) {
		header := label(head, name)
		gd.Control_set_h_size_flags(header, .SIZE_EXPAND_FILL)
		gd.Control_set_theme_type_variation(header, "DevTitleLabel")
	}
	for field, field_index in NET_FIELDS {
		line := add(box, gd.HBoxContainer_new())
		name := label(line, field.name)
		gd.Control_set_custom_minimum_size(name, {52, 0})
		for direction in 0 ..< 2 {
			slider := add(line, gd.HSlider_new())
			gd.Control_set_h_size_flags(slider, .SIZE_EXPAND_FILL)
			gd.Control_set_v_size_flags(slider, .SIZE_SHRINK_CENTER)
			gd.Control_set_focus_mode(slider, .FOCUS_NONE)
			gd.Range_set_max(slider, field.max)
			gd.Range_set_step(slider, field.step)
			on(slider, "value_changed", proc(user: rawptr, args: []^gd.Variant) -> gd.Variant {
					value, _ := gd.from_variant(f64, args[0])
					direction, field_index := int(uintptr(user)) / 3, int(uintptr(user)) % 3
					net_field(direction, field_index)^ = f32(value)
					if gd.BaseButton_is_pressed(s.cond.both) do net_field(1 - direction, field_index)^ = f32(value)
					netsim_changed = true
					conditions_sync()
					return {}
				}, rawptr(uintptr(direction * 3 + field_index)))
			conditions.sliders[direction][field_index] = slider
			conditions.values[direction][field_index] = label(line, "")
			gd.Control_set_custom_minimum_size(conditions.values[direction][field_index], {46, 0})
		}
	}
	panel_make(.Conditions, "Conditions", {350, 40, 470, 140}, box)
}

// Direction d (0 up, 1 down), field k (latency, jitter, loss) of `netsim`.
@(private)
net_field :: proc(direction, field_index: int) -> ^f32 {
	dir := direction == 0 ? &netsim.up : &netsim.down
	switch field_index {
	case 0:
		return &dir.latency_ms
	case 1:
		return &dir.jitter_ms
	}
	return &dir.loss_pct
}

// The widgets from the current values (the host, a preset or a slider changed them).
@(private)
conditions_sync :: proc() {
	conditions := &s.cond
	for fps_cap, i in FPS_CAPS do gd.BaseButton_set_pressed_no_signal(conditions.fps[i], fps_cap == conditions.cap)
	gd.BaseButton_set_pressed_no_signal(conditions.enabled, netsim.enabled)
	for direction in 0 ..< 2 {
		for field, field_index in NET_FIELDS {
			gd.Range_set_value_no_signal(
				conditions.sliders[direction][field_index],
				f64(net_field(direction, field_index)^),
			)
			gd.Label_set_text(
				conditions.values[direction][field_index],
				fmt.tprintf(field.format, net_field(direction, field_index)^),
			)
		}
	}
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
	events := &s.events
	events.tree = gd.Tree_new()
	gd.Tree_set_columns(events.tree, 2)
	gd.Tree_set_column_expand(events.tree, 0, false)
	gd.Tree_set_column_custom_minimum_width(events.tree, 0, 48)
	gd.Tree_set_hide_root(events.tree, true)
	gd.Control_set_focus_mode(events.tree, .FOCUS_NONE)
	events.root = gd.Tree_create_item(events.tree)
	panel_make(.Events, "Events", {8, 520, 480, 170}, events.tree)
	// in the title bar: the count and "follow"
	bar := s.panels[.Events].extras
	events.count = label(bar, "")
	events.follow = check(bar, "follow")
	gd.BaseButton_set_pressed_no_signal(events.follow, true)
}

@(private)
events_update :: proc() {
	events := &s.events
	if events.shown == s.log_n do return
	first := max(events.shown, s.log_n - LOG_ROWS)
	if s.log_n - events.shown > LOG_ROWS {
		gd.Tree_clear(events.tree)
		events.root = gd.Tree_create_item(events.tree)
		events.rows = 0
	}
	last: gd.TreeItem
	for i in first ..< s.log_n {
		log_row := &s.logs[i % LOG_ROWS]
		last = gd.Tree_create_item(events.tree, events.root)
		if last.ptr == nil do return // the tree refuses rows inside its own mouse handling: next frame
		gd.TreeItem_set_text(last, 0, fmt.tprint(log_row.tick))
		gd.TreeItem_set_text(last, 1, string(log_row.msg[:log_row.len]))
		events.rows += 1
		events.shown = i + 1
	}
	for events.rows > LOG_ROWS {
		gdi.object_destroy(gd.TreeItem_get_first_child(events.root).ptr)
		events.rows -= 1
	}
	gd.Label_set_text(events.count, fmt.tprint(s.log_n))
	if gd.BaseButton_is_pressed(events.follow) && last.ptr != nil do gd.Tree_scroll_to_item(events.tree, last)
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
	note := &s.note
	box := gd.VBoxContainer_new()
	note.thumb = add(box, gd.TextureRect_new())
	gd.TextureRect_set_expand_mode(note.thumb, .EXPAND_IGNORE_SIZE)
	gd.TextureRect_set_stretch_mode(note.thumb, .STRETCH_KEEP_ASPECT_CENTERED)
	gd.Control_set_custom_minimum_size(note.thumb, {160, 90})
	gd.Control_set_v_size_flags(note.thumb, .SIZE_EXPAND_FILL)
	gd.Control_set_stretch_ratio(note.thumb, 3)
	note.text = add(box, gd.TextEdit_new())
	gd.TextEdit_set_placeholder(note.text, "what happened?")
	gd.Control_set_custom_minimum_size(note.text, {160, 54})
	gd.Control_set_v_size_flags(note.text, .SIZE_EXPAND_FILL)
	// Enter sends, Ctrl+Enter is TextEdit's own new line. The signal comes before TextEdit handles the key.
	on(note.text, "gui_input", proc(_: rawptr, args: []^gd.Variant) -> gd.Variant {
		key_event := event_arg(gd.InputEventKey, args, "InputEventKey")
		if key_event.ptr == nil || !gd.InputEvent_is_pressed(key_event) do return {}
		key := gd.InputEventKey_get_keycode(key_event)
		if (key == .KEY_ENTER || key == .KEY_KP_ENTER) && !gd.InputEventWithModifiers_is_command_or_control_pressed(key_event) {
			gd.Control_accept_event(s.note.text)
			note_send()
		}
		return {}
	})
	row := add(box, gd.HBoxContainer_new())
	note.tag_bug = check(row, "bug")
	note.sent_l = label(row, "")
	gd.Control_set_h_size_flags(note.sent_l, .SIZE_EXPAND_FILL)
	button(row, "send", proc(_: rawptr, _: []^gd.Variant) -> gd.Variant {note_send(); return {}})
	panel_make(.Note, "Feedback", {300, 40, 560, 440}, box)
}

@(private)
note_open :: proc() {
	note := &s.note
	// Capture before the note covers the frame.
	tex: gd.Ref(gd.ViewportTexture) = gd.Viewport_get_texture(s.root)
	defer gd.unref(tex)
	img := gd.Texture2D_get_image(tex)
	defer gd.unref(img)
	if img.ptr == nil do return
	delete(note.png)
	note.png = fmt.aprintf("%s/devui-f3-%d.png", gd.OS_get_cache_dir(gd.OS_singleton()), time.now()._nsec)
	gd.Image_save_png(img, note.png)
	width := gd.Image_get_width(img)
	height := gd.Image_get_height(img)
	gd.Image_resize(img, NOTE_THUMB_W, NOTE_THUMB_W * height / max(width, 1))
	if note.tex.ptr == nil {
		note.tex = gd.ImageTexture_create_from_image(img)
	} else {
		gd.ImageTexture_set_image(note.tex, img)
	}
	gd.TextureRect_set_texture(note.thumb, note.tex)
	update_metrics() // the note may open with the rest of the dev UI hidden
	panel_open(.Note, true)
	gd.Object_call_deferred(note.text, "grab_focus")
}

@(private)
note_shutdown :: proc() {
	if s.note.tex.ptr != nil do gd.unref(s.note.tex)
	delete(s.note.png)
}

@(private)
note_send :: proc() {
	note := &s.note
	text := gd.TextEdit_get_text(note.text)
	tag_bug := gd.BaseButton_is_pressed(note.tag_bug)
	stamp := time.now()
	year, month, day := time.date(stamp)
	hour, minute, second := time.clock(stamp)
	dir := fmt.tprintf("%s/%04d%02d%02d-%02d%02d%02d", s.cfg.feedback_dir, year, int(month), day, hour, minute, second)
	if err := os.make_directory_all(dir); err != nil {
		gd.print_error(fmt.tprintf("devui: cannot create %s: %v", dir, err))
		return
	}
	if note.png != "" do os.rename(note.png, fmt.tprintf("%s/screenshot.png", dir))
	body := fmt.tprintf("%s\n%s", tag_bug ? "[bug]" : "[note]", text)
	_ = os.write_entire_file(fmt.tprintf("%s/note.txt", dir), transmute([]u8)body)
	if s.cfg.on_feedback != nil do s.cfg.on_feedback(dir, text, tag_bug, s.cfg.user)
	gd.print(fmt.tprintf("devui: feedback saved to %s", dir))
	note.sent += 1
	gd.Label_set_text(note.sent_l, fmt.tprintf("sent %d", note.sent))
	gd.TextEdit_set_text(note.text, "")
	panel_open(.Note, false)
	delete(note.png)
	note.png = ""
}
