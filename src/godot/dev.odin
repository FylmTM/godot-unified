// The dev UI (unified:devui) behind a compile switch: `-define:UNIFIED_DEVUI=false` builds a host without it (these
// procs become no-ops; `uni release --no-devui`). Player builds keep it while friends playtest.
//
// The host feeds the dev UI's graphs, in groups the overlay toggles:
//   frame  the frame time; the main thread split: views (this session's _process: input and view sync, the dev UI's
//          own share shown apart), game (every other node's _process up to drawing), render (the RenderingServer's draw)
//   sim    the sim thread's time per frame (verified, re-run in a rollback, newly predicted), ticks ahead (predicted
//          past the verified tick), and marks: rollback, late input (the relay replaced ours), stall (the prediction
//          cap held the sim back), desync (the relay's report; its detail goes to the Events panel); with it, the
//          `ticks/s` line: ticks stepped per second, new (each tick's first step: about the tick rate while the
//          session keeps pace), re-run (rollbacks) and, joining, catch-up (new ticks stepped late, every input
//          already known: the client fell behind; a host or single player steps most ticks that way, normally)
//   net    round trip, bandwidth in and out, relay silence (time since the relay's last message)
// and its panels: the Inspector (the predicted state, the constants, the session data), Input (the local player's
// newest input and the verified tick's), Events (every event state), Commands (sent, confirmed, refused) and the F3
// note, which gets the session's recording (driver.odin: a snapshot and the input log after it).
#+private
package godot

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:time"
import "unified:devui"
import gd "unified:gdext"
import "unified:netcode"
import "unified:sim"

DEVUI :: #config(UNIFIED_DEVUI, true)

// One direction of the dev netsim.
Netsim_Dir :: devui.Netsim_Dir

// The dev netsim (the dev UI's Conditions panel, --lag): its settings are the panel's.
Netsim_Settings :: devui.Netsim

