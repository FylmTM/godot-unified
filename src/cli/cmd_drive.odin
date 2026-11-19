// `uni drive`: an agent drives a running game through its control socket (src/godot/README.md, The control socket).
// `start` launches the game with `--control` as a named instance, every other verb is one request to it, and `stop`
// quits it and judges its log. An instance's record is games/<game>/.out/drive/<name>.json.
package cli

import "core:encoding/json"
import "core:fmt"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

// How long `start` waits for the game to answer (a cold shader cache, the first import).
DRIVE_START_TIMEOUT :: 90 * time.Second
// How long `stop` waits for the game to quit before it kills it.
DRIVE_STOP_TIMEOUT :: 20 * time.Second

@(private)
Drive_Opts :: struct {
	name:     string `usage:"the instance (start: default the first free number; any other verb: default the only one running)"`,
	headless: bool `usage:"start: no window (shot then fails); default: a window, muted, on the leftmost screen, never taking focus"`,
	strength: f64 `usage:"press: the action's strength (default 1)"`,
	timeout:  f64 `usage:"seconds a waiting verb (pause, step, press for ticks, wait, shot, click) waits (default 10)"`,
	all:      bool `usage:"events: every event state kept, not only those since the last events"`,
	overflow: [dynamic]string `hint:"[game] <verb> [args] [-- game args]" usage:"the game (default: the only one, or the only one with an instance), the verb and its arguments (below); start: the game's own arguments after --"`,
}

// A running instance as `start` recorded it.
@(private)
Drive_Instance :: struct {
	name:        string,
	pid:         int,
	port:        int,
	headless:    bool,
	log:         string,
	events_seen: u64, // the newest event serial `events` returned
	serial_seen: u64, // the newest event serial any reply named: `wait event` waits for one after it
	shots:       int,
}

// `drive -h`'s details: the verbs.
@(private)
drive_details :: proc() -> string {
	return(
		"Verbs (each prints the game's JSON reply; ok false exits 1):\n" +
		"  start [-- game args]     launch the game with its control socket (--headless: no window); prints its status\n" +
		"  stop                     quit it through the game, wait, and judge its log (errors, leaks: exit 1)\n" +
		"  list                     the instances of the game and whether each runs\n" +
		"  status                   mode, tick, verified tick, paused, level, players, local players, scene\n" +
		"  pause | resume           stop or restart a single-player session's clock (exact: nothing moves while paused)\n" +
		"  step <n>                 a paused session steps exactly n ticks, sampling the input held now (it acts after the input delay)\n" +
		"  press <action> [n]       hold an Input Map action (--strength); with n: for n ticks, then release (paused: steps them)\n" +
		"  release <action>         let go of it\n" +
		"  command <name> [k=v ..]  send one of the game's commands (any, Cmd_Dev_* too) as local player 0 (sim units; a player by its key)\n" +
		"  state [path]             the newest predicted State as JSON (tables: live items by index), or the part a path names: players.slots[0]\n" +
		"  data [name[.path]]       the session data; constants [path]; input [path]: the local input sampled for the newest tick\n" +
		"  changes                  what the newest tick changed against the one before (the op log)\n" +
		"  events [name]            event states since the last `events` (--all: every one kept)\n" +
		"  wait ticks <n>           until the shown tick moved n ticks (running sessions)\n" +
		"  wait event <name>        until an event of that kind arrives after the previous reply\n" +
		"  shot [file.png]          the window as a PNG (default .out/drive/<name>-<n>.png in the game)\n" +
		"  ui                       the visible buttons and texts (path, class, text, disabled, rect)\n" +
		"  click <text|path>        a real mouse click on a button by its text, or any control by its node path\n" +
		"  eval <expression>        a GDScript expression on the current scene (session, tree, root, scene, Input, Engine): its value\n" +
		"Input goes through the game's own sampling and commands through the session's queue, so a driven session\n" +
		"is a session like any other: deterministic, recorded, replayable. A paused session steps exactly; a running\n" +
		"one moves on its own clock between verbs." \
	)
}

