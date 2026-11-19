// The dev UI (unified:devui) behind a compile switch: `-define:UNIFIED_DEVUI=false` builds a host without it (these
// procs become no-ops; `uni release --no-devui`). Player builds keep it while friends playtest.
//
// The host feeds the dev UI's graphs, in groups the overlay toggles:
//   frame  the frame time; the main thread split: views (this session's _process: input and view sync, the dev UI's
//          own share shown apart), game (every other node's _process up to drawing), render (the RenderingServer's draw)
//   sim    the sim thread's time per frame (verified, re-run in a rollback, newly predicted), the zones' self times
//          (sim.zone, the game's systems), ticks ahead (predicted
//          past the verified tick), and marks: rollback, late input (the relay replaced ours), stall (the prediction
//          cap held the sim back), desync (the relay's report; its detail goes to the Events panel); with it, the
//          `ticks/s` line: ticks stepped per second, new (each tick's first step: about the tick rate while the
//          session keeps pace), re-run (rollbacks) and, joining, catch-up (new ticks stepped late, every input
//          already known: the client fell behind; a host or single player steps most ticks that way, normally)
//   net    round trip, bandwidth in and out, relay silence (time since the relay's last message)
// and its panels: the Inspector (the predicted state, the constants, the session data), Input (the local player's
// newest input and the verified tick's), Events (every event state), Commands (sent, confirmed: a verified tick carried
// it, any player's; refused) and the F3 note, which gets the session's recording (driver.odin: a snapshot and the input
// log after it).
#+private
package godot

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
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
		zone_ns:      [sim.ZONES_MAX + 1]i64, // the last frame's cumulative zone times (Frame_Data.zone_ns)
		changes:      Changes_View, // the op log's Inspector root
		changes_seen: u32, // the shown tick it was computed for
		replaying:    bool, // the Timeline panel shows a replay
	}

	// A replay's Timeline panel (dev_frame): its state in, its requests out as the replay's controls.
	dev_timeline :: proc(session: ^Session_Node) {
		frame := session.frame
		active := frame != nil && frame.replay.active && session.mode == .Replay
		if !active {
			if dev.replaying do devui.timeline_end()
			dev.replaying = false
			return
		}
		dev.replaying = true
		view := frame.replay
		request := devui.timeline({
			tick        = frame.tick,
			first       = view.first,
			last        = view.last,
			paused      = view.paused,
			speed       = view.speed,
			checkpoints = view.checkpoints,
			agreed      = view.agreed,
			diverged    = view.diverged,
			other_build = view.other_build,
		})
		if request.toggle_pause do replay_control({kind = view.paused ? .Play : .Pause})
		if request.step != 0 do replay_control({kind = .Step, value = i64(request.step)})
		if request.seek >= 0 do replay_control({kind = .Seek, value = request.seek})
		if request.speed != 0 do replay_control({kind = .Speed, speed = request.speed})
	}

	// The op log as the Inspector shows it: what the shown tick changed against the tick before, a line per leaf field
	// ("rocks[3].pos (1, 2) vs (1, 3)"), at most CHANGES_SHOWN.
	CHANGES_SHOWN :: 64
	Changes_View :: struct {
		tick:   u32,
		before: u32, // the tick compared against (the tick itself: none in the ring, nothing shown)
		total:  int, // the differences there are
		lines:  [CHANGES_SHOWN]string,
	}

	// The op log (dev_frame, while the Inspector shows): recomputed when the shown tick changes.
	dev_changes :: proc(shown: u32) {
		if shown != dev.changes_seen {
			dev.changes_seen = shown
			lines, total, tick, before := api.changes(CHANGES_SHOWN)
			for &line in dev.changes.lines {
				delete(line)
				line = ""
			}
			dev.changes.tick, dev.changes.before, dev.changes.total = tick, before, total
			for line, i in lines do dev.changes.lines[i] = strings.clone(line)
		}
		devui.inspect("changes (the shown tick against the one before)", any{&dev.changes, typeid_of(Changes_View)})
	}

	dev: Dev

	dev_init :: proc(visible: bool, lag: Netsim_Settings, verified_players: bool) {
		if lag.enabled do devui.netsim = lag
		if verified_players do devui.verified_players = true
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
		for line in dev.changes.lines do delete(line)
		dev = {}
	}

	// Godot routes the dev UI's events itself, and a press on the dev UI releases the actions it triggered; only
	// the polled game input needs telling that a dev text field has the keyboard.
	dev_wants_keyboard :: proc() -> bool {return devui.wants_keyboard()}
	dev_visible :: proc() -> bool {return devui.visible}
	// The session thread copies the newest state and inputs only while a panel shows them.
	dev_wants_state :: proc() -> bool {return devui.wants_state()}
	dev_set_visible :: proc(visible: bool) {devui.visible = visible}

	// The dev UI's draw-group toggles, as a mask by group index (debug_draw.odin).
	dev_draw_toggles :: proc(names: []string) -> u64 {return devui.draw_groups(names)}

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
		verified_players_want(devui.verified_players)
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
			if VP.started {
				devui.stat(
					"verified",
					"other players at tick %.1f, %.1f behind the prediction",
					VP.play,
					f64(frame.tick) - VP.play,
				)
			}
			devui.stat(
				"views",
				"%d scene   %d multimesh   sync %.0f µs   events dropped %d",
				frame.n_views,
				frame.n_multis,
				session.sync_us,
				api.events_dropped(),
			)
			if state, _ := api.state(); state != nil do devui.inspect("predicted state (read-only)", state)
			if devui.wants_state() do dev_changes(frame.tick)
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
		dev_timeline(session)
		dev_command_forms(session)
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
		dev_zone_graph(frame)
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

	// The sim's zones (sim.zone) as a stacked graph: each zone's self time this frame, in enum order, "other" last;
	// past the graph's parts the last one is the rest.
	dev_zone_graph :: proc(frame: ^Frame_Data) {
		MAX_SHOWN :: 8
		count := frame.zone_count
		if count == 0 do return
		ns := frame.zone_ns
		prev := dev.zone_ns
		if ns[sim.ZONES_MAX] < prev[sim.ZONES_MAX] do prev = ns // a new session (or sim)
		dev.zone_ns = ns
		parts: [MAX_SHOWN]f32
		names: [MAX_SHOWN]string
		shown := min(count + 1, MAX_SHOWN)
		for i in 0 ..= count {
			index := i < count ? i : sim.ZONES_MAX
			part := min(i, MAX_SHOWN - 1)
			parts[part] += f32(ns[index] - prev[index]) / 1e6
			names[part] = i < count ? draw_view.names[i] : "other"
		}
		if count + 1 > MAX_SHOWN do names[MAX_SHOWN - 1] = "rest"
		devui.stack("sim", "zones ms", parts[:shown], names[:shown])
	}

	// The session recordings kept under <user data>/recordings (the oldest beyond go when one is written).
	RECORDINGS_KEPT :: 10

	// Main thread, a live session's Result: its recording goes to <user data>/recordings/<local time>/
	// (snapshot.unis, inputs.unil, session.json: what UnifiedSession.replay opens), keeping the newest
	// RECORDINGS_KEPT.
	dev_save_recording :: proc(session: ^Session_Node) {
		snapshot, input_log: [dynamic]u8
		defer delete(snapshot)
		defer delete(input_log)
		if !api.installed || session.mode == .Replay do return
		info, recorded := api.recording(&snapshot, &input_log)
		if !recorded do return
		root := fmt.tprintf("%s/recordings", gd.OS_get_user_data_dir(gd.OS_singleton()))
		stamp, _ := strings.replace_all(
			gd.Time_get_datetime_string_from_system(gd.Time_singleton()),
			":",
			"",
			context.temp_allocator,
		)
		stamp, _ = strings.replace_all(stamp, "T", "_", context.temp_allocator)
		dir := fmt.tprintf("%s/%s", root, stamp)
		for n := 2; os.exists(dir); n += 1 do dir = fmt.tprintf("%s/%s-%d", root, stamp, n)
		if os.make_directory_all(dir) != nil do return
		Session_Json :: struct {
			game:        string,
			version:     string,
			player:      u64, // who recorded it (the replay follows them)
			from_tick:   u32,
			to_tick:     u32,
			checkpoints: int,
		}
		about := Session_Json {
			game        = api.game_name,
			version     = app_version,
			player      = session.frame != nil ? session.frame.local_player : 0,
			from_tick   = info.from,
			to_tick     = info.to,
			checkpoints = info.checkpoints,
		}
		_ = os.write_entire_file(fmt.tprintf("%s/snapshot.unis", dir), snapshot[:])
		_ = os.write_entire_file(fmt.tprintf("%s/inputs.unil", dir), input_log[:])
		if text, err := json.marshal(about, {pretty = true}, context.temp_allocator); err == nil {
			_ = os.write_entire_file(fmt.tprintf("%s/session.json", dir), text)
		}
		entries, _ := os.read_all_directory_by_path(root, context.temp_allocator)
		names := make([dynamic]string, context.temp_allocator)
		for entry in entries do if entry.type == .Directory do append(&names, entry.fullpath)
		slice.sort(names[:]) // the local time sorts by name
		for path in names[:max(len(names) - RECORDINGS_KEPT, 0)] do _ = os.remove_all(path)
	}

	// One input of a dev command's form, flattened from the command's struct by RTTI: where its value goes.
	Form_Slot :: struct {
		offset: int,
		type:   ^runtime.Type_Info,
		player: bool, // a sim.Player: a choice of the session's players
	}

	// The dev commands' forms as the Commands panel shows them (rebuilt when the session's players change).
	Dev_Forms :: struct {
		built:   bool,
		players: u64, // the present players' keys, hashed, the forms were built with
		kinds:   [dynamic]int, // the command kind of each form
		slots:   [dynamic][dynamic]Form_Slot, // by form: its inputs
		keys:    [dynamic]u64, // a player choice's keys, in order
	}

	dev_forms: Dev_Forms

	// The game's dev commands (sim.DEV_COMMAND_PREFIX) as forms in the Commands panel, and what a Send sends: the
	// command built from the form's values, sent like a script's send_command.
	dev_command_forms :: proc(session: ^Session_Node) {
		if !api.installed do return
		frame := session.frame
		players: u64 = 1
		if frame != nil do for key in frame.slots do players = players * 31 + key
		devui.command_forms_enable(frame != nil && session.mode != .Replay && api.running())
		if !dev_forms.built || players != dev_forms.players {
			dev_forms.built, dev_forms.players = true, players
			dev_forms_build(session)
		}
		form, values, sent := devui.take_form()
		if !sent || form >= len(dev_forms.kinds) do return
		kind := dev_forms.kinds[form]
		layout := &api.commands[kind]
		bytes: [sim.COMMAND_MAX]u8
		for slot, i in dev_forms.slots[form] do form_write(bytes[slot.offset:], slot, values[i])
		command, ok := sim.command_from_bytes(api.commands_type, kind, bytes[:layout.type.size])
		if !ok do return
		tick, player: u64
		if frame != nil do tick, player = u64(frame.tick), frame.local_player
		dev_command(u32(tick), api.send(command, 0) ? .Sent : .Refused, player, &command)
	}

	dev_forms_build :: proc(session: ^Session_Node) {
		for &slots in dev_forms.slots do delete(slots)
		clear(&dev_forms.slots)
		clear(&dev_forms.kinds)
		clear(&dev_forms.keys)
		choices := make([dynamic]string, context.temp_allocator)
		if frame := session.frame; frame != nil {
			for key in frame.slots {
				if key == 0 do continue
				append(&dev_forms.keys, key)
				append(&choices, fmt.tprintf("%s (%d)", player_name(session, i64(key)), key))
			}
		}
		forms := make([dynamic]devui.Form, context.temp_allocator)
		for layout, kind in api.commands {
			if !sim.command_is_dev(api.commands_type, kind) do continue
			slots: [dynamic]Form_Slot
			fields := make([dynamic]devui.Form_Field, context.temp_allocator)
			form_fields(layout.type, 0, "", &slots, &fields, choices[:])
			append(&dev_forms.kinds, kind)
			append(&dev_forms.slots, slots)
			append(&forms, devui.Form{name = layout.name, fields = fields[:]})
		}
		devui.command_forms(forms[:])
	}

	// A struct's fields as form inputs (a nested struct flattened with dotted labels; `_` fields left zero; other
	// types left zero too).
	form_fields :: proc(
		type: ^runtime.Type_Info,
		base: int,
		prefix: string,
		slots: ^[dynamic]Form_Slot,
		fields: ^[dynamic]devui.Form_Field,
		players: []string,
	) {
		info, is_struct := runtime.type_info_base(type).variant.(runtime.Type_Info_Struct)
		if !is_struct do return
		for i in 0 ..< int(info.field_count) {
			name := info.names[i]
			if strings.has_prefix(name, "_") do continue
			field_type, offset := info.types[i], base + int(info.offsets[i])
			label := prefix == "" ? name : fmt.tprintf("%s.%s", prefix, name)
			if field_type.id == sim.Player {
				append(slots, Form_Slot{offset, field_type, true})
				append(fields, devui.Form_Field{label = label, kind = .Choice, choices = players})
				continue
			}
			#partial switch variant in runtime.type_info_base(field_type).variant {
			case runtime.Type_Info_Integer:
				bits := field_type.size * 8
				low := variant.signed ? -f64(i64(1) << uint(bits - 1)) : 0
				high := variant.signed ? f64(i64(1) << uint(bits - 1)) - 1 : f64(u64(1) << uint(bits)) - 1
				append(slots, Form_Slot{offset, field_type, false})
				append(fields, devui.Form_Field {
					label = label,
					kind  = .Number,
					min   = max(low, -1e9),
					max   = min(high, 1e9),
					step  = 1,
				})
			case runtime.Type_Info_Float:
				append(slots, Form_Slot{offset, field_type, false})
				append(fields, devui.Form_Field{label = label, kind = .Number, min = -1e6, max = 1e6, step = 0.01})
			case runtime.Type_Info_Boolean:
				append(slots, Form_Slot{offset, field_type, false})
				append(fields, devui.Form_Field{label = label, kind = .Toggle})
			case runtime.Type_Info_Enum:
				names := make([]string, len(variant.names), context.temp_allocator)
				for member, k in variant.names do names[k] = member
				append(slots, Form_Slot{offset, field_type, false})
				append(fields, devui.Form_Field{label = label, kind = .Choice, choices = names})
			case runtime.Type_Info_Array:
				// a vector or a sim.Position: one number per component (sim units)
				if _, is_float := runtime.type_info_base(variant.elem).variant.(runtime.Type_Info_Float);
				   is_float && variant.count <= 4 {
					axes := [4]string{"x", "y", "z", "w"}
					for k in 0 ..< variant.count {
						append(slots, Form_Slot{offset + k * variant.elem_size, variant.elem, false})
						append(fields, devui.Form_Field {
							label = fmt.tprintf("%s.%s", label, axes[k]),
							kind  = .Number,
							min   = -1e6,
							max   = 1e6,
							step  = 0.01,
						})
					}
				}
			case runtime.Type_Info_Struct:
				form_fields(field_type, offset, label, slots, fields, players)
			}
		}
	}

	// Writes one form input's value into the command's bytes.
	form_write :: proc(out: []u8, slot: Form_Slot, value: f64) {
		if slot.player {
			index := int(value)
			player: sim.Player
			if index >= 0 && index < len(dev_forms.keys) do player = sim.player_of_key(dev_forms.keys[index])
			(^sim.Player)(raw_data(out))^ = player
			return
		}
		#partial switch variant in runtime.type_info_base(slot.type).variant {
		case runtime.Type_Info_Integer:
			bits := u64(i64(value))
			for k in 0 ..< slot.type.size do out[k] = u8(bits >> uint(8 * k))
		case runtime.Type_Info_Float:
			(^f32)(raw_data(out))^ = f32(value)
		case runtime.Type_Info_Boolean:
			out[0] = value != 0 ? 1 : 0
		case runtime.Type_Info_Enum:
			index := int(value)
			member: i64 = index >= 0 && index < len(variant.values) ? i64(variant.values[index]) : 0
			for k in 0 ..< slot.type.size do out[k] = u8(u64(member) >> uint(8 * k))
		}
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
			game:        string,
			version:     string,
			bug:         bool,
			session:     string,
			player:      u64,
			tick:        u32, // the newest predicted tick shown
			verified:    u32,
			recording:   bool, // snapshot.unis and inputs.unil are there
			from_tick:   u32, // the snapshot's tick
			to_tick:     u32, // the log's last
			checkpoints: int, // this machine's checksums of the checksum ticks the log holds (a replay checks them)
			net:         netcode.Client_Stats,
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
			out.from_tick, out.to_tick, out.checkpoints = info.from, info.to, info.checkpoints
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
	_ :: slice
	_ :: strings

	dev_init :: proc(visible: bool, lag: Netsim_Settings, verified_players: bool) {}
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
	dev_draw_toggles :: proc(names: []string) -> u64 {return 0}
	dev_save_recording :: proc(session: ^Session_Node) {}
	_ :: runtime
}
