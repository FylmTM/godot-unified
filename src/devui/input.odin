// Input capture without a node: a Callable connected to the root Window's `window_input` signal, which Godot
// emits for every event before the scene sees it. Events are decoded into a small queue that frame() feeds to
// ImGui. While the UI wants the mouse or keyboard, the event is marked handled so the game never sees it.
// F1 (toggle) and F3 (feedback note) work whether the UI is shown or not.
package devui

import gd "unified:gdext"
import "unified:gdext/gdi"
import imgui "unified:imgui"

@(private)
Event_Kind :: enum u8 {
	Mouse_Move,
	Mouse_Button,
	Wheel,
	Key,
}

@(private)
Mod :: enum u8 {
	Shift,
	Ctrl,
	Alt,
	Meta,
}

@(private)
Event :: struct {
	kind:   Event_Kind,
	pos:    [2]f32, // points
	button: int, // Godot: 1 left, 2 right, 3 middle
	down:   bool,
	echo:   bool,
	wheel:  [2]f32,
	key:    gd.Key,
	mods:   bit_set[Mod;u8],
	char:   rune,
}

@(private)
events: [dynamic]Event
@(private)
want_mouse, want_keyboard: bool
@(private)
toggle_requested, note_requested: bool

@(private)
Tags :: struct {
	key, mouse_button, mouse_motion, pan, with_mods: rawptr,
}
@(private)
tags: Tags
@(private)
input_callable: gd.Callable

@(private)
input_init :: proc() {
	tag :: proc(name: string) -> rawptr {return gdi.classdb_get_class_tag(gd.sn(name))}
	tags = {
		key          = tag("InputEventKey"),
		mouse_button = tag("InputEventMouseButton"),
		mouse_motion = tag("InputEventMouseMotion"),
		pan          = tag("InputEventPanGesture"),
		with_mods    = tag("InputEventWithModifiers"),
	}
	input_callable = gd.callable_create(on_window_input, nil, s.root)
	gd.connect(s.root, "window_input", input_callable)
}

@(private)
input_shutdown :: proc() {
	if alive(s.root_id) && gd.Object_is_connected(s.root, "window_input", input_callable) {
		gd.Object_disconnect(s.root, "window_input", input_callable)
	}
	gd.Callable_destroy(&input_callable)
	delete(events)
	events = nil
}

@(private)
on_window_input :: proc(_: rawptr, args: []^gd.Variant) -> gd.Variant {
	if len(args) < 1 do return {}
	obj, _ := gd.from_variant(gd.Object, args[0])
	if obj.ptr == nil do return {}
	ev, ok := decode(obj.ptr)
	if !ok do return {}
	scale := s.scale > 0 ? s.scale : 1
	ev.pos /= scale
	if ev.kind == .Key && ev.down && !ev.echo {
		#partial switch ev.key {
		case .KEY_F1:
			toggle_requested = true
			gd.Viewport_set_input_as_handled(s.root)
			return {}
		case .KEY_F3:
			note_requested = true
			gd.Viewport_set_input_as_handled(s.root)
			return {}
		}
	}
	if !visible do return {}
	append(&events, ev)
	is_mouse := ev.kind != .Key
	if (is_mouse && want_mouse) || (!is_mouse && want_keyboard) {
		gd.Viewport_set_input_as_handled(s.root)
	}
	return {}
}

@(private)
handle_hotkeys :: proc() {
	if toggle_requested {
		toggle_requested = false
		visible = !visible
		if !visible do want_mouse, want_keyboard = false, false
	}
	if note_requested {
		note_requested = false
		note_open()
	}
}

