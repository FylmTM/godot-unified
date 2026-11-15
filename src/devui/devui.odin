// The dev UI, built from Godot's own controls, game-agnostic. F1 shows/hides it, F3 opens/closes the feedback note.
//
//   devui.init({feedback_dir = ..., on_feedback = ...})   main thread, once the scene tree exists
//   every frame, before devui.frame(dt):
//     devui.inspect("state", &frame_state)     RTTI tree of any value (read-only)
//     devui.plot("ping ms", ping, 0, 300, "net")  a line graph sample (group "net"; groups are toggled in the overlay)
//     devui.lines("kB/s", {i, o}, {"in", "out"}) several lines in one graph
//     devui.stack("sim ms", {v, r}, {"verified", "resim"})   stacked bars
//     devui.mark("events", "rollback")         a mark in a strip (a lane per name)
//     devui.stat("tick", "%d", tick)            a line in the overlay
//     devui.log(tick, "barrel exploded")        a row in the event log (kept across frames)
//   devui.frame(dt)                            updates the panels (and the frame-time graph from dt)
//   devui.shutdown()
//
// Graphs share the frame graph's time axis (overlay.odin). Retained: the controls are built once, frame() updates values (text at 10 Hz, graphs every frame). Sizes are in
// screen points whatever the game's stretch: the layer undoes the root viewport's canvas stretch. Godot routes the
// input: a click on a panel stops there, the overlay lets clicks through, a focused text field takes the keyboard
// (wants_keyboard tells the host, whose game input is polled).
//
// Files: panel.odin (the floating panel), overlay.odin (top right: toggles, stats, graphs), inspector.odin,
// panels.odin (conditions, events, note), theme.odin.
package devui

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

// One direction of the network simulation.
Netsim_Dir :: struct {
	latency_ms: f32,
	jitter_ms:  f32,
	loss_pct:   f32,
}

Netsim :: struct {
	enabled: bool,
	up:      Netsim_Dir, // to the relay
	down:    Netsim_Dir, // from it
}

visible: bool
netsim: Netsim
netsim_changed: bool // set by the Conditions panel; the host clears it after applying

