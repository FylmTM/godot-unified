// The dev UI: Dear ImGui drawn into Godot from Odin, game-agnostic. F1 shows/hides it (hidden = no cost).
//
//   devui.init({feedback_dir = ..., on_feedback = ...})   main thread, once the scene tree exists
//   every frame, before devui.frame(dt):
//     devui.inspect("state", &frame_state)     RTTI tree of any value (the game passes its State)
//     devui.plot("ping ms", ping, 0, 300)       a sample for a graph in the overlay
//     devui.stat("tick", "%d", tick)            a line in the overlay
//     devui.log(tick, "barrel exploded")        a row in the event log (kept across frames)
//   devui.frame(dt)                            builds the UI and submits it to the RenderingServer
//   devui.shutdown()
//
// Games add their own windows with add_panel. The Netsim panel edits `devui.netsim`; the host polls
// `netsim_changed` and applies it to its links. F3 (also while hidden) captures the screen and opens the
// feedback note; Send writes <feedback_dir>/<stamp>/{screenshot.png,note.txt} and calls on_feedback, where the
// host adds what it has (snapshot, input log, net stats).
//
// Files: backend.odin (ImGui -> RenderingServer canvas items, textures), input.odin (window_input capture),
// panels.odin (overlay, inspector, netsim, event log, note).
package devui

import "core:fmt"
import "core:strings"
import "core:time"
import gd "unified:gdext"
import "unified:gdext/gdi"
import imgui "unified:imgui"

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

Panel :: struct {
	name: string,
	draw: proc(user: rawptr),
	user: rawptr,
	open: bool,
}

visible: bool
netsim: Netsim
netsim_changed: bool // set by the Netsim panel; the host clears it after applying

@(private)
State :: struct {
	cfg:        Config,
	inited:     bool,
	tree:       gd.SceneTree,
	root:       gd.Window,
	root_id:    u64,
	layer_id:   u64,
	layer:      gd.CanvasLayer,
	canvas:     gd.RID,
	scale:      f32,
	size:       [2]f32,
	panels:     [dynamic]Panel,
	inspected:  [dynamic]Inspected,
	graphs:     [dynamic]Graph,
	stats:      [dynamic]string,
	logs:       [LOG_ROWS]Log_Row,
	log_n:      int,
	log_follow: bool,
	note:       Note,
	show:       struct {
		inspector, netsim, events, demo: bool,
	},
	frame_ms:   f32,
	ui_ms:      f32,
	last:       time.Tick,
}

@(private)
s: State

@(private)
Inspected :: struct {
	name:     string,
	data:     any,
	editable: bool,
}

@(private)
GRAPH_LEN :: 240

@(private)
Graph :: struct {
	name:     string,
	min, max: f32,
	values:   [GRAPH_LEN]f32,
	head:     int,
	last:     f32,
	touched:  bool,
}

@(private)
LOG_ROWS :: 1000

@(private)
Log_Row :: struct {
	tick: u32,
	msg:  [96]u8,
	len:  u8,
}

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
	s.show.inspector = true
	s.show.events = true
	s.log_follow = true
	s.tree = gd.cast_to(gd.SceneTree, gd.Engine_get_main_loop(gd.Engine_singleton()))
	s.root = gd.SceneTree_get_root(s.tree)
	s.layer = gd.CanvasLayer_new()
	gd.CanvasLayer_set_layer(s.layer, int(s.cfg.layer))
	gd.Node_set_name(s.layer, "DevUI")
	// deferred: init usually runs inside a node's _ready, while the root is busy adding children
	gd.Object_call_deferred(s.root, "add_child", s.layer)
	s.root_id = gdi.object_get_instance_id(s.root.ptr)
	s.layer_id = gdi.object_get_instance_id(s.layer.ptr)
	s.canvas = gd.CanvasLayer_get_canvas(s.layer)
	input_init()
	backend_init()
	s.last = time.tick_now()
	s.inited = true
}

shutdown :: proc() {
	if !s.inited do return
	backend_shutdown()
	input_shutdown()
	note_shutdown()
	// At extension shutdown the tree may already be gone (Godot frees the layer with it).
	if alive(s.layer_id) && gd.Node_is_inside_tree(s.layer) do gd.Node_queue_free(s.layer)
	delete(s.panels)
	delete(s.inspected)
	delete(s.graphs)
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

// Canvas items drawn and UI time (build + submit) of the last frame.
frame_stats :: proc() -> (items: int, ui_ms: f32) {
	return b.prev_used, s.ui_ms
}

// True when ImGui uses the mouse / keyboard this frame (input then stops at the UI).
wants_mouse :: proc() -> bool {return s.inited && visible && want_mouse}
wants_keyboard :: proc() -> bool {return s.inited && visible && want_keyboard}

add_panel :: proc(name: string, draw: proc(user: rawptr), user: rawptr = nil, open := true) {
	append(&s.panels, Panel{strings.clone(name), draw, user, open})
}

// Shows `data` (any value, read by RTTI) in the Inspector this frame. Editable values are written in place.
inspect :: proc(name: string, data: any, editable := false) {
	if !s.inited || !visible do return
	append(&s.inspected, Inspected{name, data, editable})
}

// Adds a sample to the overlay graph `name` (created on first use).
plot :: proc(name: string, v: f32, lo: f32 = 0, hi: f32 = 0) {
	if !s.inited do return
	for &g in s.graphs {
		if g.name == name {
			g.values[g.head] = v
			g.head = (g.head + 1) % GRAPH_LEN
			g.last = v
			g.touched = true
			return
		}
	}
	g := Graph {
		name = strings.clone(name),
		min  = lo,
		max  = hi,
	}
	g.values[0] = v
	g.head = 1
	g.last = v
	g.touched = true
	append(&s.graphs, g)
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

// Builds and submits the UI. Call once per frame on the main thread (from a node's _process).
frame :: proc(dt: f64) {
	if !s.inited do return
	t0 := time.tick_now()
	s.frame_ms = f32(dt * 1000)
	defer {
		clear(&s.inspected)
		clear(&s.stats)
		clear(&events)
	}
	handle_hotkeys()
	if !visible {
		backend_hide()
		return
	}
	update_metrics()
	io := imgui.GetIO()
	io.DisplaySize = {s.size.x, s.size.y}
	io.DisplayFramebufferScale = {s.scale, s.scale}
	io.DeltaTime = max(f32(time.duration_seconds(time.tick_since(s.last))), 1e-4)
	s.last = time.tick_now()
	feed_input(io)
	imgui.NewFrame()
	draw_panels()
	imgui.Render()
	want_mouse = io.WantCaptureMouse
	want_keyboard = io.WantCaptureKeyboard
	render(imgui.GetDrawData())
	s.ui_ms = f32(time.duration_milliseconds(time.tick_since(t0)))
}

@(private)
update_metrics :: proc() {
	vr := gd.Viewport_get_visible_rect(s.root)
	// macOS sizes windows in physical pixels (HiDPI); the UI works in points.
	s.scale = gd.DisplayServer_screen_get_scale(gd.DisplayServer_singleton(), -1)
	if s.scale <= 0 do s.scale = 1
	s.size = {vr.size.x / s.scale, vr.size.y / s.scale}
}
