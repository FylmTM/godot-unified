// The dev UI (unified:devui) behind a compile switch: `-define:UNIFIED_DEVUI=false` builds a host without it (these
// procs become no-ops). On in every build for now, release included.
//
// The host feeds the dev UI's graphs, in groups the overlay toggles:
//   frame  the frame time; the main thread split: views (this session's _process: input and view sync, the dev UI's
//          own share shown apart), game (every other node's _process up to drawing), render (the RenderingServer's draw)
//   sim    the sim thread: time and ticks stepped per frame (verified, re-run in a rollback, newly predicted),
//          ticks ahead (predicted past the verified tick), and marks: rollback, late input (the
//          relay replaced ours), stall (the prediction cap held the sim back)
//   net    round trip, bandwidth in and out, relay silence (time since the relay's last message)
package godot_host

import "core:time"
import "unified:devui"
import gd "unified:gdext"
import "unified:netcode"

DEVUI :: #config(UNIFIED_DEVUI, true)

when DEVUI {
	@(private)
	Dev :: struct {
		begin, end:   time.Tick, // this session's _process, this frame
		pre, post:    time.Tick, // RenderingServer frame_pre_draw / frame_post_draw, the last frame
		draw:         [2]gd.Callable,
		prev_begin:   time.Tick,
		prev_end:     time.Tick,
		prev_sync_us: f32,
		prev_ui_ms:   f32,
		net:          Net_Stats, // the last frame's cumulative counters
		have_net:     bool,
		bw_bytes:     [2]i64, // bandwidth window: bytes in, out
		bw_us:        i64,
		bw:           [2]f32, // kB/s
	}

	@(private)
	dev: Dev

	@(private)
	dev_init :: proc(visible: bool, lag: Netsim_Settings) {
		if lag.enabled {
			devui.netsim = {true, dir_to_ui(lag.up), dir_to_ui(lag.down)}
		}
		if devui.is_ready() do return
		devui.init({visible = visible})
		rs := gd.RenderingServer_singleton()
		dev.draw[0] = gd.callable_create(proc(_: rawptr, _: []^gd.Variant) -> gd.Variant {
				dev.pre = time.tick_now()
				return {}
			}, nil)
		dev.draw[1] = gd.callable_create(proc(_: rawptr, _: []^gd.Variant) -> gd.Variant {
				dev.post = time.tick_now()
				return {}
			}, nil)
		gd.connect(rs, "frame_pre_draw", dev.draw[0])
		gd.connect(rs, "frame_post_draw", dev.draw[1])
	}

	@(private)
	dev_shutdown :: proc() {
		if devui.is_ready() {
			rs := gd.RenderingServer_singleton()
			for &c, i in dev.draw {
				name := i == 0 ? "frame_pre_draw" : "frame_post_draw"
				if gd.Object_is_connected(rs, name, c) do gd.Object_disconnect(rs, name, c)
				gd.Callable_destroy(&c)
			}
		}
		devui.shutdown()
		dev = {}
	}

	@(private)
	dir_to_ui :: proc(d: Netsim_Dir) -> devui.Netsim_Dir {return {d.latency_ms, d.jitter_ms, d.loss_pct}}
	@(private)
	dir_from_ui :: proc(d: devui.Netsim_Dir) -> Netsim_Dir {return {d.latency_ms, d.jitter_ms, d.loss_pct}}

	// Godot routes the dev UI's events itself; only the polled game input needs telling (a dev text field has
	// the keyboard).
	@(private)
	dev_wants_keyboard :: proc() -> bool {return devui.wants_keyboard()}
	@(private)
	dev_visible :: proc() -> bool {return devui.visible}
	@(private)
	dev_toggle :: proc() {devui.visible = !devui.visible}

	@(private)
	dev_log :: proc(tick: u32, format: string, args: ..any) {
		devui.log(tick, format, ..args)
	}

	// The start of this session's _process (it runs first: process priority -1000).
	@(private)
	dev_begin :: proc() {
		dev.prev_begin, dev.prev_end = dev.begin, dev.end
		dev.begin = time.tick_now()
	}

	// Main thread, every frame: the overlay's stats and graphs, the inspector, the Conditions panel.
	@(private)
	dev_frame :: proc(s: ^Session_Node, dt: f64) {
		dev_main_thread()
		if devui.visible && s.frame != nil {
			f := s.frame
			devui.stat("tick", "%d   verified %d   slot %d", f.tick, f.verified, f.local_slot)
			devui.stat(
				"net",
				"rtt %.0f ms   input delay %d   rollbacks %d (%d ticks)",
				f.net.rtt_ms,
				f.net.delay,
				f.net.rollbacks,
				f.net.resim_ticks,
			)
			devui.stat("views", "%d scene   %d multimesh   sync %.0f µs", f.n_scene, f.n_bulk, s.sync_us)
			if st := api.state(); st != nil do devui.inspect("predicted state (read-only)", st)
		} else if devui.visible {
			devui.stat("session", "%s", STATUS_NAMES[s.status])
		}
		if devui.visible {
			p := gd.Performance_singleton()
			devui.stat(
				"render",
				"%.0f draw calls   %.0fk triangles   %.0f MB video   %.0f nodes",
				gd.Performance_get_monitor(p, .RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
				gd.Performance_get_monitor(p, .RENDER_TOTAL_PRIMITIVES_IN_FRAME) / 1000,
				gd.Performance_get_monitor(p, .RENDER_VIDEO_MEM_USED) / (1 << 20),
				gd.Performance_get_monitor(p, .OBJECT_NODE_COUNT),
			)
		}
		if s.frame != nil do dev_sim_graphs(s.frame, dt)
		devui.frame(dt)
		dev.prev_sync_us = s.sync_us
		_, dev.prev_ui_ms = devui.frame_stats()
		dev.end = time.tick_now()
		if devui.netsim_changed {
			devui.netsim_changed = false
			n := devui.netsim
			set_netsim({n.enabled, dir_from_ui(n.up), dir_from_ui(n.down)})
		}
	}

	// The last frame's main thread, now that it is complete (its drawing came after its _process).
	@(private)
	dev_main_thread :: proc() {
		ms :: proc(a, b: time.Tick) -> f32 {
			if a._nsec == 0 || b._nsec < a._nsec do return 0
			return f32(time.duration_milliseconds(time.tick_diff(a, b)))
		}
		host := ms(dev.prev_begin, dev.prev_end)
		ui := min(dev.prev_ui_ms, host)
		game := ms(dev.prev_end, dev.pre)
		render := ms(dev.pre, dev.post)
		devui.stack("main thread ms", {host - ui, ui, game, render}, {"views", "dev ui", "game", "render"}, "frame")
	}

	@(private)
	dev_sim_graphs :: proc(f: ^Frame, dt: f64) {
		n := f.net
		p := dev.net
		if !dev.have_net || n.steps[0] < p.steps[0] || n.bytes_in < p.bytes_in { 	// a new session
			p = n
			dev.have_net = true
		}
		dev.net = n
		d_us: [3]f32
		d_steps: [3]f32
		for k in 0 ..< 3 {
			d_us[k] = f32(n.step_us[k] - p.step_us[k]) / 1000
			d_steps[k] = f32(n.steps[k] - p.steps[k])
		}
		legend := []string{"verified", "rollback", "predicted"}
		devui.stack("sim thread ms", d_us[:], legend, "sim")
		devui.stack("ticks stepped", d_steps[:], legend, "sim")
		devui.plot("ticks ahead", f32(f.tick) - f32(f.verified), 0, 0, "sim")
		if n.rollbacks > p.rollbacks do devui.mark("sim events", "rollback", "sim")
		if n.replaced > p.replaced do devui.mark("sim events", "late input", "sim")
		if n.stalls > p.stalls do devui.mark("sim events", "stall", "sim")

		devui.plot("round trip ms", n.rtt_ms, 0, 0, "net")
		// bandwidth over 250 ms windows
		dev.bw_bytes[0] += n.bytes_in - p.bytes_in
		dev.bw_bytes[1] += n.bytes_out - p.bytes_out
		dev.bw_us += i64(dt * 1e6)
		if dev.bw_us >= 250_000 {
			for k in 0 ..< 2 do dev.bw[k] = f32(dev.bw_bytes[k]) / 1024 / (f32(dev.bw_us) / 1e6)
			dev.bw_bytes, dev.bw_us = {}, 0
		}
		devui.lines("bandwidth kB/s", dev.bw[:], {"in", "out"}, 0, 0, "net")
		since: f32
		if n.last_msg_us != 0 do since = f32(netcode.now_us() - n.last_msg_us) / 1000
		devui.plot("relay silence ms", since, 0, 0, "net")
	}
} else {
	_ :: devui
	_ :: time
	_ :: gd
	_ :: netcode

	@(private)
	dev_init :: proc(visible: bool, lag: Netsim_Settings) {}
	@(private)
	dev_shutdown :: proc() {}
	@(private)
	dev_wants_keyboard :: proc() -> bool {return false}
	@(private)
	dev_visible :: proc() -> bool {return false}
	@(private)
	dev_toggle :: proc() {}
	@(private)
	dev_log :: proc(tick: u32, format: string, args: ..any) {}
	@(private)
	dev_begin :: proc() {}
	@(private)
	dev_frame :: proc(s: ^Session_Node, dt: f64) {}
}
