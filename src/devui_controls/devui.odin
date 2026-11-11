// SPIKE: the dev UI built from Godot's own controls instead of Dear ImGui. Same API as unified:devui, so the host
// can pick either at run time (`-- --devui-controls`). Retained mode: the panels are built once; frame() updates
// values (labels at 10 Hz, plots every frame, the inspector's expanded rows at 10 Hz).
//
// Panels are Godot `Window`s: embedded in the game window by default (title bar, drag, resize, close for free),
// or real OS windows ("OS windows" in the top bar: Window.force_native). Focus and mouse routing are Godot's own:
// an embedded window that has focus takes the keyboard, a click on a window or the top bar stops there, and the
// overlay lets clicks through. wants_mouse / wants_keyboard report that to the host for its polled input.
//
// Files: panels.odin (top bar, overlay, netsim, events, note), inspector.odin (the RTTI tree).
package devui_controls

import "core:fmt"
import "core:strings"
import "core:time"
import gd "unified:gdext"
import "unified:gdext/gdi"

Config :: struct {
	feedback_dir: string, // absolute; default: Godot's user data dir + /feedback
	on_feedback:  proc(dir: string, note: string, tag_bug: bool, user: rawptr),
	user:         rawptr,
	layer:        i32, // CanvasLayer index (default 128: above the game's UI)
	visible:      bool, // start shown
}

Netsim :: struct {
	enabled:    bool,
	latency_ms: f32,
	jitter_ms:  f32,
	loss_pct:   f32,
}

visible: bool
netsim: Netsim
netsim_changed: bool // set by the Netsim panel; the host clears it after applying

@(private)
Panel :: enum {
	Inspector,
	Netsim,
	Events,
	Note,
}

@(private)
State :: struct {
	cfg:        Config,
	inited:     bool,
	tree:       gd.SceneTree,
	root:       gd.Window,
	root_id:    u64,
	layer_id:   u64,
	layer:      gd.CanvasLayer,
	rs:         gd.RenderingServer,
	shown:      bool, // what is on screen (visible is what the host or F1 asked for)
	native:     bool, // panels are OS windows
	open:       [Panel]bool, // the panels the user has open (kept while hidden)
	windows:    [Panel]gd.Window,
	toggles:    [Panel]gd.Button,
	native_btn: gd.Button,
	bar:        gd.PanelContainer,
	overlay:    Overlay,
	insp:       Inspector,
	events:     Events_Panel,
	net:        Netsim_Panel,
	note:       Note,
	stats:      [dynamic]string,
	logs:       [LOG_ROWS]Log_Row,
	log_n:      int,
	frame_ms:   f32,
	ui_ms:      f32,
	last_slow:  time.Tick, // the 10 Hz updates
	hotkeys:    gd.Callable,
	toggle_req: bool,
	note_req:   bool,
	want_mouse: bool,
	want_key:   bool,
	controls:   int, // nodes created (frame_stats)
	theme:      gd.Ref(gd.Theme),
	mouse:      gd.Vector2, // the cursor in the game window (from window_input: the root viewport stops tracking it over an embedded window)
}

@(private)
s: State

@(private)
LOG_ROWS :: 1000

@(private)
Log_Row :: struct {
	tick: u32,
	msg:  [96]u8,
	len:  u8,
}

@(private)
SLOW_MS :: 100 // labels and the inspector update at 10 Hz

init :: proc(cfg: Config) {
	if s.inited do return
	s.cfg = cfg
	if s.cfg.layer == 0 do s.cfg.layer = 128
	if s.cfg.feedback_dir == "" {
		s.cfg.feedback_dir = fmt.aprintf("%s/feedback", gd.OS_get_user_data_dir(gd.OS_singleton()))
	} else {
		s.cfg.feedback_dir = strings.clone(s.cfg.feedback_dir)
	}
	visible = cfg.visible
	s.rs = gd.RenderingServer_singleton()
	s.theme = dev_theme()
	s.tree = gd.cast_to(gd.SceneTree, gd.Engine_get_main_loop(gd.Engine_singleton()))
	s.root = gd.SceneTree_get_root(s.tree)
	s.layer = gd.CanvasLayer_new()
	gd.CanvasLayer_set_layer(s.layer, int(s.cfg.layer))
	gd.Node_set_name(s.layer, "DevUI")
	gd.CanvasLayer_set_visible(s.layer, false)
	s.root_id = gdi.object_get_instance_id(s.root.ptr)
	s.layer_id = gdi.object_get_instance_id(s.layer.ptr)
	s.open[.Inspector] = true
	s.open[.Events] = true
	build_bar()
	build_overlay()
	build_inspector()
	build_netsim()
	build_events()
	build_note()
	// deferred: init usually runs inside a node's _ready, while the root is busy adding children
	gd.Object_call_deferred(s.root, "add_child", s.layer)
	// F1 / F3 before anything else sees them, also while hidden
	s.hotkeys = gd.callable_create(on_hotkey_input, nil, s.root)
	gd.connect(s.root, "window_input", s.hotkeys)
	s.last_slow = time.tick_now()
	s.inited = true
}

