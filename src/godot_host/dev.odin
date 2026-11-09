// The dev UI (unified:devui, Dear ImGui) behind a compile switch: `-define:UNIFIED_DEVUI=false` builds a host
// without it (these procs become no-ops and ImGui is not linked). On in every build for now, release included.
package godot_host

import "unified:devui"

DEVUI :: #config(UNIFIED_DEVUI, true)

when DEVUI {
	@(private)
	dev_init :: proc(visible: bool, lag: Netsim_Settings) {
		if lag.enabled do devui.netsim = {lag.enabled, lag.latency_ms, lag.jitter_ms, lag.loss_pct}
		if !devui.is_ready() do devui.init({visible = visible})
	}

	@(private)
	dev_shutdown :: proc() {devui.shutdown()}
	@(private)
	dev_wants_mouse :: proc() -> bool {return devui.wants_mouse()}
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

	// Main thread, every frame: the overlay's stats and graphs, the inspector, the Netsim panel.
	@(private)
	dev_frame :: proc(s: ^Session_Node, dt: f64) {
		if devui.visible && s.frame != nil {
			f := s.frame
			devui.stat("tick", "%d  verified %d  slot %d", f.tick, f.verified, f.local_slot)
			devui.stat(
				"net",
				"rtt %.0f ms  delay %d  rollbacks %d  resim %d",
				f.net.rtt_ms,
				f.net.delay,
				f.net.rollbacks,
				f.net.resim_ticks,
			)
			devui.stat("views", "%d scene  %d bulk  sync %.0f us", f.n_scene, f.n_bulk, s.sync_us)
			devui.plot("frame ms", f32(dt * 1000), 0, 50)
			devui.plot("rtt ms", f.net.rtt_ms, 0, 300)
			if st := api.state(); st != nil do devui.inspect("predicted state (read-only)", st)
		} else if devui.visible {
			devui.stat("session", "%s", STATUS_NAMES[s.status])
		}
		devui.frame(dt)
		if devui.netsim_changed {
			devui.netsim_changed = false
			n := devui.netsim
			set_netsim({n.enabled, n.latency_ms, n.jitter_ms, n.loss_pct})
		}
	}
} else {
	_ :: devui

	@(private)
	dev_init :: proc(visible: bool, lag: Netsim_Settings) {}
	@(private)
	dev_shutdown :: proc() {}
	@(private)
	dev_wants_mouse :: proc() -> bool {return false}
	@(private)
	dev_wants_keyboard :: proc() -> bool {return false}
	@(private)
	dev_visible :: proc() -> bool {return false}
	@(private)
	dev_toggle :: proc() {}
	@(private)
	dev_log :: proc(tick: u32, format: string, args: ..any) {}
	@(private)
	dev_frame :: proc(s: ^Session_Node, dt: f64) {}
}