@(private)
cmd_drive :: proc(args: []string) -> Result {
	opts: Drive_Opts
	split := len(args)
	for arg, i in args {
		if arg == "--" {
			split = i
			break
		}
	}
	parse(&opts, args[:split])
	game_args := split < len(args) ? args[split + 1:] : nil
	words := opts.overflow[:]
	selected: Game
	found := false
	if len(words) > 0 {
		for candidate in state.project.games {
			if candidate.name == words[0] {
				selected, found, words = candidate, true, words[1:]
				break
			}
		}
	}
	if !found {
		running: [dynamic]Game
		for candidate in state.project.games {
			if len(drive_instances(candidate)) > 0 do append(&running, candidate)
		}
		selected = len(running) == 1 && (len(words) == 0 || words[0] != "start") ? running[0] : game("")
	}
	if len(words) == 0 do usage("name a verb (uni drive -h)")
	verb, verb_args := words[0], words[1:]
	if game_args != nil && verb != "start" do usage("only start takes the game's arguments after --")
	switch verb {
	case "start":
		if len(verb_args) > 0 do usage("start takes no arguments (the game's go after --)")
		return drive_start(selected, opts, game_args)
	case "stop":
		return drive_stop(selected, drive_instance(selected, opts.name))
	case "list":
		out := strings.builder_make()
		strings.write_string(&out, `{"ok":true,"instances":[`)
		for instance, i in drive_instances(selected) {
			if i > 0 do strings.write_byte(&out, ',')
			fmt.sbprintf(
				&out,
				`{{"name":%q,"pid":%d,"port":%d,"running":%v}}`,
				instance.name,
				instance.pid,
				instance.port,
				process_alive(instance.pid),
			)
		}
		strings.write_string(&out, "]}")
		return {ok = true, summary = strings.to_string(out)}
	}
	instance := drive_instance(selected, opts.name)
	request := Drive_Request {
		op       = verb,
		args     = verb_args,
		timeout  = opts.timeout > 0 ? opts.timeout : 10,
		strength = opts.strength > 0 ? opts.strength : 1,
	}
	switch verb {
	case "events":
		request.since = opts.all ? 0 : instance.events_seen
	case "wait":
		request.since = instance.serial_seen
	case "shot":
		if len(verb_args) == 0 {
			instance.shots += 1
			request.args = strs(join(drive_dir(selected), aprintf("%s-%d.png", instance.name, instance.shots)))
		} else if len(verb_args) == 1 {
			path, _ := os.get_absolute_path(verb_args[0], context.allocator)
			request.args = strs(path)
		}
	}
	reply, ok := drive_request(instance.port, request)
	if !ok {
		if process_alive(instance.pid) do return drive_failed("instance %s did not answer: %s", instance.name, reply)
		return drive_failed("instance %s is not running (uni drive %s stop clears it)", instance.name, selected.name)
	}
	value, _ := json.parse_string(reply, parse_integers = true)
	object, _ := value.(json.Object)
	if serial, has := object["serial"].(json.Integer); has {
		instance.serial_seen = u64(serial)
		if verb == "events" do instance.events_seen = u64(serial)
	}
	drive_save(selected, instance)
	replied_ok, _ := object["ok"].(json.Boolean)
	return {ok = bool(replied_ok), summary = reply, data = box(value)}
}

// A request on the control socket (control.odin reads it).
@(private)
Drive_Request :: struct {
	op:       string,
	args:     []string,
	timeout:  f64,
	strength: f64,
	since:    u64,
}

// Sends one request and reads its reply line; false (with why) when the game can't be reached or says nothing.
@(private)
drive_request :: proc(port: int, request: Drive_Request) -> (reply: string, ok: bool) {
	line, err := json.marshal(request)
	if err != nil do return "cannot encode the request", false
	socket, dial_err := net.dial_tcp(net.Endpoint{net.IP4_Loopback, port})
	if dial_err != nil do return aprintf("%v", dial_err), false
	defer net.close(socket)
	net.set_option(socket, .Receive_Timeout, time.Duration((request.timeout + 10) * f64(time.Second)))
	append_line := make([dynamic]u8)
	append(&append_line, ..line)
	append(&append_line, '\n')
	if _, send_err := net.send_tcp(socket, append_line[:]); send_err != nil do return aprintf("%v", send_err), false
	received: [dynamic]u8
	buffer: [16 * 1024]u8
	for {
		count, recv_err := net.recv_tcp(socket, buffer[:])
		if recv_err != nil do return aprintf("%v", recv_err), false
		if count == 0 do break
		append(&received, ..buffer[:count])
		if strings.contains_rune(string(received[:]), '\n') do break
	}
	text := strings.trim_space(string(received[:]))
	if text == "" do return "no reply", false
	return text, true
}

