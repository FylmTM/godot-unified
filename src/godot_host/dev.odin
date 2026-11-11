// The dev UI (unified:devui, Dear ImGui) behind a compile switch: `-define:UNIFIED_DEVUI=false` builds a host
// without it (these procs become no-ops and ImGui is not linked). On in every build for now, release included.
// SPIKE: `-- --devui-controls` picks unified:devui_controls (the same panels on Godot controls) at run time.
package godot_host

import "core:strings"
import "unified:devui"
import dc "unified:devui_controls"

DEVUI :: #config(UNIFIED_DEVUI, true)

when DEVUI {
	@(private)
	dev_gd: bool // the Godot-controls dev UI (spike)

	@(private)
	dev_init :: proc(visible: bool, lag: Netsim_Settings, controls := false) {
		if devui.is_ready() || dc.is_ready() do return
		dev_gd = controls
		if dev_gd {
			if lag.enabled do dc.netsim = {lag.enabled, lag.latency_ms, lag.jitter_ms, lag.loss_pct}
			dc.init({visible = visible})
		} else {
			if lag.enabled do devui.netsim = {lag.enabled, lag.latency_ms, lag.jitter_ms, lag.loss_pct}
			devui.init({visible = visible})
		}
	}

	@(private)
	dev_shutdown :: proc() {devui.shutdown(); dc.shutdown()}
	@(private)
	dev_wants_mouse :: proc() -> bool {return dev_gd ? dc.wants_mouse() : devui.wants_mouse()}
	@(private)
	dev_wants_keyboard :: proc() -> bool {return dev_gd ? dc.wants_keyboard() : devui.wants_keyboard()}
	@(private)
	dev_visible :: proc() -> bool {return dev_gd ? dc.visible : devui.visible}
	@(private)
	dev_gates_events :: proc() -> bool {return !dev_gd}
	@(private)
	dev_toggle :: proc() {
		if dev_gd do dc.visible = !dc.visible
		else do devui.visible = !devui.visible
	}
	// Spike: expand inspector rows (Godot-controls UI only), "a/b/*".
	@(private)
	dev_debug_expand :: proc(path: string) {
		if dev_gd do dc.debug_expand(strings.split(path, "/", context.temp_allocator))
	}
	// Spike measurements: nodes or canvas items, and the dev UI's own time in its last frame.
	@(private)
	dev_frame_stats :: proc() -> (items: int, ui_ms: f32) {
		if dev_gd do return dc.frame_stats()
		return devui.frame_stats()
	}

	@(private)
	dev_log :: proc(tick: u32, format: string, args: ..any) {
		if dev_gd do dc.log(tick, format, ..args)
		else do devui.log(tick, format, ..args)
	}

	@(private)
	dev_stat :: proc(label: string, format: string, args: ..any) {
		if dev_gd do dc.stat(label, format, ..args)
		else do devui.stat(label, format, ..args)
	}

	// Main thread, every frame: the overlay's stats and graphs, the inspector, the Netsim panel.
	@(private)
	dev_frame :: proc(s: ^Session_Node, dt: f64) {
		if dev_visible() && s.frame != nil {
			f := s.frame
			dev_stat("tick", "%d  verified %d  slot %d", f.tick, f.verified, f.local_slot)
			dev_stat(
				"net",
				"rtt %.0f ms  delay %d  rollbacks %d  resim %d",
				f.net.rtt_ms,
				f.net.delay,
				f.net.rollbacks,
				f.net.resim_ticks,
			)
			dev_stat("views", "%d scene  %d bulk  sync %.0f us", f.n_scene, f.n_bulk, s.sync_us)
			if dev_gd {
				dc.plot("frame ms", f32(dt * 1000), 0, 50)
				dc.plot("rtt ms", f.net.rtt_ms, 0, 300)
				if st := api.state(); st != nil do dc.inspect("predicted state (read-only)", st)
			} else {
				devui.plot("frame ms", f32(dt * 1000), 0, 50)
				devui.plot("rtt ms", f.net.rtt_ms, 0, 300)
				if st := api.state(); st != nil do devui.inspect("predicted state (read-only)", st)
			}
		} else if dev_visible() {
			dev_stat("session", "%s", STATUS_NAMES[s.status])
		}
		if dev_gd {
			dc.frame(dt)
			if dc.netsim_changed {
				dc.netsim_changed = false
				n := dc.netsim
				set_netsim({n.enabled, n.latency_ms, n.jitter_ms, n.loss_pct})
			}
		} else {
			devui.frame(dt)
			if devui.netsim_changed {
				devui.netsim_changed = false
				n := devui.netsim
				set_netsim({n.enabled, n.latency_ms, n.jitter_ms, n.loss_pct})
			}
		}
	}
} else {
	_ :: devui
	_ :: dc
	_ :: strings

	@(private)
	dev_init :: proc(visible: bool, lag: Netsim_Settings, controls := false) {}
	@(private)
	dev_shutdown :: proc() {}
	@(private)
	dev_wants_mouse :: proc() -> bool {return false}
	@(private)
	dev_wants_keyboard :: proc() -> bool {return false}
	@(private)
	dev_visible :: proc() -> bool {return false}
	@(private)
	dev_gates_events :: proc() -> bool {return false}
	@(private)
	dev_toggle :: proc() {}
	@(private)
	dev_frame_stats :: proc() -> (items: int, ui_ms: f32) {return}
	@(private)
	dev_debug_expand :: proc(path: string) {}
	@(private)
	dev_log :: proc(tick: u32, format: string, args: ..any) {}
	@(private)
	dev_frame :: proc(s: ^Session_Node, dt: f64) {}
}