@(private)
decode :: proc(obj: rawptr) -> (ev: Event, ok: bool) {
	if m := gdi.object_cast_to(obj, tags.with_mods); m != nil {
		wm := gd.cast_to(gd.InputEventWithModifiers, gd.Object{m})
		if gd.InputEventWithModifiers_is_shift_pressed(wm) do ev.mods += {.Shift}
		if gd.InputEventWithModifiers_is_ctrl_pressed(wm) do ev.mods += {.Ctrl}
		if gd.InputEventWithModifiers_is_alt_pressed(wm) do ev.mods += {.Alt}
		if gd.InputEventWithModifiers_is_meta_pressed(wm) do ev.mods += {.Meta}
	}
	if k := gdi.object_cast_to(obj, tags.key); k != nil {
		ke := gd.cast_to(gd.InputEventKey, gd.Object{k})
		ev.kind = .Key
		ev.key = gd.InputEventKey_get_keycode(ke)
		ev.down = gd.InputEvent_is_pressed(ke)
		ev.echo = gd.InputEvent_is_echo(ke)
		ev.char = rune(gd.InputEventKey_get_unicode(ke))
		return ev, true
	}
	if bt := gdi.object_cast_to(obj, tags.mouse_button); bt != nil {
		be := gd.cast_to(gd.InputEventMouseButton, gd.Object{bt})
		p := gd.InputEventMouse_get_position(be)
		ev.pos = {p.x, p.y}
		idx := gd.InputEventMouseButton_get_button_index(be)
		#partial switch idx {
		case .MOUSE_BUTTON_WHEEL_UP, .MOUSE_BUTTON_WHEEL_DOWN, .MOUSE_BUTTON_WHEEL_LEFT, .MOUSE_BUTTON_WHEEL_RIGHT:
			if !gd.InputEvent_is_pressed(be) do return
			f := gd.InputEventMouseButton_get_factor(be)
			if f == 0 do f = 1
			ev.kind = .Wheel
			#partial switch idx {
			case .MOUSE_BUTTON_WHEEL_UP:
				ev.wheel.y = f
			case .MOUSE_BUTTON_WHEEL_DOWN:
				ev.wheel.y = -f
			case .MOUSE_BUTTON_WHEEL_LEFT:
				ev.wheel.x = f
			case:
				ev.wheel.x = -f
			}
		case:
			ev.kind = .Mouse_Button
			ev.button = int(idx)
			ev.down = gd.InputEvent_is_pressed(be)
		}
		return ev, true
	}
	if mm := gdi.object_cast_to(obj, tags.mouse_motion); mm != nil {
		p := gd.InputEventMouse_get_position(gd.cast_to(gd.InputEventMouse, gd.Object{mm}))
		ev.kind = .Mouse_Move
		ev.pos = {p.x, p.y}
		return ev, true
	}
	if pg := gdi.object_cast_to(obj, tags.pan); pg != nil {
		// macOS trackpad two-finger scroll
		pe := gd.cast_to(gd.InputEventPanGesture, gd.Object{pg})
		d := gd.InputEventPanGesture_get_delta(pe)
		p := gd.InputEventGesture_get_position(pe)
		ev.kind = .Wheel
		ev.pos = {p.x, p.y}
		ev.wheel = {-d.x, -d.y}
		return ev, true
	}
	return
}

@(private)
feed_input :: proc(io: ^imgui.IO) {
	for e in events {
		switch e.kind {
		case .Mouse_Move:
			imgui.IO_AddMousePosEvent(io, e.pos.x, e.pos.y)
		case .Mouse_Button:
			if e.button >= 1 && e.button <= 3 {
				imgui.IO_AddMousePosEvent(io, e.pos.x, e.pos.y)
				imgui.IO_AddMouseButtonEvent(io, i32(e.button - 1), e.down) // Godot 1,2,3 = L,R,M; ImGui 0,1,2
			}
		case .Wheel:
			imgui.IO_AddMouseWheelEvent(io, e.wheel.x, e.wheel.y)
		case .Key:
			imgui.IO_AddKeyEvent(io, .Mod_Ctrl, .Ctrl in e.mods)
			imgui.IO_AddKeyEvent(io, .Mod_Shift, .Shift in e.mods)
			imgui.IO_AddKeyEvent(io, .Mod_Alt, .Alt in e.mods)
			imgui.IO_AddKeyEvent(io, .Mod_Super, .Meta in e.mods)
			if k := map_key(e.key); k != .None do imgui.IO_AddKeyEvent(io, k, e.down)
			if e.down && e.char >= 32 && e.char != 127 && (e.mods & {.Ctrl, .Meta}) == {} {
				imgui.IO_AddInputCharacter(io, u32(e.char))
			}
		}
	}
}

@(private)
map_key :: proc(k: gd.Key) -> imgui.Key {
	c := i64(k)
	switch {
	case c >= 'A' && c <= 'Z':
		return imgui.Key(i64(imgui.Key.A) + c - 'A')
	case c >= '0' && c <= '9':
		return imgui.Key(i64(imgui.Key._0) + c - '0')
	case c >= i64(gd.Key.KEY_F1) && c <= i64(gd.Key.KEY_F12):
		return imgui.Key(i64(imgui.Key.F1) + c - i64(gd.Key.KEY_F1))
	}
	#partial switch k {
	case .KEY_TAB:
		return .Tab
	case .KEY_LEFT:
		return .LeftArrow
	case .KEY_RIGHT:
		return .RightArrow
	case .KEY_UP:
		return .UpArrow
	case .KEY_DOWN:
		return .DownArrow
	case .KEY_PAGEUP:
		return .PageUp
	case .KEY_PAGEDOWN:
		return .PageDown
	case .KEY_HOME:
		return .Home
	case .KEY_END:
		return .End
	case .KEY_INSERT:
		return .Insert
	case .KEY_DELETE:
		return .Delete
	case .KEY_BACKSPACE:
		return .Backspace
	case .KEY_SPACE:
		return .Space
	case .KEY_ENTER:
		return .Enter
	case .KEY_KP_ENTER:
		return .KeypadEnter
	case .KEY_ESCAPE:
		return .Escape
	case .KEY_CTRL:
		return .LeftCtrl
	case .KEY_SHIFT:
		return .LeftShift
	case .KEY_ALT:
		return .LeftAlt
	case .KEY_META:
		return .LeftSuper
	}
	return .None
}
