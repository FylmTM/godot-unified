// The dev UI, built from Godot's own controls, game-agnostic. F1 shows/hides it, F3 opens/closes the feedback note.
// The host feeds it every frame (inspect, plot, stat, log...), then calls frame(). How it fits, and its decisions
// (retained controls, sizes in points, its own theme, input routing, F3 notes): src/devui/README.md.
//
// Files: panel.odin (the floating panel), overlay.odin (toggles, stats, graphs), inspector.odin (the Inspector and
// Input panels' RTTI trees), panels.odin (conditions, the logs, the note), theme.odin.
package devui

import "core:fmt"
import "core:time"
import gd "unified:gdext"
import "unified:gdext/gdi"

// Called on the main thread once an F3 note was written into `dir` (the host adds its own files there).
Feedback_Proc :: #type proc(dir: string, tag_bug: bool)

@(private)
LAYER :: 128 // the dev UI's CanvasLayer: above the game's UI

// One direction of the network simulation.
Netsim_Dir :: struct {
	latency_ms: f32,
	jitter_ms:  f32,
	loss_pct:   f32,
}

// The Conditions panel's network simulation: off, or latency, jitter and loss each way.
Netsim :: struct {
	enabled: bool,
	up:      Netsim_Dir, // to the relay
	down:    Netsim_Dir, // from it
}

// The dev UI is shown: F1 toggles it, the host may set it.
visible: bool
// The Conditions panel's settings; the host applies them to its remote links.
netsim: Netsim
netsim_changed: bool // set by the Conditions panel; the host clears it after applying
netsim_applies := true // false: the session has no remote links (single player); the panel greys its network part

@(private)
State :: struct {
	feedback_dir: string, // Godot's user data dir + /feedback
	on_feedback:  Feedback_Proc,
	inited:       bool,
	root:         gd.Window,
	root_id:      u64,
	layer:        gd.CanvasLayer,
	layer_id:     u64,
	rs:           gd.RenderingServer,
	theme:        gd.Ref(gd.Theme),
	mono:         gd.Ref(gd.SystemFont),
	shown:        bool, // on screen (visible is what F1 or the host asked for)
	scale:        f32, // window pixels per point (HiDPI)
	stretch:      f32, // the game's canvas stretch, undone by the layer
	view:         gd.Vector2, // the game window in points
	panels:       [Panel_Kind]Panel,
	overlay:      Overlay,
	insp:         Inspector,
	input:        Inspector, // the Input panel
	events:       Log_Panel,
	commands:     Log_Panel,
	cond:         Conditions_Panel,
	note:         Note,
	stats:        [dynamic][2]string, // this frame's stat lines: key, value
	ui_ms:        f32,
	last_slow:    time.Tick,
	hotkeys:      gd.Callable,
	note_req:     bool,
	mouse:        gd.Vector2, // the cursor in window pixels (from window_input: Godot stops tracking it over GUI)
	want_key:     bool,
	nodes:        int, // controls created (frame_stats)
}

@(private)
s: State

@(private)
SLOW_MS :: 100 // text and the inspector update at 10 Hz

// Builds the dev UI's controls on their own CanvasLayer and hooks its hotkeys; call on the main thread once the
// scene tree exists. A second call does nothing.
init :: proc(shown: bool, on_feedback: Feedback_Proc = nil) {
	if s.inited do return
	s.on_feedback = on_feedback
	s.feedback_dir = fmt.aprintf("%s/feedback", gd.OS_get_user_data_dir(gd.OS_singleton()))
	visible = shown
	s.rs = gd.RenderingServer_singleton()
	tree := gd.cast_to(gd.SceneTree, gd.Engine_get_main_loop(gd.Engine_singleton()))
	s.root = gd.SceneTree_get_root(tree)
	s.root_id = gdi.object_get_instance_id(s.root.ptr)
	s.layer = gd.CanvasLayer_new()
	gd.CanvasLayer_set_layer(s.layer, LAYER)
	gd.Node_set_name(s.layer, "DevUI")
	gd.CanvasLayer_set_visible(s.layer, false)
	s.layer_id = gdi.object_get_instance_id(s.layer.ptr)
	s.scale, s.stretch = 1, 1
	theme_init()
	build_overlay()
	build_inspector(&s.insp, .Inspector, "Inspector", {8, 8, 330, 420})
	build_inspector(&s.input, .Input, "Input", {350, 190, 330, 300})
	build_conditions()
	build_log(&s.events, .Events, "Events", {8, 520, 480, 170})
	build_log(&s.commands, .Commands, "Commands", {496, 520, 480, 170})
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
	inspector_shutdown(&s.insp)
	inspector_shutdown(&s.input)
	log_shutdown(&s.events)
	log_shutdown(&s.commands)
	note_shutdown()
	// Everything else is a child of the layer (popped-out windows included); freeing it frees them. At extension
	// shutdown the tree may already be gone.
	if alive(s.layer_id) do gd.Node_queue_free(s.layer)
	gd.unref(s.theme)
	gd.unref(s.mono)
	delete(s.stats)
	delete(s.feedback_dir)
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
	rows := len(s.insp.nodes) - len(s.insp.free) + len(s.input.nodes) - len(s.input.free)
	return s.nodes + rows, s.ui_ms
}

// True while a dev UI text field (or a popped-out panel window) has the keyboard: polled game input should
// ignore keys then. Godot routes the events themselves.
wants_keyboard :: proc() -> bool {return s.inited && s.want_key}

// Whether the Inspector or the Input panel is open while the dev UI is shown: the host feeds them only then (a copy
// of the state costs the sim thread every tick).
wants_state :: proc() -> bool {
	return s.inited && visible && (s.panels[.Inspector].open || s.panels[.Input].open)
}

