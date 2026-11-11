// A floating panel on the dev UI's layer: a thin title bar (drag to move; pop out; close), a body, a resize grip
// in the corner. Popping out moves the body into a native OS window (closing that window docks it back).
package devui

import gd "unified:gdext"

@(private)
Panel_Kind :: enum {
	Inspector,
	Netsim,
	Events,
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
panel_make :: proc(k: Panel_Kind, title: string, r: [4]f32, body: gd.Control) {
	p := &s.panels[k]
	p.title = title
	p.frame = add(s.layer, gd.Control_new())
	gd.Control_set_position(p.frame, {r.x, r.y})
	gd.Control_set_size(p.frame, {r.z, r.w})
	gd.Control_set_theme(p.frame, s.theme)
	gd.CanvasItem_set_visible(p.frame, false)
	bg := add(p.frame, gd.PanelContainer_new())
	gd.Control_set_anchors_and_offsets_preset(bg, .PRESET_FULL_RECT)
	p.box = add(bg, gd.VBoxContainer_new())
	gd.Control_add_theme_constant_override(p.box, "separation", 1)
	// title bar: drag it to move the panel (and raise it)
	tb := add(p.box, gd.PanelContainer_new())
	gd.Control_set_theme_type_variation(tb, "DevTitle")
	on(tb, "gui_input", proc(user: rawptr, args: []^gd.Variant) -> gd.Variant {
			p := &s.panels[Panel_Kind(uintptr(user))]
			drag(p, args, &p.dragging, proc(p: ^Panel, d: gd.Vector2) {
				pos := gd.Control_get_position(p.frame)
				gd.Control_set_position(p.frame, {pos.x + d.x, pos.y + d.y})
			})
			return {}
		}, rawptr(uintptr(k)))
	p.bar = add(tb, gd.HBoxContainer_new())
	gd.Control_set_mouse_filter(p.bar, .MOUSE_FILTER_PASS)
	t := label(p.bar, title)
	gd.Control_set_h_size_flags(t, .SIZE_EXPAND_FILL)
	gd.Control_set_theme_type_variation(t, "DevTitleLabel")
	p.extras = add(p.bar, gd.HBoxContainer_new())
	pop := button(p.bar, "⧉", proc(user: rawptr, _: []^gd.Variant) -> gd.Variant {
			k := Panel_Kind(uintptr(user))
			panel_pop(k, s.panels[k].window.ptr == nil)
			return {}
		}, rawptr(uintptr(k)))
	gd.Control_set_theme_type_variation(pop, "DevTitleButton")
	gd.Control_set_tooltip_text(pop, "own window")
	x := button(p.bar, "×", proc(user: rawptr, _: []^gd.Variant) -> gd.Variant {
			panel_open(Panel_Kind(uintptr(user)), false)
			return {}
		}, rawptr(uintptr(k)))
	gd.Control_set_theme_type_variation(x, "DevTitleButton")
	p.body = add(p.box, body)
	gd.Control_set_v_size_flags(p.body, .SIZE_EXPAND_FILL)
	// resize grip, bottom right, over the body
	g := add(p.frame, gd.Control_new())
	gd.Control_set_size(g, {GRIP, GRIP})
	p.grip = g
	on(p.frame, "resized", proc(user: rawptr, _: []^gd.Variant) -> gd.Variant {
			p := &s.panels[Panel_Kind(uintptr(user))]
			size := gd.Control_get_size(p.frame)
			gd.Control_set_position(p.grip, {size.x - GRIP, size.y - GRIP})
			return {}
		}, rawptr(uintptr(k)))
	gd.Control_set_position(g, {r.z - GRIP, r.w - GRIP})
	gd.Control_set_default_cursor_shape(g, .CURSOR_FDIAGSIZE)
	ci := gd.CanvasItem_get_canvas_item(g)
	for i in 0 ..< 3 {
		o := f32(i) * 3
		gd.RenderingServer_canvas_item_add_rect(s.rs, ci, {{GRIP - 3 - o, GRIP - 3}, {2, 2}}, GRIP_COLOR)
		if i > 0 do gd.RenderingServer_canvas_item_add_rect(s.rs, ci, {{GRIP - 3, GRIP - 3 - o}, {2, 2}}, GRIP_COLOR)
	}
	on(g, "gui_input", proc(user: rawptr, args: []^gd.Variant) -> gd.Variant {
			p := &s.panels[Panel_Kind(uintptr(user))]
			drag(p, args, &p.sizing, proc(p: ^Panel, d: gd.Vector2) {
				min := gd.Control_get_combined_minimum_size(p.box)
				size := gd.Control_get_size(p.frame)
				gd.Control_set_size(p.frame, {max(size.x + d.x, min.x + 8), max(size.y + d.y, min.y + 8)})
			})
			return {}
		}, rawptr(uintptr(k)))
}

@(private)
GRIP_COLOR :: gd.Color{0.6, 0.65, 0.75, 0.8}

// Left-button drags on a title bar or grip: `apply` gets each motion (in points).
@(private)
drag :: proc(p: ^Panel, args: []^gd.Variant, active: ^bool, apply: proc(p: ^Panel, d: gd.Vector2)) {
	if mb := event_arg(gd.InputEventMouseButton, args, "InputEventMouseButton"); mb.ptr != nil {
		if gd.InputEventMouseButton_get_button_index(mb) != .MOUSE_BUTTON_LEFT do return
		active^ = gd.InputEvent_is_pressed(mb)
		if active^ do gd.Node_move_child(s.layer, p.frame, -1) // raise
		return
	}
	if mm := event_arg(gd.InputEventMouseMotion, args, "InputEventMouseMotion"); mm.ptr != nil && active^ {
		apply(p, gd.InputEventMouseMotion_get_relative(mm))
	}
}

@(private)
panel_open :: proc(k: Panel_Kind, on: bool) {
	p := &s.panels[k]
	if p.open == on do return
	p.open = on
	if !on && p.window.ptr != nil do panel_pop(k, false)
	panel_sync(k)
	overlay_sync_toggles()
	if k == .Inspector && on do s.insp.dirty = true
	if k == .Netsim && on do netsim_sync()
}

// Shows what should be on screen: the frame, or the native window while popped out.
@(private)
panel_sync :: proc(k: Panel_Kind) {
	p := &s.panels[k]
	on := s.shown && p.open
	gd.CanvasItem_set_visible(p.frame, on && p.window.ptr == nil)
	if p.window.ptr != nil do gd.Window_set_visible(p.window, on)
	if on do gd.Node_move_child(s.layer, p.frame, -1)
}

// The body into its own OS window (out), or back into the panel.
@(private)
panel_pop :: proc(k: Panel_Kind, out: bool) {
	p := &s.panels[k]
	if out == (p.window.ptr != nil) do return
	if out {
		w := gd.Window_new()
		gd.Window_set_visible(w, false) // force_native only changes on a hidden window
		gd.Window_set_title(w, p.title)
		gd.Window_set_force_native(w, true)
		gd.Window_set_transient(w, true)
		gd.Window_set_theme(w, s.theme)
		gd.Window_set_content_scale_factor(w, s.scale)
		size := gd.Control_get_size(p.frame)
		pos := gd.Control_get_position(p.frame)
		origin := gd.Window_get_position(s.root)
		gd.Window_set_size(w, {i32(size.x * s.scale), i32(size.y * s.scale)})
		gd.Window_set_position(w, {origin.x + i32(pos.x * s.scale), origin.y + i32(pos.y * s.scale)})
		on(w, "close_requested", proc(user: rawptr, _: []^gd.Variant) -> gd.Variant {
				panel_pop(Panel_Kind(uintptr(user)), false)
				return {}
			}, rawptr(uintptr(k)))
		on(w, "window_input", on_window_input, w.ptr) // F1 / F3 there too
		add(s.layer, w)
		// a background for the body, which the panel's frame drew
		bg := add(w, gd.PanelContainer_new())
		gd.Control_set_anchors_and_offsets_preset(bg, .PRESET_FULL_RECT)
		gd.Node_reparent(p.body, bg, false)
		p.window = w
	} else {
		gd.Node_reparent(p.body, p.box, false)
		gd.Node_queue_free(p.window)
		p.window = {}
	}
	panel_sync(k)
}

// A panel's title bar stays reachable when the game window shrinks.
@(private)
panel_keep_on_screen :: proc(k: Panel_Kind) {
	p := &s.panels[k]
	if !p.open || p.window.ptr != nil do return
	pos := gd.Control_get_position(p.frame)
	size := gd.Control_get_size(p.frame)
	x := clamp(pos.x, 40 - size.x, max(s.view.x - 40, 0))
	y := clamp(pos.y, 0, max(s.view.y - 20, 0))
	if x != pos.x || y != pos.y do gd.Control_set_position(p.frame, {x, y})
}
