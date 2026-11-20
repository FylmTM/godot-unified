// The control socket (dev UI builds; src/godot/README.md, The control socket): with `--control <file>` the game
// listens on 127.0.0.1 at a port the OS picks, writes the port to <file>, and answers one request per connection,
// a JSON line `{"op": ..., "args": [...]}`, with one JSON line. `uni drive` is its client. Everything here runs on the
// main thread, polled at the end of the session's _process; a request that waits (a pause, a step, a timed press, a
// wait, a screenshot, a click over three frames) keeps its connection until it is answered or times out.
#+private
package godot

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:time"
import gd "unified:gdext"
import "unified:gdext/gdi"
import "unified:sim"

// The newest event states the socket keeps for `events` and `wait event`.
CONTROL_EVENTS :: 1024
// How long a waiting request waits unless it says (`timeout`, seconds); one for ticks (step, a timed press, `wait
// ticks`) this beyond twice their time at the tick rate.
CONTROL_TIMEOUT :: 10 * time.Second
// A request line longer than this is refused.
CONTROL_REQUEST_MAX :: 64 * 1024
// The controls `ui` lists, and the nodes `find` does, at most.
CONTROL_UI_MAX :: 256

when DEVUI {
	// What a request waits for before it is answered (None: answered at once).
	Control_Wait :: enum u8 {
		None,
		Pause,
		Resume,
		Step,
		Press,
		Wait_Ticks,
		Wait_Event,
		Shot,
		Click,
	}

	// One connection: its request as it arrives, then what it waits for.
	Control_Client :: struct {
		socket:   net.TCP_Socket,
		received: [dynamic]u8,
		wait:     Control_Wait,
		deadline: time.Tick,
		from:     u32, // the shown tick when the request came
		goal:     u32, // Step and a paused Press: step_req's goal; Wait_Ticks and a running Press: the tick to reach
		stepping: bool, // Press: stepped (paused), not waited
		ticks:    u32, // Press, stepped: its ticks, asked the next frame (once the sample holds the press)
		text:     string, // Press: the action; Wait_Event: the event's name; Shot: the file (heap)
		since:    u64, // Wait_Event: an event after this serial
		target:   u64, // Click: the control's instance id
		stage:    int, // Click: 0 motion, 1 press, 2 release, 3 answered
		position: gd.Vector2, // Click: in the window
	}

	// An event state as `events` lists it.
	Control_Event :: struct {
		serial: u64, // 1, 2, ... in the order the session delivered them
		id:     u64, // UnifiedEvent.id: the same in an event's emitted and its confirmed or cancelled
		tick:   u32,
		action: Event_Action,
		kind:   int,
		fields: string, // JSON (heap)
	}

	control: struct {
		open:     bool,
		listener: net.TCP_Socket,
		clients:  [dynamic]Control_Client,
		events:   [CONTROL_EVENTS]Control_Event, // a ring by serial
		serial:   u64, // the newest event's (0: none yet)
		held:     [dynamic]string, // `values`: the input values' assignments held (key=value, heap), in order
	}

	// Listens on 127.0.0.1 at a port the OS picks and writes it to `port_file` (session_ready, `--control`). False,
	// with an error printed, when it can't.
	control_open :: proc(port_file: string) -> bool {
		if control.open do return true
		listener, err := net.listen_tcp({net.IP4_Loopback, 0})
		if err != nil {
			gd.print_error(fmt.tprintf("unified: --control: cannot listen on 127.0.0.1: %v", err))
			return false
		}
		endpoint, info_err := net.bound_endpoint(listener)
		if info_err != nil || net.set_blocking(listener, false) != nil {
			net.close(listener)
			gd.print_error("unified: --control: cannot set the socket up")
			return false
		}
		if write_err := os.write_entire_file(port_file, transmute([]u8)fmt.tprintf("%d\n", endpoint.port));
		   write_err != nil {
			net.close(listener)
			gd.print_error(fmt.tprintf("unified: --control: cannot write %s: %v", port_file, write_err))
			return false
		}
		control.open, control.listener = true, listener
		fmt.printfln("unified: control socket on 127.0.0.1:%d", endpoint.port)
		return true
	}

	// Whether the socket is open: the session thread then copies the state for every frame (want_state).
	control_listening :: proc() -> bool {
		return control.open
	}

	// Closes the socket and every connection (the extension's unload).
	control_close :: proc() {
		if !control.open do return
		for &client in control.clients do control_drop(&client)
		delete(control.clients)
		control.clients = {}
		net.close(control.listener)
		for &event in control.events do delete(event.fields)
		for held in control.held do delete(held)
		delete(control.held)
		control = {}
	}

	// Keeps an event state for `events` (route_event).
	control_event :: proc(tick: u32, id: u64, action: Event_Action, kind: int, layout: ^Event_Layout, data: []u8) {
		if !control.open do return
		control.serial += 1
		slot := &control.events[control.serial % CONTROL_EVENTS]
		delete(slot.fields)
		out := strings.builder_make()
		sim.value_json(&out, layout.type, raw_data(data))
		slot^ = {
			serial = control.serial,
			id     = id,
			tick   = tick,
			action = action,
			kind   = kind,
			fields = strings.to_string(out),
		}
	}

	// Writes the input values `values` holds over what scripts set for local player 0 (session_process: after
	// input_wanted, before the sample), so the sample takes them whatever a script set.
	control_hold_input :: proc() {
		if len(control.held) == 0 do return
		instance := local_input_instance(0)
		if instance == nil || api.input_values.type == nil do return
		for held in control.held do sim.assign_text(raw_data(instance.bytes), api.input_values.type, held)
	}

	// One frame of the socket: new connections, requests that arrived, and the waits that are over.
	control_poll :: proc(session: ^Session_Node) {
		if !control.open do return
		for {
			socket, _, err := net.accept_tcp(control.listener)
			if err != nil do break // Would_Block: nobody new
			net.set_blocking(socket, false)
			append(&control.clients, Control_Client{socket = socket})
		}
		for i := 0; i < len(control.clients); {
			client := &control.clients[i]
			done := false
			if client.wait == .None {
				done = control_receive(session, client)
			} else {
				done = control_waiting(session, client)
			}
			if done {
				control_drop(client)
				ordered_remove(&control.clients, i)
			} else {
				i += 1
			}
		}
	}

	@(private = "file")
	control_drop :: proc(client: ^Control_Client) {
		if client.wait == .Press && client.text != "" do gd.Input_action_release(gd.Input_singleton(), client.text)
		net.close(client.socket)
		delete(client.received)
		delete(client.text)
	}

	// Reads what arrived; once the line is whole, starts its request. True when the connection is done with.
	@(private = "file")
	control_receive :: proc(session: ^Session_Node, client: ^Control_Client) -> bool {
		buffer: [4096]u8
		for {
			count, err := net.recv_tcp(client.socket, buffer[:])
			if err == .Would_Block do return false
			if err != nil || count == 0 do return true // closed before a whole line
			append(&client.received, ..buffer[:count])
			if newline := strings.index_byte(string(client.received[:]), '\n'); newline >= 0 {
				return control_start(session, client, string(client.received[:newline]))
			}
			if len(client.received) > CONTROL_REQUEST_MAX {
				return control_reply(client, control_error("the request is longer than %d bytes", CONTROL_REQUEST_MAX))
			}
		}
	}

	// Sends one JSON line (blocking: a reply is small and the client waits for it). True: the connection is done.
	@(private = "file")
	control_reply :: proc(client: ^Control_Client, reply: string) -> bool {
		net.set_blocking(client.socket, true)
		line := fmt.tprintf("%s\n", reply)
		net.send_tcp(client.socket, transmute([]u8)line)
		return true
	}

	@(private = "file")
	control_error :: proc(format: string, args: ..any) -> string {
		out := strings.builder_make(context.temp_allocator)
		strings.write_string(&out, `{"ok":false,"error":`)
		strings.write_quoted_string(&out, fmt.tprintf(format, ..args))
		strings.write_byte(&out, '}')
		return strings.to_string(out)
	}

	// An ok reply: `{"ok":true,"tick":<shown>,"serial":<newest event>` then `fields` (a JSON object's members, "" or
	// starting with a comma) and `}`.
	@(private = "file")
	control_ok :: proc(session: ^Session_Node, fields: string = "") -> string {
		tick: u32 = session.frame != nil ? session.frame.tick : 0
		return fmt.tprintf(`{{"ok":true,"tick":%d,"serial":%d%s}}`, tick, control.serial, fields)
	}

	@(private = "file")
	quoted :: proc(text: string) -> string {
		out := strings.builder_make(context.temp_allocator)
		strings.write_quoted_string(&out, text)
		return strings.to_string(out)
	}

	// The request's verb, from its JSON line: answers it, or sets up what it waits for. True: answered.
	@(private = "file")
	control_start :: proc(session: ^Session_Node, client: ^Control_Client, line: string) -> bool {
		value, parse_err := json.parse_string(line, allocator = context.temp_allocator)
		request, is_object := value.(json.Object)
		if parse_err != nil || !is_object do return control_reply(client, control_error("not a JSON object: %q", line))
		op, _ := request["op"].(json.String)
		args := make([dynamic]string, context.temp_allocator)
		if list, is_array := request["args"].(json.Array); is_array {
			for arg in list {
				text, is_text := arg.(json.String)
				if !is_text do return control_reply(client, control_error("args are strings"))
				append(&args, text)
			}
		}
		timeout := CONTROL_TIMEOUT
		given := false // a timeout > 0: a wait for ticks then waits that long, not CONTROL_TIMEOUT beyond its ticks
		if seconds, has := request["timeout"].(json.Float); has && seconds > 0 {
			timeout, given = time.Duration(seconds * f64(time.Second)), true
		}
		if seconds, has := request["timeout"].(json.Integer); has && seconds > 0 {
			timeout, given = time.Duration(seconds) * time.Second, true
		}
		client.deadline = time.tick_add(time.tick_now(), timeout)
		// a wait for `ticks` ticks with no timeout given: CONTROL_TIMEOUT beyond twice their time at the tick rate
		for_ticks :: proc(client: ^Control_Client, given: bool, ticks: int) {
			if given do return
			their_time := time.Duration(2 * f64(ticks) / f64(max(api.tick_hz, 1)) * f64(time.Second))
			client.deadline = time.tick_add(time.tick_now(), CONTROL_TIMEOUT + their_time)
		}
		client.from = session.frame != nil ? session.frame.tick : 0
		number :: proc(request: json.Object, key: string, default: f64) -> f64 {
			#partial switch value in request[key] {
			case json.Float:
				return value
			case json.Integer:
				return f64(value)
			}
			return default
		}
		count :: proc(text: string) -> (int, bool) {
			value, ok := strconv.parse_int(text, 10)
			return value, ok && value > 0
		}
		want :: proc(args: []string, low, high: int) -> bool {return len(args) >= low && len(args) <= high}
		reply := ""
		switch op {
		case "status":
			reply = control_ok(session, control_status(session))
		case "pause", "resume":
			if !want(args[:], 0, 0) do break
			if !api.installed || !api.running() do return control_reply(client, control_error("no session is running"))
			if op == "pause" && session.mode != .Single {
				return control_reply(
					client,
					control_error("a pause is single player only (this session is %v)", session.mode),
				)
			}
			sync.atomic_store(&pause_want, op == "pause")
			client.wait = op == "pause" ? .Pause : .Resume
			client.deadline = time.tick_add(time.tick_now(), 2 * time.Second)
			return false
		case "step":
			if !want(args[:], 1, 1) do break
			ticks, ok := count(args[0])
			if !ok do return control_reply(client, control_error("step takes a tick count, got %q", args[0]))
			if !sync.atomic_load(&pause_on) {
				return control_reply(client, control_error("the session is not paused: `pause` first (single player)"))
			}
			client.goal = sync.atomic_add(&step_req, u32(ticks)) + u32(ticks)
			client.wait = .Step
			for_ticks(client, given, ticks)
			return false
		case "press", "release":
			if !want(args[:], 1, op == "press" ? 2 : 1) do break
			action := args[0]
			if !gd.InputMap_has_action(gd.InputMap_singleton(), action) {
				return control_reply(client, control_error("no input action %q (the project's Input Map)", action))
			}
			if op == "release" {
				gd.Input_action_release(gd.Input_singleton(), action)
				reply = control_ok(session)
				break
			}
			strength := number(request, "strength", 1)
			gd.Input_action_press(gd.Input_singleton(), action, f32(strength))
			if len(args) == 1 {
				reply = control_ok(session)
				break
			}
			ticks, ok := count(args[1])
			if !ok {
				gd.Input_action_release(gd.Input_singleton(), action)
				return control_reply(
					client,
					control_error("press takes a tick count after the action, got %q", args[1]),
				)
			}
			client.text = strings.clone(action)
			client.wait = .Press
			for_ticks(client, given, ticks)
			if sync.atomic_load(&pause_on) {
				client.stepping, client.ticks = true, u32(ticks)
			} else {
				client.goal = client.from + u32(ticks)
			}
			return false
		case "command":
			if len(args) < 1 do break
			reply = control_command(session, args[0], strings.join(args[1:], ",", context.temp_allocator))
		case "state":
			if !want(args[:], 0, 1) do break
			state: any
			tick: u32
			if api.installed do state, tick = api.state()
			if state == nil do return control_reply(client, control_error("no state yet: no session has shown a tick"))
			reply = control_value(session, type_info_of(state.id), state.data, len(args) > 0 ? args[0] : "", tick)
		case "data":
			if !want(args[:], 0, 1) do break
			reply = control_data(session, len(args) > 0 ? args[0] : "")
		case "constants":
			if !want(args[:], 0, 1) do break
			if !api.installed || api.constants.type == nil {
				return control_reply(client, control_error("the game has no constants"))
			}
			reply = control_value(
				session,
				api.constants.type,
				raw_data(api.constants_bytes),
				len(args) > 0 ? args[0] : "",
				client.from,
			)
		case "changes":
			if !want(args[:], 0, 0) do break
			reply = control_changes(session)
		case "values":
			reply = control_values(session, args[:])
		case "input":
			if !want(args[:], 0, 1) do break
			inputs := api.installed ? api.inputs() : nil
			if inputs == nil do return control_reply(client, control_error("no input yet: no session has shown a tick"))
			reply = control_value(
				session,
				type_info_of(inputs.id),
				inputs.data,
				len(args) > 0 ? args[0] : "",
				client.from,
			)
		case "events":
			if !want(args[:], 0, 1) do break
			reply = control_events(session, u64(number(request, "since", 0)), len(args) > 0 ? args[0] : "")
		case "wait":
			if !want(args[:], 2, 2) do break
			switch args[0] {
			case "ticks":
				ticks, ok := count(args[1])
				if !ok do return control_reply(client, control_error("wait ticks takes a tick count, got %q", args[1]))
				if sync.atomic_load(&pause_on) {
					return control_reply(client, control_error("the session is paused: `step` it instead"))
				}
				client.goal = client.from + u32(ticks)
				client.wait = .Wait_Ticks
				for_ticks(client, given, ticks)
				return false
			case "event":
				client.text = strings.clone(args[1])
				client.since = u64(number(request, "since", f64(control.serial)))
				client.wait = .Wait_Event
				return control_waiting(session, client) // it may have come already
			}
			return control_reply(client, control_error("wait ticks <n> | wait event <name>"))
		case "shot":
			if !want(args[:], 1, 1) do break
			if gd.DisplayServer_get_name(gd.DisplayServer_singleton()) == "headless" {
				return control_reply(
					client,
					control_error("a headless game has no screen to capture: start it with a window"),
				)
			}
			client.text = strings.clone(args[0])
			client.wait = .Shot // the next frame: what this one draws
			return false
		case "ui":
			if !want(args[:], 0, 0) do break
			reply = control_ui(session)
		case "find":
			if len(args) < 1 do break
			reply = control_find_nodes(session, strings.join(args[:], " ", context.temp_allocator))
		case "click":
			if !want(args[:], 1, 1) do break
			target, problem := control_find(session, args[0])
			if problem != "" do return control_reply(client, control_error("%s", problem))
			client.target = gdi.object_get_instance_id(target.ptr)
			client.position = control_center(target)
			client.wait = .Click
			return control_waiting(session, client)
		case "eval":
			if len(args) < 1 do break
			reply = control_eval(session, strings.join(args[:], " ", context.temp_allocator))
		case "quit":
			if !want(args[:], 0, 0) do break
			control_reply(client, control_ok(session))
			game := gd.Node_get_node_or_null(control_root(session), "/root/Game")
			if game.ptr != nil && gd.Object_has_method(game, "quit_app") {
				gd.Object_call_deferred(game, "quit_app", 0)
			} else {
				quit_when_quiet(session, 0)
			}
			return true
		case:
			return control_reply(client, control_error("no verb %q (uni drive -h)", op))
		}
		if reply == "" do return control_reply(client, control_error("%s: wrong arguments (uni drive -h)", op))
		return control_reply(client, reply)
	}

	// A waiting request, this frame: answered when what it waits for happened, an error at its deadline. True:
	// answered.
	@(private = "file")
	control_waiting :: proc(session: ^Session_Node, client: ^Control_Client) -> bool {
		shown: u32 = session.frame != nil ? session.frame.tick : 0
		late := time.tick_diff(client.deadline, time.tick_now()) > 0
		stepped :: proc(session: ^Session_Node, goal: u32) -> bool {
			if i32(sync.atomic_load(&step_taken) - goal) < 0 do return false
			tick := sync.atomic_load(&step_tick)
			_, state_tick := api.state()
			return state_tick >= tick && session.frame != nil && session.frame.tick >= tick
		}
		switch client.wait {
		case .None:
			return true
		case .Pause, .Resume:
			if sync.atomic_load(&pause_on) == (client.wait == .Pause) do return control_reply(client, control_ok(session, control_status(session)))
			if late {
				sync.atomic_store(&pause_want, false) // a refused pause asks nothing more
				return control_reply(
					client,
					control_error(
						client.wait == .Pause ? "the session did not pause (a pause is single player only)" : "the session did not resume",
					),
				)
			}
		case .Step:
			if stepped(session, client.goal) do return control_reply(client, control_ok(session, fmt.tprintf(`,"from":%d`, client.from)))
			if late || !api.running() do return control_reply(client, control_error("the step did not finish (the session ended?)"))
		case .Press:
			if client.stepping && client.stage == 0 {
				// this frame sampled the press (the sample comes before the socket's poll): its ticks may run now
				client.goal = sync.atomic_add(&step_req, client.ticks) + client.ticks
				client.stage = 1
				return false
			}
			done := client.stepping ? stepped(session, client.goal) : shown >= client.goal
			if done || late || !api.running() {
				gd.Input_action_release(gd.Input_singleton(), client.text)
				delete(client.text)
				client.text = ""
				if !done do return control_reply(client, control_error("the press did not last its ticks (the session ended?)"))
				return control_reply(client, control_ok(session, fmt.tprintf(`,"from":%d`, client.from)))
			}
		case .Wait_Ticks:
			if shown >= client.goal do return control_reply(client, control_ok(session, fmt.tprintf(`,"from":%d`, client.from)))
			if late do return control_reply(client, control_error("timed out at tick %d, waiting for %d", shown, client.goal))
		case .Wait_Event:
			first := control.serial > CONTROL_EVENTS ? control.serial - CONTROL_EVENTS + 1 : 1
			for serial := max(client.since + 1, first); serial <= control.serial; serial += 1 {
				event := &control.events[serial % CONTROL_EVENTS]
				if event.action == .Cancelled || !event_named(event.kind, client.text) do continue
				return control_reply(
					client,
					control_ok(session, fmt.tprintf(`,"event":%s`, control_event_json(event))),
				)
			}
			if late do return control_reply(client, control_error("timed out waiting for the event %q", client.text))
		case .Shot:
			texture := gd.Viewport_get_texture(gd.cast_to(gd.Viewport, control_root(session)))
			defer gd.unref(texture)
			image := gd.Texture2D_get_image(texture)
			defer gd.unref(image)
			if image.ptr == nil || gd.Image_is_empty(image) do return control_reply(client, control_error("the window has no image to capture"))
			if err := gd.Image_save_png(image, client.text); err != .OK {
				return control_reply(client, control_error("cannot write %s: %v", client.text, err))
			}
			return control_reply(
				client,
				control_ok(
					session,
					fmt.tprintf(
						`,"path":%s,"width":%d,"height":%d`,
						quoted(client.text),
						gd.Image_get_width(image),
						gd.Image_get_height(image),
					),
				),
			)
		case .Click:
			if gdi.object_get_instance_from_id(client.target) == nil {
				return control_reply(client, control_error("the control left the tree before the click"))
			}
			control_click_stage(client)
			client.stage += 1
			if client.stage == 3 {
				node := transmute(gd.Node)gdi.object_get_instance_from_id(client.target)
				return control_reply(
					client,
					control_ok(session, fmt.tprintf(`,"path":%s`, quoted(gd.Node_get_path(node)))),
				)
			}
		}
		return false
	}

	// Whether event kind `kind` is called `name`: its lowercased name ("rock_hit") or its type name (Event_Rock_Hit).
	@(private = "file")
	event_named :: proc(kind: int, name: string) -> bool {
		if kind >= len(api.events) do return false
		layout := &api.events[kind]
		return strings.equal_fold(layout.name, name) || strings.equal_fold(fmt.tprintf("event_%s", layout.name), name)
	}

	@(private = "file")
	control_event_json :: proc(event: ^Control_Event) -> string {
		names := [Event_Action]string {
			.Emitted   = "emitted",
			.Confirmed = "confirmed",
			.Cancelled = "cancelled",
		}
		name := event.kind < len(api.events) ? api.events[event.kind].name : "?"
		return fmt.tprintf(
			`{{"serial":%d,"id":%d,"tick":%d,"state":"%s","kind":%s,"fields":%s}}`,
			event.serial,
			event.id,
			event.tick,
			names[event.action],
			quoted(name),
			event.fields,
		)
	}

	// The members `status` adds to its reply.
	@(private = "file")
	control_status :: proc(session: ^Session_Node) -> string {
		out := strings.builder_make(context.temp_allocator)
		running := api.installed && api.running()
		fmt.sbprintf(
			&out,
			`,"game":%s,"running":%v,"mode":"%s","status":"%s","paused":%v`,
			quoted(api.game_name),
			running,
			strings.to_lower(fmt.tprint(session.mode), context.temp_allocator),
			STATUS_NAMES[session.status],
			sync.atomic_load(&pause_on),
		)
		frame := session.frame
		fmt.sbprintf(&out, `,"verified":%d,"tick_hz":%d`, frame != nil ? frame.verified : 0, api.tick_hz)
		level := "null"
		if api.level_enum != nil && session.level.shown.id >= 0 {
			if info, is_enum := runtime.type_info_base(api.level_enum).variant.(runtime.Type_Info_Enum); is_enum {
				for value, k in info.values do if i64(value) == i64(session.level.shown.id) do level = quoted(info.names[k])
			}
		}
		fmt.sbprintf(&out, `,"level":%s,"players":[`, level)
		if frame != nil {
			first := true
			for key, slot in frame.slots {
				if key == 0 do continue
				if !first do strings.write_byte(&out, ',')
				first = false
				fmt.sbprintf(
					&out,
					`{{"key":%d,"slot":%d,"name":%s}}`,
					key,
					slot,
					quoted(player_name(session, i64(key))),
				)
			}
		}
		strings.write_string(&out, `],"local_players":[`)
		if frame != nil {
			first := true
			for key in frame.local_players {
				if key == 0 do continue
				if !first do strings.write_byte(&out, ',')
				first = false
				fmt.sbprintf(&out, "%d", key)
			}
		}
		strings.write_byte(&out, ']')
		scene := gd.SceneTree_get_current_scene(gd.Node_get_tree(node_of(session)))
		fmt.sbprintf(&out, `,"scene":%s`, scene.ptr != nil ? quoted(gd.Node_get_name(scene)) : "null")
		return strings.to_string(out)
	}

	// A value (or the part `path` names) as `{"ok":true,...,"tick":<its tick>,"value":<json>}`.
	@(private = "file")
	control_value :: proc(
		session: ^Session_Node,
		type: ^runtime.Type_Info,
		data: rawptr,
		path: string,
		tick: u32,
	) -> string {
		out := strings.builder_make(context.temp_allocator)
		if problem := sim.value_json_at(&out, type, data, path); problem != "" do return control_error("%s", problem)
		return fmt.tprintf(
			`{{"ok":true,"tick":%d,"serial":%d,"value":%s}}`,
			tick,
			control.serial,
			strings.to_string(out),
		)
	}

	// The session data (Glue.data) as `value`: every type by its property name, or the one `name` (or a path in it:
	// `hud.score`) names.
	@(private = "file")
	control_data :: proc(session: ^Session_Node, path: string) -> string {
		out := strings.builder_make(context.temp_allocator)
		name, rest := path, ""
		if dot := strings.index_any(path, ".["); dot >= 0 do name, rest = path[:dot], strings.trim_prefix(path[dot:], ".")
		strings.write_byte(&out, '{')
		found, first := false, true
		for data_class in D.data {
			if data_class == nil || data_class.instance == nil do continue
			property := data_class.layout.property
			if name != "" {
				if property != name do continue
				found = true
				if problem := sim.value_json_at(
					&out,
					data_class.layout.type,
					raw_data(data_class.instance.bytes),
					rest,
				); problem != "" {
					return control_error("%s", problem)
				}
				return fmt.tprintf(
					`{{"ok":true,"tick":%d,"serial":%d,"value":%s}}`,
					session.frame != nil ? session.frame.tick : 0,
					control.serial,
					strings.to_string(out)[1:],
				)
			}
			if !first do strings.write_byte(&out, ',')
			first = false
			fmt.sbprintf(&out, `%s:`, quoted(property))
			sim.value_json(&out, data_class.layout.type, raw_data(data_class.instance.bytes))
		}
		if name != "" && !found do return control_error("no session data %q", name)
		strings.write_byte(&out, '}')
		return control_ok(session, fmt.tprintf(`,"value":%s`, strings.to_string(out)))
	}

	@(private = "file")
	control_changes :: proc(session: ^Session_Node) -> string {
		if !api.installed do return control_error("no game")
		lines, total, tick, before := api.changes(256)
		out := strings.builder_make(context.temp_allocator)
		fmt.sbprintf(&out, `,"changed_tick":%d,"before":%d,"total":%d,"lines":[`, tick, before, total)
		for line, i in lines {
			if i > 0 do strings.write_byte(&out, ',')
			strings.write_string(&out, quoted(line))
		}
		strings.write_byte(&out, ']')
		return control_ok(session, strings.to_string(out))
	}

	// The kept event states after serial `since`, of kind `name` when given.
	@(private = "file")
	control_events :: proc(session: ^Session_Node, since: u64, name: string) -> string {
		out := strings.builder_make(context.temp_allocator)
		first_kept := control.serial > CONTROL_EVENTS ? control.serial - CONTROL_EVENTS + 1 : 1
		fmt.sbprintf(&out, `,"dropped":%v,"events":[`, since + 1 < first_kept && control.serial > 0)
		first := true
		for serial := max(since + 1, first_kept); serial <= control.serial; serial += 1 {
			event := &control.events[serial % CONTROL_EVENTS]
			if name != "" && !event_named(event.kind, name) do continue
			if !first do strings.write_byte(&out, ',')
			first = false
			strings.write_string(&out, control_event_json(event))
		}
		strings.write_byte(&out, ']')
		return control_ok(session, strings.to_string(out))
	}

	// A command of the game's union from its name (`drop`, `Cmd_Drop`) and `key=value,...`, sent as local player 0's
	// like a script's send_command (sim units: what the state reads; a player field by its key).
	@(private = "file")
	control_command :: proc(session: ^Session_Node, name: string, text: string) -> string {
		if !api.installed || !api.running() do return control_error("no session is running")
		names := make([dynamic]string, context.temp_allocator)
		for &layout, kind in api.commands {
			append(&names, layout.name)
			if !strings.equal_fold(layout.name, name) &&
			   !strings.equal_fold(fmt.tprintf("cmd_%s", layout.name), name) {
				continue
			}
			bytes: [sim.COMMAND_MAX]u8
			if problem := sim.assign_text(&bytes, layout.type, text); problem != "" do return control_error("%s", problem)
			command, ok := sim.command_from_bytes(api.commands_type, kind, bytes[:layout.type.size])
			if !ok do return control_error("%s does not encode", name)
			tick, player: u64
			if session.frame != nil do tick, player = u64(session.frame.tick), session.frame.local_player
			if !api.send(command, 0) {
				dev_command(u32(tick), .Refused, player, &command)
				return control_error("too many commands are waiting for the session")
			}
			dev_command(u32(tick), .Sent, player, &command)
			return control_ok(session)
		}
		return control_error(
			"no command %q (the game's: %s)",
			name,
			strings.join(names[:], ", ", context.temp_allocator),
		)
	}

	// `values`: with no arguments, local player 0's input values now and what is held; `clear` lets go of what is held;
	// key=value assignments (sim.assign_text's) are held from this frame on (one replaces any held whose path is it or
	// lies within it, or holds it: `aim` and `aim[0]`), written over what scripts set every frame until `values clear`
	// (control_hold_input).
	@(private = "file")
	control_values :: proc(session: ^Session_Node, args: []string) -> string {
		if api.input_values.type == nil do return control_error("the game has no input values (Glue.input_values)")
		instance := local_input_instance(0)
		if instance == nil do return control_error("no local player yet: its input values exist once the session's classes do")
		if len(args) == 1 && args[0] == "clear" {
			for held in control.held do delete(held)
			clear(&control.held)
		} else if len(args) > 0 {
			scratch := make([]u8, len(instance.bytes), context.temp_allocator)
			copy(scratch, instance.bytes)
			for arg in args {
				if strings.count(arg, "=") != 1 || strings.contains_rune(arg, ',') {
					return control_error("%q: one key=value per argument", arg)
				}
				if problem := sim.assign_text(raw_data(scratch), api.input_values.type, arg); problem != "" {
					return control_error("%s", problem)
				}
			}
			// a path within another (`aim` and `aim[0]`, `area` and `area.layer`): one place written twice
			overlap :: proc(a, b: string) -> bool {
				within :: proc(path, outer: string) -> bool {
					if !strings.has_prefix(path, outer) do return false
					return len(path) == len(outer) || path[len(outer)] == '.' || path[len(outer)] == '['
				}
				return within(a, b) || within(b, a)
			}
			for arg in args {
				key := strings.trim_space(arg[:strings.index_byte(arg, '=')])
				for i := len(control.held) - 1; i >= 0; i -= 1 {
					held := control.held[i]
					if overlap(strings.trim_space(held[:strings.index_byte(held, '=')]), key) {
						delete(held)
						ordered_remove(&control.held, i)
					}
				}
				append(&control.held, strings.clone(strings.trim_space(arg)))
			}
			control_hold_input()
		}
		out := strings.builder_make(context.temp_allocator)
		strings.write_string(&out, `,"held":[`)
		for held, i in control.held {
			if i > 0 do strings.write_byte(&out, ',')
			strings.write_quoted_string(&out, held)
		}
		strings.write_string(&out, `],"value":`)
		sim.value_json(&out, api.input_values.type, raw_data(instance.bytes))
		return control_ok(session, strings.to_string(out))
	}

	@(private = "file")
	control_root :: proc(session: ^Session_Node) -> gd.Node {
		return gd.cast_to(gd.Node, gd.SceneTree_get_root(gd.Node_get_tree(node_of(session))))
	}

	// The visible controls with a text or a press (buttons), in tree order, the dev UI's left out.
	@(private = "file")
	control_ui :: proc(session: ^Session_Node) -> string {
		out := strings.builder_make(context.temp_allocator)
		strings.write_string(&out, `,"controls":[`)
		listed := 0
		walk :: proc(node: gd.Node, out: ^strings.Builder, listed: ^int) {
			if listed^ >= CONTROL_UI_MAX do return
			if gd.Node_get_name(node) == "DevUI" do return
			control := gd.object_cast(gd.Control, node)
			if control.ptr != nil {
				if !gd.CanvasItem_is_visible_in_tree(control) do return // nor its children
				entry, ok := control_entry(control)
				if ok {
					if listed^ > 0 do strings.write_byte(out, ',')
					strings.write_string(out, entry)
					listed^ += 1
				}
			}
			for i in 0 ..< gd.Node_get_child_count(node, false) do walk(gd.Node_get_child(node, i, false), out, listed)
		}
		walk(control_root(session), &out, &listed)
		fmt.sbprintf(&out, `],"more":%v`, listed >= CONTROL_UI_MAX)
		return control_ok(session, strings.to_string(out))
	}

	// A control as `ui` lists it: one with a text property that holds text, or a button (with its text, maybe "").
	@(private = "file")
	control_entry :: proc(control: gd.Control) -> (string, bool) {
		button := gd.Object_is_class(control, "BaseButton")
		text_value := gd.Object_get(control, "text")
		defer gd.variant_destroy(&text_value)
		text, has_text := gd.from_variant(string, &text_value)
		if !button && (!has_text || text == "") do return "", false
		rect := gd.Control_get_global_rect(control)
		out := strings.builder_make(context.temp_allocator)
		fmt.sbprintf(
			&out,
			`{{"path":%s,"class":%s,"text":%s`,
			quoted(gd.Node_get_path(control)),
			quoted(gd.Object_get_class(control)),
			quoted(text),
		)
		if button {
			disabled := gd.Object_get(control, "disabled")
			defer gd.variant_destroy(&disabled)
			value, _ := gd.from_variant(bool, &disabled)
			fmt.sbprintf(&out, `,"disabled":%v`, value)
		}
		fmt.sbprintf(
			&out,
			`,"rect":[%.0f,%.0f,%.0f,%.0f]}}`,
			rect.position.x,
			rect.position.y,
			rect.size.x,
			rect.size.y,
		)
		return strings.to_string(out), true
	}

	// Every node, hidden ones too, whose name, class (its own, one it extends, or its script's class_name) or text holds
	// `query` (any case; a class it extends by its exact name), in tree order, the dev UI's left out: its path, name,
	// class, script class, text, whether it is visible, and a control's rect. What an agent looks a node path up with.
	@(private = "file")
	control_find_nodes :: proc(session: ^Session_Node, query: string) -> string {
		Search :: struct {
			query: string, // lowercased
			exact: string, // as typed: a class the node extends (Object.is_class)
			out:   strings.Builder,
			found: int,
		}
		search := Search {
			query = strings.to_lower(query, context.temp_allocator),
			exact = query,
			out   = strings.builder_make(context.temp_allocator),
		}
		strings.write_string(&search.out, `,"nodes":[`)
		walk :: proc(node: gd.Node, search: ^Search) {
			if search.found >= CONTROL_UI_MAX do return
			name := gd.Node_get_name(node)
			if name == "DevUI" do return
			class := gd.Object_get_class(node)
			script_class := ""
			script_variant := gd.Object_get_script(node)
			defer gd.variant_destroy(&script_variant)
			if script, _ := gd.from_variant(gd.Object, &script_variant); script.ptr != nil {
				global := gd.Object_call(script, "get_global_name")
				defer gd.variant_destroy(&global)
				script_class = variant_text(&global)
			}
			text_value := gd.Object_get(node, "text")
			defer gd.variant_destroy(&text_value)
			text, _ := gd.from_variant(string, &text_value)
			holds :: proc(value, query: string) -> bool {
				return value != "" && strings.contains(strings.to_lower(value, context.temp_allocator), query)
			}
			if holds(name, search.query) ||
			   holds(class, search.query) ||
			   holds(script_class, search.query) ||
			   holds(text, search.query) ||
			   gd.Object_is_class(node, search.exact) {
				if search.found > 0 do strings.write_byte(&search.out, ',')
				search.found += 1
				fmt.sbprintf(
					&search.out,
					`{{"path":%s,"name":%s,"class":%s,"script_class":%s,"text":%s`,
					quoted(gd.Node_get_path(node)),
					quoted(name),
					quoted(class),
					quoted(script_class),
					quoted(text),
				)
				if item := gd.object_cast(gd.CanvasItem, node); item.ptr != nil {
					fmt.sbprintf(&search.out, `,"visible":%v`, gd.CanvasItem_is_visible_in_tree(item))
				} else if spatial := gd.object_cast(gd.Node3D, node); spatial.ptr != nil {
					fmt.sbprintf(&search.out, `,"visible":%v`, gd.Node3D_is_visible_in_tree(spatial))
				}
				if control := gd.object_cast(gd.Control, node); control.ptr != nil {
					rect := gd.Control_get_global_rect(control)
					fmt.sbprintf(
						&search.out,
						`,"rect":[%.0f,%.0f,%.0f,%.0f]`,
						rect.position.x,
						rect.position.y,
						rect.size.x,
						rect.size.y,
					)
				}
				strings.write_byte(&search.out, '}')
			}
			for i in 0 ..< gd.Node_get_child_count(node, false) do walk(gd.Node_get_child(node, i, false), search)
		}
		walk(control_root(session), &search)
		fmt.sbprintf(&search.out, `],"more":%v`, search.found >= CONTROL_UI_MAX)
		return control_ok(session, strings.to_string(search.out))
	}

	// The control `target` names: a node path (`/root/Main/Hud/Start`, or `root/Main/Hud/Start`: Git Bash rewrites an
	// argument starting with / into a Windows path), else the first visible button whose text is `target` (any case),
	// else the first visible control with that text.
	@(private = "file")
	control_find :: proc(session: ^Session_Node, path_or_text: string) -> (found: gd.Control, problem: string) {
		root := control_root(session)
		target := path_or_text
		if target == "root" || strings.has_prefix(target, "root/") {
			target = fmt.tprintf("/%s", target)
		}
		if strings.has_prefix(target, "/") {
			node := gd.Node_get_node_or_null(root, target)
			found = gd.object_cast(gd.Control, node)
			if found.ptr == nil do return {}, fmt.tprintf("no control at %s", target)
			if !gd.CanvasItem_is_visible_in_tree(found) do return {}, fmt.tprintf("%s is hidden", target)
			return found, ""
		}
		search :: proc(node: gd.Node, target: string, buttons_only: bool) -> gd.Control {
			if gd.Node_get_name(node) == "DevUI" do return {}
			control := gd.object_cast(gd.Control, node)
			if control.ptr != nil {
				if !gd.CanvasItem_is_visible_in_tree(control) do return {}
				if !buttons_only || gd.Object_is_class(control, "BaseButton") {
					text_value := gd.Object_get(control, "text")
					defer gd.variant_destroy(&text_value)
					if text, ok := gd.from_variant(string, &text_value); ok && strings.equal_fold(text, target) do return control
				}
			}
			for i in 0 ..< gd.Node_get_child_count(node, false) {
				if hit := search(gd.Node_get_child(node, i, false), target, buttons_only); hit.ptr != nil do return hit
			}
			return {}
		}
		if found = search(root, target, true); found.ptr == nil do found = search(root, target, false)
		if found.ptr == nil do return {}, fmt.tprintf("no visible control with the text %q (`uni drive ui` lists them)", target)
		return found, ""
	}

	// The control's centre in window coordinates, where a click lands.
	@(private = "file")
	control_center :: proc(control: gd.Control) -> gd.Vector2 {
		apply :: proc(xf: gd.Transform2D, p: gd.Vector2) -> gd.Vector2 {
			return {xf.x.x * p.x + xf.y.x * p.y + xf.origin.x, xf.x.y * p.x + xf.y.y * p.y + xf.origin.y}
		}
		size := gd.Control_get_size(control)
		in_canvas := apply(gd.CanvasItem_get_global_transform_with_canvas(control), {size.x / 2, size.y / 2})
		return apply(gd.Viewport_get_final_transform(gd.Node_get_viewport(control)), in_canvas)
	}

	// One frame of a click, as a player's mouse: the motion onto the control, the press, the release.
	@(private = "file")
	control_click_stage :: proc(client: ^Control_Client) {
		input := gd.Input_singleton()
		if client.stage == 0 {
			gd.Input_warp_mouse(input, client.position) // a window: the real cursor sits on the control
			motion := gd.InputEventMouseMotion_new()
			defer gd.unref(motion)
			gd.InputEventMouse_set_position(motion, client.position)
			gd.InputEventMouse_set_global_position(motion, client.position)
			gd.Input_parse_input_event(input, motion)
			return
		}
		if client.stage > 2 do return
		button := gd.InputEventMouseButton_new()
		defer gd.unref(button)
		gd.InputEventMouseButton_set_button_index(button, .MOUSE_BUTTON_LEFT)
		gd.InputEventMouseButton_set_pressed(button, client.stage == 1)
		gd.InputEventMouse_set_position(button, client.position)
		gd.InputEventMouse_set_global_position(button, client.position)
		gd.Input_parse_input_event(input, button)
	}

	// A GDScript expression (Godot's Expression) on the current scene, with `session`, `tree`, `root`, `scene`,
	// `Input` and `Engine` named (Engine.get_singleton("Unified"): any other singleton); its value as JSON (Godot's
	// JSON.stringify: a Vector3 is a string).
	@(private = "file")
	control_eval :: proc(session: ^Session_Node, text: string) -> string {
		tree := gd.Node_get_tree(node_of(session))
		root := control_root(session)
		scene := gd.SceneTree_get_current_scene(tree)
		names := gd.PackedStringArray_new0()
		defer gd.PackedStringArray_destroy(&names)
		for name in ([]string{"session", "tree", "root", "scene", "Input", "Engine"}) do gd.PackedStringArray_append(&names, name)
		expression := gd.Expression_new()
		defer gd.unref(expression)
		if err := gd.Expression_parse(expression, text, names); err != .OK {
			return control_error("%s", gd.Expression_get_error_text(expression))
		}
		inputs := gd.array_new()
		defer gd.Array_destroy(&inputs)
		gd.array_push(&inputs, gd.Object{session.obj.ptr})
		gd.array_push(&inputs, gd.Object{tree.ptr})
		gd.array_push(&inputs, gd.Object{root.ptr})
		gd.array_push(&inputs, gd.Object{scene.ptr})
		gd.array_push(&inputs, gd.Object{gd.Input_singleton().ptr})
		gd.array_push(&inputs, gd.Object{gd.Engine_singleton().ptr})
		base := scene.ptr != nil ? gd.Object{scene.ptr} : gd.Object{root.ptr}
		result := gd.Expression_execute(expression, inputs, base, false)
		defer gd.variant_destroy(&result)
		if gd.Expression_has_execute_failed(expression) {
			return control_error("%s", gd.Expression_get_error_text(expression))
		}
		return control_ok(session, fmt.tprintf(`,"value":%s`, gd.JSON_stringify(result)))
	}
} else {
	_ :: runtime
	_ :: fmt
	_ :: strings
	_ :: gd
	_ :: json
	_ :: net
	_ :: os
	_ :: strconv
	_ :: sync
	_ :: time
	_ :: gdi
	_ :: sim

	control_open :: proc(port_file: string) -> bool {return false}
	control_listening :: proc() -> bool {return false}
	control_close :: proc() {}
	control_event :: proc(tick: u32, id: u64, action: Event_Action, kind: int, layout: ^Event_Layout, data: []u8) {}
	control_poll :: proc(session: ^Session_Node) {}
	control_hold_input :: proc() {}
}