// Shows `data` (any value, read by RTTI) in the Inspector this frame.
inspect :: proc(name: string, data: any) {
	if !s.inited || !visible do return
	inspector_set(&s.insp, name, data)
}

// Shows `data` (any value, read by RTTI) in the Input panel this frame.
inputs :: proc(name: string, data: any) {
	if !s.inited || !visible do return
	inspector_set(&s.input, name, data)
}

// This frame's sample of the line graph `name` in `group` (both created on first use; the overlay toggles a group),
// scaled from 0 to a round value above the largest shown.
plot :: proc(group, name: string, value: f32) {
	if !s.inited do return
	graph_lines(name, {value}, nil, group)
}

// Up to 4 lines in one graph, named by `legend`.
lines :: proc(group, name: string, values: []f32, legend: []string) {
	if !s.inited do return
	graph_lines(name, values, legend, group)
}

// Up to 4 parts stacked bottom up, named by `legend` (each frame's bar as tall as their sum).
stack :: proc(group, name: string, parts: []f32, legend: []string) {
	if !s.inited do return
	graph_stack(name, parts, legend, group)
}

// A mark this frame in the strip `strip`, lane `lane` (up to 4 lanes, created on first use).
mark :: proc(group, strip, lane: string) {
	if !s.inited do return
	graph_mark(strip, lane, group)
}

// A line in the overlay this frame.
stat :: proc(label: string, format: string, args: ..any) {
	if !s.inited || !visible do return
	append(&s.stats, [2]string{fmt.tprint(label), fmt.tprintf(format, ..args)})
}

// A row in the Events panel (the newest 1000 are kept): an event in one of its states, or a note (.None: a desync).
log :: proc(tick: u32, state: Log_State, format: string, args: ..any) {
	if !s.inited do return
	log_add(&s.events, tick, state, format, ..args)
}

// A row in the Commands panel (the newest 1000 are kept): a command sent, confirmed in a verified tick, or refused.
command :: proc(tick: u32, state: Log_State, format: string, args: ..any) {
	if !s.inited do return
	log_add(&s.commands, tick, state, format, ..args)
}

// Updates the panels. Call once per frame on the main thread (from a node's _process).
frame :: proc(dt: f64) {
	if !s.inited do return
	start := time.tick_now()
	frame_time_add(f32(dt * 1000))
	defer {
		clear(&s.stats)
		inspector_end_frame(&s.insp)
		inspector_end_frame(&s.input)
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
	for kind in ([]Panel_Kind{.Inspector, .Input}) {
		inspector := kind == .Inspector ? &s.insp : &s.input
		if len(inspector.pending) > 0 do inspector_build_pending(inspector)
		if s.panels[kind].open && (slow || inspector.dirty) do inspector_refresh(inspector)
	}
	if s.panels[.Events].open do log_update(&s.events)
	if s.panels[.Commands].open do log_update(&s.commands)
	if s.panels[.Conditions].open && netsim_applies != s.cond.applies do conditions_enable()
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
	if mouse_button := gd.object_cast(gd.InputEventMouseButton, obj); mouse_button.ptr != nil {
		if window != nil { 	// a popped-out panel: every press there is the dev UI's
			if gd.InputEvent_is_pressed(mouse_button) do release_actions(mouse_button)
			return {}
		}
		s.mouse = gd.InputEventMouse_get_position(mouse_button)
		if (s.shown || s.panels[.Note].open) && gd.InputEvent_is_pressed(mouse_button) {
			if over_ui(points(s.mouse)) {
				release_actions(mouse_button)
			} else if ours(gd.Viewport_gui_get_focus_owner(s.root)) {
				gd.Viewport_gui_release_focus(s.root) // a click outside the dev UI gives the keyboard back to the game
			}
		}
		return {}
	}
	if window == nil {
		if mouse_event := gd.object_cast(gd.InputEventMouse, obj); mouse_event.ptr != nil {
			s.mouse = gd.InputEventMouse_get_position(mouse_event)
			return {}
		}
	}
	key_event := gd.object_cast(gd.InputEventKey, obj)
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

// A press on the dev UI never reaches the game. Godot stops the click at the control, but Input's action state
// already holds it (Input updates before the window sees the event), and polled game input reads that state: the
// actions the press triggered are released. Godot presses them again only on a new press, so a press that began on
// the dev UI stays away from the game until the button is let go.
@(private)
release_actions :: proc(event: gd.InputEventMouseButton) {
	input := gd.Input_singleton()
	actions := gd.InputMap_get_actions(gd.InputMap_singleton())
	defer gd.Array_destroy(&actions)
	for i in 0 ..< gd.array_len(&actions) {
		name, _ := gd.from_variant(string, gd.array_at(&actions, i))
		if gd.InputEvent_is_action(event, name) do gd.Input_action_release(input, name)
	}
}

// The point (in points) is over a panel or the overlay's buttons.
@(private)
over_ui :: proc(point: gd.Vector2) -> bool {
	if s.shown && rect_has(gd.Control_get_global_rect(s.overlay.buttons), point) do return true
	if s.shown && rect_has(gd.Control_get_global_rect(s.overlay.frames_button), point) do return true
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
event_arg :: proc($Event: typeid, args: []^gd.Variant) -> Event {
	if len(args) < 1 do return {}
	obj, _ := gd.from_variant(gd.Object, args[0])
	return gd.object_cast(Event, obj)
}

// Window pixels to points.
@(private)
points :: proc(point: gd.Vector2) -> gd.Vector2 {
	return {point.x / s.scale, point.y / s.scale}
}
