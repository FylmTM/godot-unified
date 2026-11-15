// A floating panel on the dev UI's layer: a thin title bar (drag to move; pop out; close), a body, a resize grip
// in the corner. Popping out moves the body into a native OS window (closing that window docks it back).
package devui

import gd "unified:gdext"

@(private)
Panel_Kind :: enum {
	Inspector,
	Input,
	Conditions,
	Events,
	Commands,
	Note,
}

@(private)
Panel :: struct {
	title:    string,
	frame:    gd.Control, // background, title bar, body, grip
	box:      gd.VBoxContainer, // title bar + body
	bar:      gd.HBoxContainer, // the title bar (callers may add widgets: before the buttons)
	extras:   gd.HBoxContainer, // where those widgets go
	body:     gd.Control,
	grip:     gd.Control,
	window:   gd.Window, // the native window while popped out
	open:     bool,
	dragging: bool,
	sizing:   bool,
}

@(private)
GRIP :: 10

// A panel at `r` (points: x, y, w, h), hidden until opened; `body` fills it below the title bar.
@(private)
panel_make :: proc(kind: Panel_Kind, title: string, rect: [4]f32, body: gd.Control) {
	panel := &s.panels[kind]
	panel.title = title
	panel.frame = add(s.layer, gd.Control_new())
	gd.Control_set_position(panel.frame, {rect.x, rect.y})
	gd.Control_set_size(panel.frame, {rect.z, rect.w})
	gd.Control_set_theme(panel.frame, s.theme)
	gd.CanvasItem_set_visible(panel.frame, false)
	background := add(panel.frame, gd.PanelContainer_new())
	gd.Control_set_anchors_and_offsets_preset(background, .PRESET_FULL_RECT)
	panel.box = add(background, gd.VBoxContainer_new())
	gd.Control_add_theme_constant_override(panel.box, "separation", 1)
	// title bar: drag it to move the panel (and raise it)
	title_bar := add(panel.box, gd.PanelContainer_new())
	gd.Control_set_theme_type_variation(title_bar, "DevTitle")
	on(title_bar, "gui_input", proc(user: rawptr, args: []^gd.Variant) -> gd.Variant {
			panel := &s.panels[Panel_Kind(uintptr(user))]
			drag(panel, args, &panel.dragging, proc(panel: ^Panel, delta: gd.Vector2) {
				pos := gd.Control_get_position(panel.frame)
				gd.Control_set_position(panel.frame, {pos.x + delta.x, pos.y + delta.y})
			})
			return {}
		}, rawptr(uintptr(kind)))
	panel.bar = add(title_bar, gd.HBoxContainer_new())
	gd.Control_set_mouse_filter(panel.bar, .MOUSE_FILTER_PASS)
	title_label := label(panel.bar, title)
	gd.Control_set_h_size_flags(title_label, .SIZE_EXPAND_FILL)
	gd.Control_set_theme_type_variation(title_label, "DevTitleLabel")
	panel.extras = add(panel.bar, gd.HBoxContainer_new())
	pop_button := button(panel.bar, "⧉", proc(user: rawptr, _: []^gd.Variant) -> gd.Variant {
			kind := Panel_Kind(uintptr(user))
			panel_pop(kind, s.panels[kind].window.ptr == nil)
			return {}
		}, rawptr(uintptr(kind)))
	gd.Control_set_theme_type_variation(pop_button, "DevTitleButton")
	gd.Control_set_tooltip_text(pop_button, "own window")
	close_button := button(panel.bar, "×", proc(user: rawptr, _: []^gd.Variant) -> gd.Variant {
			panel_open(Panel_Kind(uintptr(user)), false)
			return {}
		}, rawptr(uintptr(kind)))
	gd.Control_set_theme_type_variation(close_button, "DevTitleButton")
	panel.body = add(panel.box, body)
	gd.Control_set_v_size_flags(panel.body, .SIZE_EXPAND_FILL)
	// resize grip, bottom right, over the body
	grip := add(panel.frame, gd.Control_new())
	gd.Control_set_size(grip, {GRIP, GRIP})
	panel.grip = grip
	on(panel.frame, "resized", proc(user: rawptr, _: []^gd.Variant) -> gd.Variant {
			panel := &s.panels[Panel_Kind(uintptr(user))]
			size := gd.Control_get_size(panel.frame)
			gd.Control_set_position(panel.grip, {size.x - GRIP, size.y - GRIP})
			return {}
		}, rawptr(uintptr(kind)))
	gd.Control_set_position(grip, {rect.z - GRIP, rect.w - GRIP})
	gd.Control_set_default_cursor_shape(grip, .CURSOR_FDIAGSIZE)
	canvas_item := gd.CanvasItem_get_canvas_item(grip)
	for i in 0 ..< 3 {
		offset := f32(i) * 3
		gd.RenderingServer_canvas_item_add_rect(s.rs, canvas_item, {{GRIP - 3 - offset, GRIP - 3}, {2, 2}}, GRIP_COLOR)
		if i > 0 do gd.RenderingServer_canvas_item_add_rect(s.rs, canvas_item, {{GRIP - 3, GRIP - 3 - offset}, {2, 2}}, GRIP_COLOR)
	}
	on(grip, "gui_input", proc(user: rawptr, args: []^gd.Variant) -> gd.Variant {
			panel := &s.panels[Panel_Kind(uintptr(user))]
			drag(panel, args, &panel.sizing, proc(panel: ^Panel, delta: gd.Vector2) {
				min_size := gd.Control_get_combined_minimum_size(panel.box)
				size := gd.Control_get_size(panel.frame)
				gd.Control_set_size(
					panel.frame,
					{max(size.x + delta.x, min_size.x + 8), max(size.y + delta.y, min_size.y + 8)},
				)
			})
			return {}
		}, rawptr(uintptr(kind)))
}