@(private)
drive_dir :: proc(game: Game) -> string {
	return join(game.dir, ".out", "drive")
}

// The game's instance records, by name.
@(private)
drive_instances :: proc(game: Game) -> []Drive_Instance {
	out: [dynamic]Drive_Instance
	entries, _ := os.read_all_directory_by_path(drive_dir(game), context.allocator)
	for entry in entries {
		if !strings.has_suffix(entry.name, ".json") do continue
		text, ok := read_text(entry.fullpath)
		instance: Drive_Instance
		if ok && json.unmarshal_string(text, &instance) == nil do append(&out, instance)
	}
	return out[:]
}

// The instance `name` names, or the only one there is (a usage error otherwise).
@(private)
drive_instance :: proc(game: Game, name: string) -> Drive_Instance {
	instances := drive_instances(game)
	names: [dynamic]string
	for instance in instances {
		if instance.name == name do return instance
		append(&names, instance.name)
	}
	if name != "" do usage("%s has no instance %q (running: %s)", game.name, name, strings.join(names[:], ", "))
	switch len(instances) {
	case 0:
		usage("%s has no running instance: uni drive %s start", game.name, game.name)
	case 1:
		return instances[0]
	}
	usage("%s has several instances: name one with --name (%s)", game.name, strings.join(names[:], ", "))
}

@(private)
drive_save :: proc(game: Game, instance: Drive_Instance) {
	text, err := json.marshal(instance, {pretty = true})
	if err != nil do fatal("cannot encode the instance record: %v", err)
	write_text(join(drive_dir(game), aprintf("%s.json", instance.name)), string(text))
}

@(private)
drive_forget :: proc(game: Game, name: string) {
	os.remove(join(drive_dir(game), aprintf("%s.json", name)))
	os.remove(join(drive_dir(game), aprintf("%s.port", name)))
}

// Whether a process with this pid runs.
@(private)
process_alive :: proc(pid: int) -> bool {
	if pid <= 0 do return false
	process, err := os.process_open(pid)
	if err != nil do return false
	state, wait_err := os.process_wait(process, 0)
	if wait_err == .Timeout do return true // still running: its handle stays open until the CLI exits
	return wait_err == nil && !state.exited
}