shutdown :: proc() {
	if !s.inited do return
	if alive(s.root_id) && gd.Object_is_connected(s.root, "window_input", s.hotkeys) {
		gd.Object_disconnect(s.root, "window_input", s.hotkeys)
	}
	gd.Callable_destroy(&s.hotkeys)
	overlay_shutdown()
	inspector_shutdown()
	note_shutdown()
	// The windows and controls are children of the layer; freeing it frees them.
	if alive(s.layer_id) do gd.Node_queue_free(s.layer)
	gd.unref(s.theme)
	delete(s.stats)
	delete(s.cfg.feedback_dir)
	s = {}
}

@(private)
alive :: proc(id: u64) -> bool {
	return id != 0 && gdi.object_get_instance_from_id(id) != nil
}

is_ready :: proc() -> bool {
	return s.inited
}

// Nodes the dev UI created plus inspector rows, and the UI time (frame()) of the last frame.
frame_stats :: proc() -> (items: int, ui_ms: f32) {
	return s.controls + len(s.insp.nodes), s.ui_ms
}

// True when the dev UI has the mouse (the cursor is over a panel or the top bar) / the keyboard (a panel has
// focus). Godot already routes the events; the host uses these for its polled input.
wants_mouse :: proc() -> bool {return s.inited && s.shown && s.want_mouse}
wants_keyboard :: proc() -> bool {return s.inited && s.shown && s.want_key}

// Shows `data` (any value, read by RTTI) in the Inspector this frame. Read-only in this spike.
inspect :: proc(name: string, data: any, editable := false) {
	if !s.inited || !visible do return
	inspector_set(name, data)
}

// Adds a sample to the overlay graph `name` (created on first use).
plot :: proc(name: string, v: f32, lo: f32 = 0, hi: f32 = 0) {
	if !s.inited do return
	graph_add(name, v, lo, hi)
}

// A line in the overlay this frame.
stat :: proc(label: string, format: string, args: ..any) {
	if !s.inited || !visible do return
	append(&s.stats, fmt.aprintf("%s  %s", label, fmt.tprintf(format, ..args), allocator = context.temp_allocator))
}

// A row in the event log (the newest 1000 are kept).
log :: proc(tick: u32, format: string, args: ..any) {
	if !s.inited do return
	r := &s.logs[s.log_n % LOG_ROWS]
	msg := fmt.bprintf(r.msg[:], format, ..args)
	r.tick = tick
	r.len = u8(len(msg))
	s.log_n += 1
}

// Updates the panels. Call once per frame on the main thread (from a node's _process).
frame :: proc(dt: f64) {
	if !s.inited do return
	t0 := time.tick_now()
	s.frame_ms = f32(dt * 1000)
	defer {
		clear(&s.stats)
		inspector_end_frame()
	}
	if s.toggle_req {
		s.toggle_req = false
		visible = !visible
	}
	if s.note_req {
		s.note_req = false
		note_open()
	}
	if visible != s.shown do set_shown(visible)
	if !s.shown do return
	slow := time.duration_milliseconds(time.tick_since(s.last_slow)) >= SLOW_MS
	if slow do s.last_slow = time.tick_now()
	overlay_update(slow)
	if len(s.insp.pending) > 0 do inspector_build_pending()
	if s.open[.Inspector] && (slow || s.insp.dirty) do inspector_refresh()
	if s.open[.Events] do events_update()
	update_focus()
	s.ui_ms = f32(time.duration_milliseconds(time.tick_since(t0)))
}

@(private)
set_shown :: proc(on: bool) {
	s.shown = on
	gd.CanvasLayer_set_visible(s.layer, on)
	for p in Panel do gd.Window_set_visible(s.windows[p], on && s.open[p])
	if !on do s.want_mouse, s.want_key = false, false
}

@(private)
set_open :: proc(p: Panel, on: bool) {
	s.open[p] = on
	gd.Window_set_visible(s.windows[p], s.shown && on)
	if s.toggles[p].ptr != nil do gd.BaseButton_set_pressed_no_signal(s.toggles[p], on)
	if p == .Inspector && on do inspector_refresh()
	if p == .Netsim && on do netsim_sync()
}