when DEVUI {
	Dev :: struct {
		begin, end:   time.Tick, // this session's _process, this frame
		pre, post:    time.Tick, // RenderingServer frame_pre_draw / frame_post_draw, the last frame
		draw:         [2]gd.Callable,
		prev_begin:   time.Tick,
		prev_end:     time.Tick,
		prev_sync_us: f32,
		prev_ui_ms:   f32,
		net:          netcode.Client_Stats, // the last frame's cumulative counters
		have_net:     bool,
		bw_bytes:     [2]i64, // bandwidth window: bytes in, out
		bw_us:        i64,
		bw:           [2]f32, // kB/s
		steps:        [3]i64, // ticks stepped in the current second: verified (catch-up), re-run, predicted (new)
		steps_us:     i64,
		per_second:   [3]f32, // the last full second's
	}

	dev: Dev

	dev_init :: proc(visible: bool, lag: Netsim_Settings) {
		if lag.enabled do devui.netsim = lag
		if devui.is_ready() do return
		devui.init(visible, dev_feedback)
		rendering_server := gd.RenderingServer_singleton()
		dev.draw[0] = gd.callable_create(proc(_: rawptr, _: []^gd.Variant) -> gd.Variant {
				dev.pre = time.tick_now()
				return {}
			}, nil)
		dev.draw[1] = gd.callable_create(proc(_: rawptr, _: []^gd.Variant) -> gd.Variant {
				dev.post = time.tick_now()
				return {}
			}, nil)
		gd.connect(rendering_server, "frame_pre_draw", dev.draw[0])
		gd.connect(rendering_server, "frame_post_draw", dev.draw[1])
	}

	dev_shutdown :: proc() {
		if devui.is_ready() {
			rendering_server := gd.RenderingServer_singleton()
			for &callable, i in dev.draw {
				name := i == 0 ? "frame_pre_draw" : "frame_post_draw"
				if gd.Object_is_connected(rendering_server, name, callable) {
					gd.Object_disconnect(rendering_server, name, callable)
				}
				gd.Callable_destroy(&callable)
			}
		}
		devui.shutdown()
		dev = {}
	}

	// Godot routes the dev UI's events itself, and a press on the dev UI releases the actions it triggered; only
	// the polled game input needs telling that a dev text field has the keyboard.
	dev_wants_keyboard :: proc() -> bool {return devui.wants_keyboard()}
	dev_visible :: proc() -> bool {return devui.visible}
	// The session thread copies the newest state and inputs only while a panel shows them.
	dev_wants_state :: proc() -> bool {return devui.wants_state()}
	dev_set_visible :: proc(visible: bool) {devui.visible = visible}

	// A session starts: the frames line (p50, p99, max) starts over.
	dev_session_started :: proc() {devui.frames_reset()}

	// An event in one of its states, to the Events panel.
	dev_event :: proc(tick: u32, id: u64, action: Event_Action, layout: ^Event_Layout, data: []u8) {
		state: devui.Log_State
		switch action {
		case .Emitted:
			state = .Emitted
		case .Confirmed:
			state = .Confirmed
		case .Cancelled:
			state = .Cancelled
		}
		player, entity := event_subject(layout, data)
		devui.log(tick, state, "#%d %s player %d entity %d", id, layout.name, player, entity)
	}

	// A note in the Events panel (a desync report).
	dev_note :: proc(tick: u32, text: string) {
		devui.log(tick, .None, "%s", text)
	}

	// A command to the Commands panel: its struct and fields (a command of another build: its kind).
	dev_command :: proc(tick: u32, state: devui.Log_State, player: u64, command: ^sim.Raw_Command) {
		if int(command.kind) >= len(api.commands) {
			devui.command(tick, state, "player %d  command kind %d", player, command.kind)
			return
		}
		value := any{&command.data[0], api.commands[command.kind].type.id}
		devui.command(tick, state, "player %d  %v", player, value)
	}

	// The start of this session's _process (it runs first: process priority -1000).
	dev_begin :: proc() {
		dev.prev_begin, dev.prev_end = dev.begin, dev.end
		dev.begin = time.tick_now()
	}

	// Main thread, every frame: the overlay's stats and graphs, the panels' data, the Conditions panel.
	dev_frame :: proc(session: ^Session_Node, dt: f64) {
		dev_main_thread()
		devui.netsim_applies = !(session.mode == .Single && api.installed && api.running())
		for api.installed {
			note := api.next_confirmed() or_break
			player: u64
			if session.frame != nil && int(note.command.slot) < len(session.frame.slots) {
				player = session.frame.slots[note.command.slot]
			}
			dev_command(note.tick, .Confirmed, player, &note.command)
		}
		if devui.visible && session.frame != nil {
			frame := session.frame
			devui.stat("tick", "%d   verified %d   player %d", frame.tick, frame.verified, frame.local_player)
			devui.stat(
				"net",
				"rtt %.0f ms   input delay %d   rollbacks %d (%d ticks)",
				frame.net.rtt_ms,
				frame.net.delay,
				frame.net.rollbacks,
				frame.net.resim_ticks,
			)
			if devui.group_shown("sim") {
				joining := session.mode == .Join_Direct || session.mode == .Join_Online
				new_ticks, catch_up := dev.per_second[0] + dev.per_second[2], dev.per_second[0]
				if joining {
					devui.stat(
						"ticks/s",
						"new %.0f   re-run %.0f   catch-up %.0f",
						new_ticks,
						dev.per_second[1],
						catch_up,
					)
				} else {
					devui.stat("ticks/s", "new %.0f   re-run %.0f", new_ticks, dev.per_second[1])
				}
			}
			devui.stat(
				"views",
				"%d scene   %d multimesh   sync %.0f µs   events dropped %d",
				frame.n_views,
				frame.n_multis,
				session.sync_us,
				api.events_dropped(),
			)
			if state := api.state(); state != nil do devui.inspect("predicted state (read-only)", state)
			if inputs := api.inputs(); inputs != nil do devui.inputs("inputs", inputs)
		} else if devui.visible {
			devui.stat("session", "%s", STATUS_NAMES[session.status])
		}
		if devui.visible {
			if api.installed && api.constants.type != nil {
				devui.inspect("constants", any{raw_data(api.constants_bytes), api.constants.type.id})
			}
			for data_class in D.data {
				if data_class == nil || data_class.instance == nil do continue
				value := any{raw_data(data_class.instance.bytes), data_class.layout.type.id}
				devui.inspect(fmt.tprintf("data.%s", data_class.layout.property), value)
			}
			performance := gd.Performance_singleton()
			devui.stat(
				"render",
				"%.0f draw calls   %.0fk triangles   %.0f MB video   %.0f nodes",
				gd.Performance_get_monitor(performance, .RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
				gd.Performance_get_monitor(performance, .RENDER_TOTAL_PRIMITIVES_IN_FRAME) / 1000,
				gd.Performance_get_monitor(performance, .RENDER_VIDEO_MEM_USED) / (1 << 20),
				gd.Performance_get_monitor(performance, .OBJECT_NODE_COUNT),
			)
		}
		if session.frame != nil do dev_sim_graphs(session.frame, dt)
		devui.frame(dt)
		dev.prev_sync_us = session.sync_us
		_, dev.prev_ui_ms = devui.frame_stats()
		dev.end = time.tick_now()
		if devui.netsim_changed {
			devui.netsim_changed = false
			set_netsim(devui.netsim)
		}
	}

	// The last frame's main thread, now that it is complete (its drawing came after its _process).
	dev_main_thread :: proc() {
		ms :: proc(start, end: time.Tick) -> f32 {
			if start._nsec == 0 || end._nsec < start._nsec do return 0
			return f32(time.duration_milliseconds(time.tick_diff(start, end)))
		}
		host := ms(dev.prev_begin, dev.prev_end)
		ui := min(dev.prev_ui_ms, host)
		game := ms(dev.prev_end, dev.pre)
		render := ms(dev.pre, dev.post)
		devui.stack("frame", "main thread ms", {host - ui, ui, game, render}, {"views", "dev ui", "game", "render"})
	}

	dev_sim_graphs :: proc(frame: ^Frame_Data, dt: f64) {
		net := frame.net
		prev := dev.net
		if !dev.have_net ||
		   net.steps[.Verified] < prev.steps[.Verified] ||
		   net.net.bytes_recv < prev.net.bytes_recv { 	// a new session
			prev = net
			dev.have_net = true
			dev.steps, dev.steps_us, dev.per_second = {}, 0, {}
		}
		dev.net = net
		step_ms: [3]f32
		for kind, k in netcode.Step_Kind {
			step_ms[k] = f32(net.step_us[kind] - prev.step_us[kind]) / 1000
			dev.steps[k] += i64(net.steps[kind] - prev.steps[kind])
		}
		// ticks stepped per second, over whole seconds
		dev.steps_us += i64(dt * 1e6)
		if dev.steps_us >= 1_000_000 {
			for k in 0 ..< 3 do dev.per_second[k] = f32(dev.steps[k]) / (f32(dev.steps_us) / 1e6)
			dev.steps, dev.steps_us = {}, 0
		}
		devui.stack("sim", "sim thread ms", step_ms[:], {"verified", "rollback", "predicted"})
		devui.plot("sim", "ticks ahead", f32(frame.tick) - f32(frame.verified))
		if net.rollbacks > prev.rollbacks do devui.mark("sim", "sim events", "rollback")
		if net.own_replaced > prev.own_replaced do devui.mark("sim", "sim events", "late input")
		if net.stall_ticks > prev.stall_ticks do devui.mark("sim", "sim events", "stall")
		if net.desyncs > prev.desyncs do devui.mark("sim", "sim events", "desync")

		devui.plot("net", "round trip ms", f32(net.rtt_ms))
		// bandwidth over 250 ms windows
		dev.bw_bytes[0] += i64(net.net.bytes_recv - prev.net.bytes_recv)
		dev.bw_bytes[1] += i64(net.net.bytes_sent - prev.net.bytes_sent)
		dev.bw_us += i64(dt * 1e6)
		if dev.bw_us >= 250_000 {
			for k in 0 ..< 2 do dev.bw[k] = f32(dev.bw_bytes[k]) / 1024 / (f32(dev.bw_us) / 1e6)
			dev.bw_bytes, dev.bw_us = {}, 0
		}
		devui.lines("net", "bandwidth kB/s", dev.bw[:], {"in", "out"})
		since: f32
		if net.last_msg_us != 0 do since = f32(netcode.now_us() - net.last_msg_us) / 1000
		devui.plot("net", "relay silence ms", since)
	}

	// devui's on_feedback (main thread, a note was just written to `dir`): the session's recording, so the note
	// replays (`uni headless <game> -- replay --snapshot snapshot.unis --log inputs.unil`), and note.json.
	dev_feedback :: proc(dir: string, tag_bug: bool) {
		snapshot, input_log: [dynamic]u8
		defer delete(snapshot)
		defer delete(input_log)
		info: Recording_Info
		recorded := false
		if api.installed do info, recorded = api.recording(&snapshot, &input_log)
		Note_Json :: struct {
			game:       string,
			version:    string,
			bug:        bool,
			session:    string,
			player:     u64,
			tick:       u32, // the newest predicted tick shown
			verified:   u32,
			recording:  bool, // snapshot.unis and inputs.unil are there
			from_tick:  u32, // the snapshot's tick
			to_tick:    u32, // the log's last
			check_tick: u32, // a tick the replay reaches, and the session's checksum of it (hex; check_tick 0: none)
			checksum:   string,
			net:        netcode.Client_Stats,
		}
		out := Note_Json {
			game      = api.game_name,
			version   = app_version,
			bug       = tag_bug,
			recording = recorded,
		}
		if active != nil {
			out.session = STATUS_NAMES[active.status]
			if frame := active.frame; frame != nil {
				out.player, out.tick, out.verified, out.net = frame.local_player, frame.tick, frame.verified, frame.net
			}
		}
		if recorded {
			out.from_tick, out.to_tick, out.check_tick = info.from, info.to, info.check_tick
			if info.check_tick != 0 do out.checksum = fmt.tprintf("%016x", info.check)
			ok := os.write_entire_file(fmt.tprintf("%s/snapshot.unis", dir), snapshot[:]) == nil
			ok &&= os.write_entire_file(fmt.tprintf("%s/inputs.unil", dir), input_log[:]) == nil
			if !ok do gd.print_error(fmt.tprintf("unified: the recording of %s was not saved", dir))
		}
		text, err := json.marshal(out, {pretty = true}, context.temp_allocator)
		if err == nil do _ = os.write_entire_file(fmt.tprintf("%s/note.json", dir), text)
	}
} else {
	_ :: devui
	_ :: time
	_ :: gd
	_ :: netcode
	_ :: json
	_ :: os
	_ :: fmt

	dev_init :: proc(visible: bool, lag: Netsim_Settings) {}
	dev_shutdown :: proc() {}
	dev_wants_keyboard :: proc() -> bool {return false}
	dev_visible :: proc() -> bool {return false}
	dev_wants_state :: proc() -> bool {return false}
	dev_set_visible :: proc(visible: bool) {}
	dev_session_started :: proc() {}
	dev_event :: proc(tick: u32, id: u64, action: Event_Action, layout: ^Event_Layout, data: []u8) {}
	dev_note :: proc(tick: u32, text: string) {}
	dev_command :: proc(tick: u32, state: devui.Log_State, player: u64, command: ^sim.Raw_Command) {}
	dev_begin :: proc() {}
	dev_frame :: proc(session: ^Session_Node, dt: f64) {}
}