@(private)
GRIP_COLOR :: gd.Color{0.6, 0.65, 0.75, 0.8}

// Left-button drags on a title bar or grip: `apply` gets each motion (in points).
@(private)
drag :: proc(panel: ^Panel, args: []^gd.Variant, active: ^bool, apply: proc(panel: ^Panel, delta: gd.Vector2)) {
	if mouse_button := event_arg(gd.InputEventMouseButton, args, "InputEventMouseButton"); mouse_button.ptr != nil {
		if gd.InputEventMouseButton_get_button_index(mouse_button) != .MOUSE_BUTTON_LEFT do return
		active^ = gd.InputEvent_is_pressed(mouse_button)
		if active^ do gd.Node_move_child(s.layer, panel.frame, -1) // raise
		return
	}
	if motion := event_arg(gd.InputEventMouseMotion, args, "InputEventMouseMotion"); motion.ptr != nil && active^ {
		apply(panel, gd.InputEventMouseMotion_get_relative(motion))
	}
}

@(private)
panel_open :: proc(kind: Panel_Kind, open: bool) {
	panel := &s.panels[kind]
	if panel.open == open do return
	panel.open = open
	if !open && panel.window.ptr != nil do panel_pop(kind, false)
	panel_sync(kind)
	if kind == .Note do layer_sync()
	overlay_sync_toggles()
	if kind == .Inspector && open do s.insp.dirty = true
	if kind == .Input && open do s.input.dirty = true
	if kind == .Conditions && open do conditions_sync()
	if kind == .Note && !open do note_discard()
}

// Shows what should be on screen: the frame, or the native window while popped out.
@(private)
panel_sync :: proc(kind: Panel_Kind) {
	panel := &s.panels[kind]
	shown := panel.open && (s.shown || kind == .Note)
	gd.CanvasItem_set_visible(panel.frame, shown && panel.window.ptr == nil)
	if panel.window.ptr != nil do gd.Window_set_visible(panel.window, shown)
	if shown do gd.Node_move_child(s.layer, panel.frame, -1)
}

// The body into its own OS window (out), or back into the panel.
@(private)
panel_pop :: proc(kind: Panel_Kind, out: bool) {
	panel := &s.panels[kind]
	if out == (panel.window.ptr != nil) do return
	if out {
		window := gd.Window_new()
		gd.Window_set_visible(window, false) // force_native only changes on a hidden window
		gd.Window_set_title(window, panel.title)
		gd.Window_set_force_native(window, true)
		gd.Window_set_transient(window, true)
		gd.Window_set_theme(window, s.theme)
		gd.Window_set_content_scale_factor(window, s.scale)
		size := gd.Control_get_size(panel.frame)
		pos := gd.Control_get_position(panel.frame)
		origin := gd.Window_get_position(s.root)
		gd.Window_set_size(window, {i32(size.x * s.scale), i32(size.y * s.scale)})
		gd.Window_set_position(window, {origin.x + i32(pos.x * s.scale), origin.y + i32(pos.y * s.scale)})
		on(window, "close_requested", proc(user: rawptr, _: []^gd.Variant) -> gd.Variant {
				panel_pop(Panel_Kind(uintptr(user)), false)
				return {}
			}, rawptr(uintptr(kind)))
		on(window, "window_input", on_window_input, window.ptr) // F1 / F3 there too
		add(s.layer, window)
		// a background for the body, which the panel's frame drew
		bg := add(window, gd.PanelContainer_new())
		gd.Control_set_anchors_and_offsets_preset(bg, .PRESET_FULL_RECT)
		gd.Node_reparent(panel.body, bg, false)
		panel.window = window
	} else {
		gd.Node_reparent(panel.body, panel.box, false)
		gd.Node_queue_free(panel.window)
		panel.window = {}
	}
	panel_sync(kind)
}

// A panel's title bar stays reachable when the game window shrinks.
@(private)
panel_keep_on_screen :: proc(kind: Panel_Kind) {
	panel := &s.panels[kind]
	if !panel.open || panel.window.ptr != nil do return
	pos := gd.Control_get_position(panel.frame)
	size := gd.Control_get_size(panel.frame)
	x := clamp(pos.x, 40 - size.x, max(s.view.x - 40, 0))
	y := clamp(pos.y, 0, max(s.view.y - 20, 0))
	if x != pos.x || y != pos.y do gd.Control_set_position(panel.frame, {x, y})
}