// Who has the mouse and keyboard. Mouse: the cursor over the top bar or an open embedded window (title bar
// included); a native window under the cursor has focus or is the OS's business, so it counts through focus.
// Keyboard: any panel window has focus (embedded: Godot sends it every key; native: the OS does).
@(private)
update_focus :: proc() {
	m := s.mouse
	s.want_mouse = rect_has(gd.Control_get_global_rect(s.bar), m)
	s.want_key = false
	for p in Panel {
		w := s.windows[p]
		if !s.open[p] do continue
		if gd.Window_has_focus(w) {
			s.want_key = true
			if s.native do s.want_mouse = true
		}
		if !s.native {
			pos := gd.Window_get_position_with_decorations(w)
			size := gd.Window_get_size_with_decorations(w)
			r := gd.Rect2{{f32(pos.x), f32(pos.y)}, {f32(size.x), f32(size.y)}}
			if rect_has(r, m) do s.want_mouse = true
		}
	}
}

@(private)
rect_has :: proc(r: gd.Rect2, p: gd.Vector2) -> bool {
	return p.x >= r.position.x && p.y >= r.position.y && p.x < r.position.x + r.size.x && p.y < r.position.y + r.size.y
}

// ---- hotkeys (window_input: before the scene, embedded windows or the GUI see the event)

@(private)
on_hotkey_input :: proc(window: rawptr, args: []^gd.Variant) -> gd.Variant {
	if len(args) < 1 do return {}
	obj, _ := gd.from_variant(gd.Object, args[0])
	if window == nil {
		if me := gd.object_cast(gd.InputEventMouse, obj, "InputEventMouse"); me.ptr != nil {
			s.mouse = gd.InputEventMouse_get_position(me)
			return {}
		}
	}
	k := gd.object_cast(gd.InputEventKey, obj, "InputEventKey")
	if k.ptr == nil || !gd.InputEvent_is_pressed(k) || gd.InputEvent_is_echo(k) do return {}
	#partial switch gd.InputEventKey_get_keycode(k) {
	case .KEY_F1:
		s.toggle_req = true
	case .KEY_F3:
		s.note_req = true
	case:
		return {}
	}
	gd.Viewport_set_input_as_handled(window != nil ? gd.cast_to(gd.Viewport, {window}) : s.root)
	return {}
}

// ---- small builders

@(private)
add :: proc(parent: gd.Node, child: $T) -> T {
	gd.Node_add_child(parent, gd.cast_to(gd.Node, gd.Object{child.ptr}))
	s.controls += 1
	return child
}

@(private)
label :: proc(parent: gd.Node, text: string) -> gd.Label {
	l := add(parent, gd.Label_new())
	gd.Label_set_text(l, text)
	return l
}

@(private)
button :: proc(parent: gd.Node, text: string, on_press: gd.Callable_Proc, user: rawptr = nil) -> gd.Button {
	b := add(parent, gd.Button_new())
	gd.Button_set_text(b, text)
	gd.Control_set_focus_mode(b, .FOCUS_NONE)
	on(b, "pressed", on_press, user)
	return b
}

@(private)
on :: proc(obj: $T, signal: string, fn: gd.Callable_Proc, user: rawptr = nil) {
	c := gd.callable_create(fn, user, gd.Object{obj.ptr})
	gd.connect(gd.Object{obj.ptr}, signal, c)
	gd.Callable_destroy(&c) // the connection holds its own reference
}

// A panel: a Window holding one full-rect child (a margin container), hidden until opened.
@(private)
make_window :: proc(p: Panel, title: string, r: [4]i32) -> gd.MarginContainer {
	w := gd.Window_new()
	s.windows[p] = w
	gd.Window_set_title(w, title)
	gd.Window_set_position(w, {r.x, r.y})
	gd.Window_set_size(w, {r.z, r.w})
	gd.Window_set_transient(w, true)
	gd.Window_set_wrap_controls(w, false)
	gd.Window_set_visible(w, false)
	on(w, "close_requested", proc(user: rawptr, _: []^gd.Variant) -> gd.Variant {
			set_open(Panel(uintptr(user)), false)
			return {}
		}, rawptr(uintptr(p)))
	// a native window gets its own key events: F1 / F3 there too
	on(w, "window_input", on_hotkey_input, w.ptr)
	gd.Window_set_theme(w, s.theme)
	add(s.layer, w)
	m := add(w, gd.MarginContainer_new())
	gd.Control_set_anchors_and_offsets_preset(m, .PRESET_FULL_RECT)
	for side in ([]string{"margin_left", "margin_top", "margin_right", "margin_bottom"}) {
		gd.Control_add_theme_constant_override(m, side, 6)
	}
	return m
}