// Launches the game with its control socket (a window as AGENT_WINDOW places it, or headless) and waits until it
// answers; its output goes to .out/drive/<name>.log.
@(private)
drive_start :: proc(game: Game, opts: Drive_Opts, game_args: []string) -> Result {
	if !has_extension(game) do usage("%s has no extension to drive", game.name)
	name := opts.name
	taken := drive_instances(game)
	for instance in taken {
		if !process_alive(instance.pid) {
			drive_forget(game, instance.name) // a crashed or killed one
		} else if instance.name == name {
			usage("%s's instance %s is running (uni drive %s --name %s stop)", game.name, name, game.name, name)
		}
	}
	if name == "" {
		for n := 1;; n += 1 {
			name = aprintf("%d", n)
			if !os.exists(join(drive_dir(game), aprintf("%s.json", name))) do break
		}
	}
	ensure_game(game)
	dir := drive_dir(game)
	make_dirs(dir)
	port_file := join(dir, aprintf("%s.port", name))
	os.remove(port_file)
	log_path := join(dir, aprintf("%s.log", name))
	cmd: [dynamic]string
	append(&cmd, godot())
	if opts.headless {
		append(&cmd, "--headless")
	} else {
		append(&cmd, "--resolution", "1280x720")
		append(&cmd, ..window_args(AGENT_WINDOW))
	}
	append(&cmd, "--path", game.dir, "--", "--no-settings", "--local-net", "--control", port_file)
	append(&cmd, ..game_args)
	cleanup := opts.headless ? no_cleanup : with_window(game.dir, AGENT_WINDOW)
	defer cleanup(game.dir) // the window exists by then: Godot read the override at its start
	log_file, log_err := os.open(log_path, {.Write, .Create, .Trunc})
	if log_err != nil do fatal("cannot create %s", log_path)
	stdin := debugger_quit_stdin()
	if state.verbose do log("+ %s", strings.join(cmd[:], " "))
	// the game outlives this command: it must not hold our stdout open (a caller reading it to its end would wait
	// for the game), so our stdio are not inherited while it starts
	for file in ([]^os.File{os.stdin, os.stdout, os.stderr}) do set_inheritable(file, false)
	process, err := spawn({command = cmd[:], stdin = stdin, stdout = log_file, stderr = log_file}, stdin, log_file)
	for file in ([]^os.File{os.stdin, os.stdout, os.stderr}) do set_inheritable(file, true)
	os.close(log_file)
	if stdin != nil do os.close(stdin)
	if err != nil do fatal("cannot start Godot: %v", err)
	instance := Drive_Instance {
		name     = name,
		pid      = process.pid,
		headless = opts.headless,
		log      = log_path,
	}
	deadline := time.tick_add(time.tick_now(), DRIVE_START_TIMEOUT)
	for {
		if text, ok := read_text(port_file); ok {
			if port, parsed := strconv.parse_int(strings.trim_space(text)); parsed && port > 0 {
				instance.port = port
				break
			}
		}
		if _, wait_err := os.process_wait(process, 0); wait_err != .Timeout {
			text, _ := read_text(log_path)
			log("%s", tail(text, 4000))
			return drive_failed("%s quit before it opened its control socket (its log: %s)", game.name, log_path)
		}
		if time.tick_diff(deadline, time.tick_now()) > 0 {
			kill_tree(process)
			return drive_failed(
				"%s opened no control socket within %.0fs",
				game.name,
				time.duration_seconds(DRIVE_START_TIMEOUT),
			)
		}
		time.sleep(50 * time.Millisecond)
	}
	drive_save(game, instance)
	reply, ok := drive_request(instance.port, {op = "status", timeout = 10})
	if !ok do return drive_failed("the control socket does not answer: %s", reply)
	// the reply with the instance's name and log in front
	summary := aprintf(`{{"name":%q,"log":%q,%s`, name, log_path, strings.trim_prefix(reply, "{"))
	return {ok = true, summary = summary}
}

// Quits the instance through the game (its own quit: sounds stopped, a clean exit), waits for it (killing it past
// DRIVE_STOP_TIMEOUT) and judges its log as a tool run's: an error line, a leak at exit or a GDScript warning fails.
@(private)
drive_stop :: proc(game: Game, instance: Drive_Instance) -> Result {
	defer drive_forget(game, instance.name)
	if !process_alive(instance.pid) {
		return drive_failed("instance %s was not running (its log: %s)", instance.name, instance.log)
	}
	drive_request(instance.port, {op = "quit", timeout = 5})
	process, err := os.process_open(instance.pid)
	killed := false
	if err == nil {
		if _, wait_err := os.process_wait(process, DRIVE_STOP_TIMEOUT); wait_err != nil {
			kill_tree(process)
			killed = true
		}
	}
	text, _ := read_text(instance.log)
	problems: [dynamic]string
	append(&problems, ..godot_problems(text))
	if killed do append(&problems, aprintf("it did not quit within %.0fs: killed", time.duration_seconds(DRIVE_STOP_TIMEOUT)))
	for problem in problems do log("uni: %s", problem)
	encoded, _ := json.marshal(problems[:])
	return {
		ok      = len(problems) == 0,
		summary = aprintf(
			`{{"ok":%v,"name":%q,"log":%q,"problems":%s}}`,
			len(problems) == 0,
			instance.name,
			instance.log,
			string(encoded),
		),
	}
}

// A failed verb's reply, as the game's are: `{"ok":false,"error":...}`.
@(private)
drive_failed :: proc(format: string, args: ..any) -> Result {
	text, _ := json.marshal(aprintf(format, ..args))
	return {ok = false, summary = aprintf(`{{"ok":false,"error":%s}}`, string(text))}
}