@(private)
State :: struct {
	cfg:       Config,
	inited:    bool,
	root:      gd.Window,
	root_id:   u64,
	layer:     gd.CanvasLayer,
	layer_id:  u64,
	rs:        gd.RenderingServer,
	theme:     gd.Ref(gd.Theme),
	mono:      gd.Ref(gd.SystemFont),
	shown:     bool, // on screen (visible is what F1 or the host asked for)
	scale:     f32, // window pixels per point (HiDPI)
	stretch:   f32, // the game's canvas stretch, undone by the layer
	view:      gd.Vector2, // the game window in points
	panels:    [Panel_Kind]Panel,
	overlay:   Overlay,
	insp:      Inspector,
	events:    Events_Panel,
	cond:      Conditions_Panel,
	note:      Note,
	stats:     [dynamic][2]string, // this frame's stat lines: key, value
	logs:      [LOG_ROWS]Log_Row,
	log_n:     int,
	ui_ms:     f32,
	last_slow: time.Tick,
	hotkeys:   gd.Callable,
	note_req:  bool,
	mouse:     gd.Vector2, // the cursor in window pixels (from window_input: Godot stops tracking it over GUI)
	want_key:  bool,
	nodes:     int, // controls created (frame_stats)
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
SLOW_MS :: 100 // text and the inspector update at 10 Hz

// Builds the dev UI's controls on their own CanvasLayer and hooks its hotkeys; call on the main thread once the
// scene tree exists. A second call does nothing.
init :: proc(config: Config) {
	if s.inited do return
	s.cfg = config
	if s.cfg.layer == 0 do s.cfg.layer = 128
	if s.cfg.feedback_dir == "" {
		s.cfg.feedback_dir = fmt.aprintf("%s/feedback", gd.OS_get_user_data_dir(gd.OS_singleton()))
	} else {
		s.cfg.feedback_dir = strings.clone(s.cfg.feedback_dir)
	}
	visible = config.visible
	s.rs = gd.RenderingServer_singleton()
	tree := gd.cast_to(gd.SceneTree, gd.Engine_get_main_loop(gd.Engine_singleton()))
	s.root = gd.SceneTree_get_root(tree)
	s.root_id = gdi.object_get_instance_id(s.root.ptr)
	s.layer = gd.CanvasLayer_new()
	gd.CanvasLayer_set_layer(s.layer, int(s.cfg.layer))
	gd.Node_set_name(s.layer, "DevUI")
	gd.CanvasLayer_set_visible(s.layer, false)
	s.layer_id = gdi.object_get_instance_id(s.layer.ptr)
	s.scale, s.stretch = 1, 1
	theme_init()
	build_overlay()
	build_inspector()
	build_conditions()
	build_events()
	build_note()
	// deferred: init usually runs inside a node's _ready, while the root is busy adding children
	gd.Object_call_deferred(s.root, "add_child", s.layer)
	// F1 / F3 (and the cursor) before anything else sees them, also while hidden
	s.hotkeys = gd.callable_create(on_window_input, nil, s.root)
	gd.connect(s.root, "window_input", s.hotkeys)
	s.last_slow = time.tick_now()
	s.inited = true
}

// Frees everything init made and resets the state, so init can run again (the extension calls it on unload).
shutdown :: proc() {
	if !s.inited do return
	if alive(s.root_id) && gd.Object_is_connected(s.root, "window_input", s.hotkeys) {
		gd.Object_disconnect(s.root, "window_input", s.hotkeys)
	}
	gd.Callable_destroy(&s.hotkeys)
	overlay_shutdown()
	inspector_shutdown()
	note_shutdown()
	// Everything else is a child of the layer (popped-out windows included); freeing it frees them. At extension
	// shutdown the tree may already be gone.
	if alive(s.layer_id) do gd.Node_queue_free(s.layer)
	gd.unref(s.theme)
	gd.unref(s.mono)
	delete(s.stats)
	delete(s.cfg.feedback_dir)
	s = {}
}

@(private)
alive :: proc(id: u64) -> bool {
	return id != 0 && gdi.object_get_instance_from_id(id) != nil
}

// Whether init has run (and shutdown has not since), so a host can init the dev UI only once.
is_ready :: proc() -> bool {
	return s.inited
}

// Controls plus inspector rows the dev UI made, and its own time (frame()) in the last frame.
frame_stats :: proc() -> (items: int, ui_ms: f32) {
	return s.nodes + len(s.insp.nodes), s.ui_ms
}

// True while the cursor is over a panel or the overlay's buttons (Godot already stops those clicks there).
wants_mouse :: proc() -> bool {
	return s.inited && (s.shown || s.panels[.Note].open) && over_ui(points(s.mouse))
}

// True while a dev UI text field (or a popped-out panel window) has the keyboard: polled game input should
// ignore keys then. Godot routes the events themselves.
wants_keyboard :: proc() -> bool {return s.inited && s.want_key}

// Shows `data` (any value, read by RTTI) in the Inspector this frame.
inspect :: proc(name: string, data: any, editable := false) {
	if !s.inited || !visible do return
	inspector_set(name, data)
}

// This frame's sample of the line graph `name` in `group` (created on first use; lo == hi: from 0 to a round value
// above the largest shown).
plot :: proc(name: string, value: f32, lo: f32 = 0, hi: f32 = 0, group := "game") {
	if !s.inited do return
	graph_lines(name, {value}, nil, lo, hi, group)
}

// Up to 4 lines in one graph, named by `legend`.
lines :: proc(name: string, values: []f32, legend: []string, lo: f32 = 0, hi: f32 = 0, group := "game") {
	if !s.inited do return
	graph_lines(name, values, legend, lo, hi, group)
}

// Up to 4 parts stacked bottom up, named by `legend` (each frame's bar as tall as their sum).
stack :: proc(name: string, parts: []f32, legend: []string, group := "game") {
	if !s.inited do return
	graph_stack(name, parts, legend, group)
}

// A mark this frame in the strip `strip`, lane `lane` (up to 4 lanes, created on first use).
mark :: proc(strip, lane: string, group := "game") {
	if !s.inited do return
	graph_mark(strip, lane, group)
}

// A line in the overlay this frame.
stat :: proc(label: string, format: string, args: ..any) {
	if !s.inited || !visible do return
	append(&s.stats, [2]string{fmt.tprint(label), fmt.tprintf(format, ..args)})
}

// A row in the event log (the newest 1000 are kept).
log :: proc(tick: u32, format: string, args: ..any) {
	if !s.inited do return
	row := &s.logs[s.log_n % LOG_ROWS]
	msg := fmt.bprintf(row.msg[:], format, ..args)
	row.tick = tick
	row.len = u8(len(msg))
	s.log_n += 1
}

// Updates the panels. Call once per frame on the main thread (from a node's _process).
frame :: proc(dt: f64) {
	if !s.inited do return
	start := time.tick_now()
	frame_time_add(f32(dt * 1000))
	defer {
		clear(&s.stats)
		inspector_end_frame()
	}
	if s.note_req {
		s.note_req = false
		if s.panels[.Note].open do panel_open(.Note, false)
		else do note_open()
	}
	if visible != s.shown do set_shown(visible)
	if !s.shown {
		// F3 without F1: the note alone
		if s.panels[.Note].open do update_focus()
		else do s.want_key = false
		return
	}
	slow := time.duration_milliseconds(time.tick_since(s.last_slow)) >= SLOW_MS
	if slow {
		s.last_slow = time.tick_now()
		update_metrics()
	}
	overlay_update(slow)
	if len(s.insp.pending) > 0 do inspector_build_pending()
	if s.panels[.Inspector].open && (slow || s.insp.dirty) do inspector_refresh()
	if s.panels[.Events].open do events_update()
	update_focus()
	s.ui_ms = f32(time.duration_milliseconds(time.tick_since(start)))
}

@(private)
set_shown :: proc(on: bool) {
	s.shown = on
	layer_sync()
	for kind in Panel_Kind do panel_sync(kind)
	if on {
		update_metrics()
		overlay_update(true)
	} else {
		s.want_key = false
	}
}

// The layer is up while the dev UI is shown or the note is open (F3 works without F1); the overlay only when shown.
@(private)
layer_sync :: proc() {
	gd.CanvasLayer_set_visible(s.layer, s.shown || s.panels[.Note].open)
	gd.CanvasItem_set_visible(s.overlay.panel, s.shown)
}

// Points, and the layer's scale: points * HiDPI scale / the game's canvas stretch (canvas_items stretch scales
// every canvas layer of the root viewport).
@(private)
update_metrics :: proc() {
	s.scale = max(gd.DisplayServer_screen_get_scale(gd.DisplayServer_singleton(), -1), 1)
	transform := gd.Viewport_get_final_transform(s.root)
	s.stretch = max(abs(transform.x.x), 1e-3)
	scale_factor := s.scale / s.stretch
	gd.CanvasLayer_set_scale(s.layer, {scale_factor, scale_factor})
	window_size := gd.Window_get_size(s.root)
	s.view = {f32(window_size.x) / s.scale, f32(window_size.y) / s.scale}
	overlay_place()
	for kind in Panel_Kind do panel_keep_on_screen(kind)
}

// The keyboard: a focused dev control (a text field), or a popped-out panel window with OS focus.
@(private)
update_focus :: proc() {
	s.want_key = ours(gd.Viewport_gui_get_focus_owner(s.root))
	for &panel in s.panels do if panel.window.ptr != nil && gd.Window_has_focus(panel.window) do s.want_key = true
}

@(private)
ours :: proc(control: gd.Control) -> bool {
	return control.ptr != nil && gd.Node_is_ancestor_of(s.layer, control)
}

// ---- window_input: hotkeys and the cursor, before the scene, the GUI or a popped-out window sees the event

@(private)
on_window_input :: proc(window: rawptr, args: []^gd.Variant) -> gd.Variant {
	if len(args) < 1 do return {}
	obj, _ := gd.from_variant(gd.Object, args[0])
	if window == nil {
		if mouse_button := gd.object_cast(gd.InputEventMouseButton, obj, "InputEventMouseButton");
		   mouse_button.ptr != nil {
			s.mouse = gd.InputEventMouse_get_position(mouse_button)
			// A click outside the dev UI gives the keyboard back to the game.
			if (s.shown || s.panels[.Note].open) &&
			   gd.InputEvent_is_pressed(mouse_button) &&
			   !over_ui(points(s.mouse)) {
				if ours(gd.Viewport_gui_get_focus_owner(s.root)) do gd.Viewport_gui_release_focus(s.root)
			}
			return {}
		}
		if mouse_event := gd.object_cast(gd.InputEventMouse, obj, "InputEventMouse"); mouse_event.ptr != nil {
			s.mouse = gd.InputEventMouse_get_position(mouse_event)
			return {}
		}
	}
	key_event := gd.object_cast(gd.InputEventKey, obj, "InputEventKey")
	if key_event.ptr == nil || !gd.InputEvent_is_pressed(key_event) || gd.InputEvent_is_echo(key_event) do return {}
	#partial switch gd.InputEventKey_get_keycode(key_event) {
	case .KEY_F1:
		visible = !visible // now: the host adds its stats before the next frame()
	case .KEY_F3:
		s.note_req = true
	case:
		return {}
	}
	gd.Viewport_set_input_as_handled(window != nil ? gd.cast_to(gd.Viewport, {window}) : s.root)
	return {}
}

