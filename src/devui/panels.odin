// The Conditions panel, the log panels (Events, Commands) and the F3 note.
package devui

import "core:fmt"
import "core:os"
import "core:strings"
import gd "unified:gdext"
import "unified:gdext/gdi"

// ---- conditions: a frame-rate cap and the network simulation, per direction

@(private)
Conditions_Panel :: struct {
	fps:     [len(FPS_CAPS)]gd.Button,
	cap:     int, // the current cap (0: none)
	net:     gd.VBoxContainer, // the network simulation's rows (greyed while it can't apply)
	enabled: gd.CheckBox,
	presets: [4]gd.Button,
	both:    gd.CheckBox, // the sliders move both directions together
	sliders: [2][3]gd.HSlider, // [up, down][latency, jitter, loss]
	values:  [2][3]gd.Label,
	applies: bool, // netsim_applies as the controls show it
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
	conditions.net = add(box, gd.VBoxContainer_new())
	row = add(conditions.net, gd.HBoxContainer_new())
	conditions.enabled = check(row, "netsim")
	on(conditions.enabled, "toggled", proc(_: rawptr, args: []^gd.Variant) -> gd.Variant {
		netsim.enabled, _ = gd.from_variant(bool, args[0])
		netsim_changed = true
		return {}
	})
	PRESETS := [4]string{"LAN", "WAN", "bad Wi-Fi", "off"}
	for name, i in PRESETS {
		conditions.presets[i] = button(row, name, proc(user: rawptr, _: []^gd.Variant) -> gd.Variant {
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
	head := add(conditions.net, gd.HBoxContainer_new())
	gd.Control_set_custom_minimum_size(label(head, ""), {52, 0})
	for name in ([]string{"up (to the relay)", "down"}) {
		header := label(head, name)
		gd.Control_set_h_size_flags(header, .SIZE_EXPAND_FILL)
		gd.Control_set_theme_type_variation(header, "DevTitleLabel")
	}
	for field, field_index in NET_FIELDS {
		line := add(conditions.net, gd.HBoxContainer_new())
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
	conditions.applies = true
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

// The network rows follow netsim_applies: greyed and inert while the session has no remote links (the netsim
// wraps remote links only); the settings stay for the next session that has them.
@(private)
conditions_enable :: proc() {
	conditions := &s.cond
	conditions.applies = netsim_applies
	off := !netsim_applies
	gd.BaseButton_set_disabled(conditions.enabled, off)
	gd.BaseButton_set_disabled(conditions.both, off)
	for preset in conditions.presets do gd.BaseButton_set_disabled(preset, off)
	for direction in conditions.sliders do for slider in direction do gd.Slider_set_editable(slider, !off)
	gd.CanvasItem_set_modulate(conditions.net, off ? {1, 1, 1, 0.4} : {1, 1, 1, 1})
}

// ---- the log panels (Events, Commands): a three-column Tree (tick, state, text), rows appended as they come,
// the newest LOG_ROWS kept; "confirmed" in the title bar shows only confirmed rows (and notes).

// A log row's state: an event's (emitted, then confirmed or cancelled), a command's (sent, confirmed in a verified
// tick, or refused), or none (a note: a desync).
Log_State :: enum u8 {
	None,
	Emitted,
	Confirmed,
	Cancelled,
	Sent,
	Refused,
}

@(private)
LOG_STATE_NAMES := [Log_State]string {
	.None      = "",
	.Emitted   = "emitted",
	.Confirmed = "confirmed",
	.Cancelled = "cancelled",
	.Sent      = "sent",
	.Refused   = "refused",
}

@(private)
LOG_ROWS :: 1000

@(private)
Log_Row :: struct {
	tick:  u32,
	state: Log_State,
	len:   u8,
	msg:   [122]u8,
}

@(private)
Log_Panel :: struct {
	rows:      [LOG_ROWS]Log_Row, // by number % LOG_ROWS
	count:     int, // rows added so far
	follow:    gd.CheckBox,
	confirmed: gd.CheckBox, // show confirmed rows (and notes) only
	filtered:  bool, // `confirmed` as the tree was built
	count_l:   gd.Label,
	tree:      gd.Tree,
	root:      gd.TreeItem,
	items:     int, // rows in the tree
	shown:     int, // count when last synced
}

@(private)
build_log :: proc(panel: ^Log_Panel, kind: Panel_Kind, title: string, rect: [4]f32) {
	panel.tree = gd.Tree_new()
	gd.Tree_set_columns(panel.tree, 3)
	for column in 0 ..< 2 do gd.Tree_set_column_expand(panel.tree, column, false)
	gd.Tree_set_column_custom_minimum_width(panel.tree, 0, 48)
	gd.Tree_set_column_custom_minimum_width(panel.tree, 1, 62)
	gd.Tree_set_hide_root(panel.tree, true)
	gd.Control_set_focus_mode(panel.tree, .FOCUS_NONE)
	panel.root = gd.Tree_create_item(panel.tree)
	panel_make(kind, title, rect, panel.tree)
	// in the title bar: the count, "confirmed" and "follow"
	bar := s.panels[kind].extras
	panel.count_l = label(bar, "")
	panel.confirmed = check(bar, "confirmed")
	panel.follow = check(bar, "follow")
	gd.BaseButton_set_pressed_no_signal(panel.follow, true)
}

@(private)
log_shutdown :: proc(panel: ^Log_Panel) {
	panel.count, panel.shown, panel.items = 0, 0, 0
}

@(private)
log_add :: proc(panel: ^Log_Panel, tick: u32, state: Log_State, format: string, args: ..any) {
	row := &panel.rows[panel.count % LOG_ROWS]
	msg := fmt.bprintf(row.msg[:], format, ..args)
	row.tick, row.state, row.len = tick, state, u8(len(msg))
	panel.count += 1
}

@(private)
log_shows :: proc(panel: ^Log_Panel, row: ^Log_Row) -> bool {
	return !panel.filtered || row.state == .Confirmed || row.state == .None
}

@(private)
log_update :: proc(panel: ^Log_Panel) {
	filtered := gd.BaseButton_is_pressed(panel.confirmed)
	if filtered != panel.filtered || panel.count - panel.shown > LOG_ROWS {
		// rebuilt from the kept rows: the filter changed, or more rows came than the panel keeps
		gd.Tree_clear(panel.tree)
		panel.root = gd.Tree_create_item(panel.tree)
		panel.items = 0
		panel.filtered = filtered
		panel.shown = max(0, panel.count - LOG_ROWS)
	}
	if panel.shown == panel.count do return
	last: gd.TreeItem
	for i in panel.shown ..< panel.count {
		row := &panel.rows[i % LOG_ROWS]
		if log_shows(panel, row) {
			item := gd.Tree_create_item(panel.tree, panel.root)
			if item.ptr == nil do break // the tree refuses rows inside its own mouse handling: next frame
			gd.TreeItem_set_text(item, 0, fmt.tprint(row.tick))
			gd.TreeItem_set_text(item, 1, LOG_STATE_NAMES[row.state])
			gd.TreeItem_set_text(item, 2, string(row.msg[:row.len]))
			#partial switch row.state {
			case .Emitted, .Sent:
				for column in 0 ..< 3 do gd.TreeItem_set_custom_color(item, column, DIM)
			case .Cancelled, .Refused:
				gd.TreeItem_set_custom_color(item, 1, CANCELLED)
			}
			panel.items += 1
			last = item
		}
		panel.shown = i + 1
	}
	for panel.items > LOG_ROWS {
		gdi.object_destroy(gd.TreeItem_get_first_child(panel.root).ptr)
		panel.items -= 1
	}
	gd.Label_set_text(panel.count_l, fmt.tprint(panel.count))
	if gd.BaseButton_is_pressed(panel.follow) && last.ptr != nil do gd.Tree_scroll_to_item(panel.tree, last)
}

// ---- F3 feedback note

@(private)
Note :: struct {
	thumb:   gd.TextureRect,
	text:    gd.TextEdit,
	tag_bug: gd.CheckBox,
	sent_l:  gd.Label,
	sent:    int,
	shot:    gd.Ref(gd.Image), // the screenshot of this note, in memory until it is sent (nil: none)
	tex:     gd.Ref(gd.ImageTexture),
}

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

// F3: the frame as it is (before the note covers it) is kept in memory and shown scaled in the note; nothing is
// written until the note is sent, so the capture costs only the read back from the GPU.
@(private)
note_open :: proc() {
	note := &s.note
	tex: gd.Ref(gd.ViewportTexture) = gd.Viewport_get_texture(s.root)
	defer gd.unref(tex)
	img := gd.Texture2D_get_image(tex)
	if img.ptr == nil do return
	note_discard()
	note.shot = img
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

// The note's screenshot, dropped (the note was closed without sending, or a new one replaces it).
@(private)
note_discard :: proc() {
	if s.note.shot.ptr != nil do gd.unref(s.note.shot)
	s.note.shot = {}
}

@(private)
note_shutdown :: proc() {
	note_discard()
	if s.note.tex.ptr != nil do gd.unref(s.note.tex)
}

// Writes `<feedback dir>/<local time>[-n]/` with screenshot.png and note.txt, then calls on_feedback (the host adds
// its own files there).
@(private)
note_send :: proc() {
	note := &s.note
	text := gd.TextEdit_get_text(note.text)
	tag_bug := gd.BaseButton_is_pressed(note.tag_bug)
	// "2026-11-16T15:30:12" (local time) -> 20261116-153012; a second note within the second gets -2, -3, ...
	stamp, _ := strings.replace_all(
		gd.Time_get_datetime_string_from_system(gd.Time_singleton()),
		"-",
		"",
		context.temp_allocator,
	)
	stamp, _ = strings.replace_all(stamp, ":", "", context.temp_allocator)
	stamp, _ = strings.replace_all(stamp, "T", "-", context.temp_allocator)
	dir := fmt.tprintf("%s/%s", s.cfg.feedback_dir, stamp)
	for n := 2; os.exists(dir); n += 1 do dir = fmt.tprintf("%s/%s-%d", s.cfg.feedback_dir, stamp, n)
	if err := os.make_directory_all(dir); err != nil {
		gd.print_error(fmt.tprintf("devui: cannot create %s: %v", dir, err))
		return
	}
	body := fmt.tprintf("%s\n%s", tag_bug ? "[bug]" : "[note]", text)
	if note.shot.ptr != nil {
		if err := gd.Image_save_png(note.shot, fmt.tprintf("%s/screenshot.png", dir)); err != .OK {
			gd.print_error(fmt.tprintf("devui: the screenshot of %s was not saved: %v", dir, err))
			body = fmt.tprintf("%s\n[screenshot not saved: %v]", body, err)
		}
	}
	_ = os.write_entire_file(fmt.tprintf("%s/note.txt", dir), transmute([]u8)body)
	if s.cfg.on_feedback != nil do s.cfg.on_feedback(dir, text, tag_bug, s.cfg.user)
	gd.print(fmt.tprintf("devui: feedback saved to %s", dir))
	note.sent += 1
	gd.Label_set_text(note.sent_l, fmt.tprintf("sent %d", note.sent))
	gd.TextEdit_set_text(note.text, "")
	panel_open(.Note, false) // drops the screenshot
}