// The godot suite's `drive` step: the game, headless with a single-player session at once, driven the way an agent
// drives it: status, pause, exact steps, a timed press stepped while paused (the action released after), the state,
// the sampled input, events, the menus' controls, an expression, a refused screenshot (no window), a resume and a
// wait on the session's own clock, then a stop whose log must be clean. Quiet unless it fails.
drive_check :: proc(game: Game) -> bool {
	NAME :: "suite-check"
	if instance, ok := drive_find(game, NAME); ok && process_alive(instance.pid) {
		drive_stop(game, instance) // a run that was cut short left it
	}
	started := drive_start(game, {name = NAME, headless = true}, {"--autostart"})
	if !started.ok {
		log("uni: %s drive: start: %s", game.name, started.summary)
		return false
	}
	instance, _ := drive_find(game, NAME)
	failed := ""
	call :: proc(
		instance: ^Drive_Instance,
		failed: ^string,
		want_ok: bool,
		op: string,
		args: ..string,
	) -> json.Object {
		if failed^ != "" do return nil
		reply, reached := drive_request(instance.port, {op = op, args = args, timeout = 10, strength = 1})
		value, _ := json.parse_string(reply, parse_integers = true)
		object, _ := value.(json.Object)
		replied_ok, _ := object["ok"].(json.Boolean)
		if !reached || bool(replied_ok) != want_ok {
			failed^ = aprintf("%s %s: %s", op, strings.join(args, " "), reply)
		}
		return object
	}
	tick :: proc(object: json.Object) -> i64 {
		value, _ := object["tick"].(json.Integer)
		return i64(value)
	}
	check :: proc(failed: ^string, cond: bool, format: string, args: ..any) {
		if failed^ == "" && !cond do failed^ = aprintf(format, ..args)
	}
	deadline := time.tick_add(time.tick_now(), 20 * time.Second)
	for failed == "" {
		status := call(&instance, &failed, true, "status")
		running, _ := status["running"].(json.Boolean)
		if running && tick(status) > 0 do break
		check(&failed, time.tick_diff(deadline, time.tick_now()) < 0, "the session never ran: %v", status)
		time.sleep(50 * time.Millisecond)
	}
	paused := tick(call(&instance, &failed, true, "pause"))
	from := tick(call(&instance, &failed, true, "step", "16"))
	check(&failed, from == paused + 16, "step 16 from the pause went from %d to %d", paused, from)
	stepped := tick(call(&instance, &failed, true, "step", "3"))
	check(&failed, stepped == from + 3, "step 3 went from %d to %d", from, stepped)
	pressed := tick(call(&instance, &failed, true, "press", "ui_right", "4"))
	check(&failed, pressed == stepped + 4, "a press for 4 ticks went from %d to %d", stepped, pressed)
	held := call(&instance, &failed, true, "eval", `Input.is_action_pressed("ui_right")`)
	still, _ := held["value"].(json.Boolean)
	check(&failed, !still, "the press was not released: %v", held["value"])
	state := call(&instance, &failed, true, "state")
	state_tick := tick(state)
	check(&failed, state_tick == pressed, "the state is of tick %d, the session's newest is %d", state_tick, pressed)
	_, is_object := state["value"].(json.Object)
	check(&failed, failed != "" || is_object, "the state is no object")
	call(&instance, &failed, true, "input")
	call(&instance, &failed, true, "events")
	call(&instance, &failed, true, "ui")
	sum := call(&instance, &failed, true, "eval", "6 * 7")
	product, _ := sum["value"].(json.Integer)
	check(&failed, product == 42, "eval 6 * 7 gave %v", sum["value"])
	call(&instance, &failed, false, "shot", join(drive_dir(game), "suite-check.png")) // headless: refused
	call(&instance, &failed, false, "state", "no_such_field")
	call(&instance, &failed, true, "resume")
	call(&instance, &failed, true, "wait", "ticks", "8")
	stopped := drive_stop(game, instance)
	if failed == "" && !stopped.ok do failed = aprintf("stop: %s", stopped.summary)
	if failed != "" {
		log("uni: %s drive: %s", game.name, failed)
		if text, ok := read_text(instance.log); ok do log("%s", tail(text, 3000))
	}
	return failed == ""
}

// The instance record `name`, if there is one.
@(private)
drive_find :: proc(game: Game, name: string) -> (Drive_Instance, bool) {
	for instance in drive_instances(game) {
		if instance.name == name do return instance, true
	}
	return {}, false
}