// The point (in points) is over a panel or the overlay's buttons.
@(private)
over_ui :: proc(point: gd.Vector2) -> bool {
	if s.shown && rect_has(gd.Control_get_global_rect(s.overlay.buttons), point) do return true
	for &panel in s.panels {
		if gd.CanvasItem_is_visible(panel.frame) && rect_has(gd.Control_get_global_rect(panel.frame), point) do return true
	}
	return false
}

@(private)
rect_has :: proc(rect: gd.Rect2, point: gd.Vector2) -> bool {
	return(
		point.x >= rect.position.x &&
		point.y >= rect.position.y &&
		point.x < rect.position.x + rect.size.x &&
		point.y < rect.position.y + rect.size.y \
	)
}

// ---- small builders

@(private)
add :: proc(parent: gd.Node, child: $Child) -> Child {
	gd.Node_add_child(parent, gd.cast_to(gd.Node, gd.Object{child.ptr}))
	s.nodes += 1
	return child
}

@(private)
label :: proc(parent: gd.Node, text: string) -> gd.Label {
	node := add(parent, gd.Label_new())
	gd.Label_set_text(node, text)
	return node
}

@(private)
button :: proc(parent: gd.Node, text: string, on_press: gd.Callable_Proc, user: rawptr = nil) -> gd.Button {
	node := add(parent, gd.Button_new())
	gd.Button_set_text(node, text)
	gd.Control_set_focus_mode(node, .FOCUS_NONE)
	on(node, "pressed", on_press, user)
	return node
}

@(private)
check :: proc(parent: gd.Node, text: string) -> gd.CheckBox {
	node := add(parent, gd.CheckBox_new())
	gd.Button_set_text(node, text)
	gd.Control_set_focus_mode(node, .FOCUS_NONE)
	return node
}

@(private)
on :: proc(obj: $Source, signal: string, fn: gd.Callable_Proc, user: rawptr = nil) {
	callable := gd.callable_create(fn, user, gd.Object{obj.ptr})
	gd.connect(gd.Object{obj.ptr}, signal, callable)
	gd.Callable_destroy(&callable) // the connection holds its own reference
}

// The event of a signal's first argument, when it is a `T`.
@(private)
event_arg :: proc($Event: typeid, args: []^gd.Variant, class: string) -> Event {
	if len(args) < 1 do return {}
	obj, _ := gd.from_variant(gd.Object, args[0])
	return gd.object_cast(Event, obj, class)
}

// Window pixels to points.
@(private)
points :: proc(point: gd.Vector2) -> gd.Vector2 {
	return {point.x / s.scale, point.y / s.scale}
}
