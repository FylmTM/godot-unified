// `uni drive`: an agent drives a running game through its control socket (src/godot/README.md, The control socket).
// `start` launches the game with `--control` as a named instance, every other verb is one request to it, and `stop`
// quits it and judges its log. An instance's record is examples/<game>/.out/drive/<name>.json.
package cli

import "core:encoding/json"
import "core:fmt"
import "core:net"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"

// How long `start` waits for the game to answer (a cold shader cache, the first import).
DRIVE_START_TIMEOUT :: 90 * time.Second
// The frames a scene must have run before `start` judges the log: the scripts its start loads are parsed by then.
DRIVE_START_FRAMES :: 5
// How long `stop` waits for the game to quit before it kills it.
DRIVE_STOP_TIMEOUT :: 20 * time.Second

@(private)
Drive_Opts :: struct {
	name:     string `usage:"the instance (start: default the first free number; any other verb: default the only one running)"`,
	headless: bool `usage:"start: no window (shot then fails); default: a window, muted, on the leftmost screen, never taking focus"`,
	strength: f64 `usage:"press: the action's strength (default 1)"`,
	timeout:  f64 `usage:"seconds a waiting verb (pause, step, press for ticks, wait, shot, click) waits (default 10; for n ticks: 10 beyond twice their time)"`,
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
		"  start [-- game args]     launch the game with its control socket (--headless: no window) and wait until its\n" +
		"                           scene has run a few frames; prints its status. A GDScript error in its log by then\n" +
		"                           fails it (script_errors: res://file.gd:line: message) and stops the game\n" +
		"  stop                     quit it through the game, wait, and judge its log (errors, leaks: exit 1)\n" +
		"  list                     the instances of the game and whether each runs\n" +
		"  status                   mode, tick, verified tick, paused, level, players, local players, scene, and\n" +
		"                           script_errors when its log has any (a script loaded since start)\n" +
		"  pause | resume           stop or restart a single-player session's clock (exact: nothing moves while paused)\n" +
		"  step <n>                 a paused session steps exactly n ticks, sampling the input held now (it acts after the input delay)\n" +
		"  press <action> [n]       hold an Input Map action (--strength); with n: for n ticks, then release (paused: steps them);\n" +
		"                           polling (Input.is_action_pressed) and input handlers (_unhandled_input) both see it\n" +
		"  release <action>         let go of it\n" +
		"  command <name> [k=v ..]  send one of the game's commands (any, Command_Dev_* too) as local player 0 (sim units; a player by its key)\n" +
		"  state [path]             the newest predicted State as JSON (tables: live items by index), or the part a path names: players.slots[0]\n" +
		"  data [name[.path]]       the session data; constants [path]; input [path]: the local input sampled for the newest tick\n" +
		"  changes                  what the newest tick changed against the one before (the op log)\n" +
		"  values [k=v ..|clear]    the game's input values (Glue.input_values: what its scripts set, a camera's look) of\n" +
		"                           local player 0, and those held; k=v (command's syntax, one each: yaw=0.25 look[2]=-1)\n" +
		"                           holds them over what scripts set, every frame, until `values clear`: aims a\n" +
		"                           first-person game (a camera rig that keeps its own look still shows that look)\n" +
		"  events [name]            event states since the last `events` (--all: every one kept)\n" +
		"  wait ticks <n>           until the shown tick moved n ticks (running sessions; 10 s beyond twice their time)\n" +
		"  wait event <name>        until an event of that kind arrives after the previous reply\n" +
		"  shot [file.png]          the window as a PNG (default .out/drive/<name>-<n>.png in the game)\n" +
		"  ui                       the visible buttons and texts (path, class, text, disabled, rect)\n" +
		"  find <text|class|name>   every node, hidden too, whose name, class (its own, one it extends, its script's\n" +
		"                           class_name) or text holds it, any case: path, name, class, script_class, text,\n" +
		"                           visible, rect (a control's)\n" +
		"  click <text|path>        a real mouse click on a button by its text, or any control by its node path:\n" +
		"                           /root/Main/Start or root/Main/Start (what Git Bash makes of a leading / is undone)\n" +
		"  eval <expression>        a GDScript expression on the current scene (session, tree, root, scene, Input, Engine): its value\n" +
		"                           (its double quotes survive bash, PowerShell 5.1 and cmd alike; 'single' quotes work too)\n" +
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
				instance_alive(selected, instance),
			)
		}
		strings.write_string(&out, "]}")
		return {ok = true, summary = strings.to_string(out)}
	}
	instance := drive_instance(selected, opts.name)
	request := Drive_Request {
		op       = verb,
		args     = verb_args,
		timeout  = opts.timeout, // 0: the game's default (control.odin, CONTROL_TIMEOUT: scaled for ticks)
		strength = opts.strength > 0 ? opts.strength : 1,
	}
	switch verb {
	case "events":
		request.since = opts.all ? 0 : instance.events_seen
	case "wait":
		request.since = instance.serial_seen
	case "click":
		if len(verb_args) == 1 do request.args = strs(node_path_unmangled(verb_args[0]))
	case "eval":
		request.args = strs(eval_expression(verb_args, raw_command_line()))
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
		if instance_alive(selected, instance) do return drive_failed("instance %s did not answer: %s", instance.name, reply)
		return drive_failed("instance %s is not running (uni drive %s stop clears it)", instance.name, selected.name)
	}
	if verb == "status" && strings.has_suffix(reply, "}") {
		if errors := drive_script_errors(instance); errors != "" do reply = aprintf("%s%s}", reply[:len(reply) - 1], errors)
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
	// a backstop past the game's own deadline (it answers at that): with none given, the game's default for the most
	// ticks an argument asks, at a tick rate of at least 1 Hz
	backstop := request.timeout
	if backstop <= 0 {
		backstop = 10
		for arg in request.args {
			if ticks, parsed := strconv.parse_int(arg); parsed && ticks > 0 do backstop = max(backstop, 10 + 2 * f64(ticks))
		}
	}
	net.set_option(socket, .Receive_Timeout, time.Duration((backstop + 10) * f64(time.Second)))
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

// Whether the instance's game still runs: its pid names a running process that is that game, not one that took the
// pid over after the game ended (a crash, a closed window, a reboot): `stop` would kill that one's whole tree.
@(private)
instance_alive :: proc(game: Game, instance: Drive_Instance) -> bool {
	return process_runs(instance.pid, join(drive_dir(game), aprintf("%s.port", instance.name)))
}

// Whether the process with this pid runs and is the one started with `marker` among its arguments (one only that
// process has, such as the drive instance's --control port file). Arguments the OS doesn't give us count as a match:
// the pid is all there is to go on. (The arguments, not the command line: core:os reads a Windows command line
// at twice its length, and the text it makes of it can come back empty.)
process_runs :: proc(pid: int, marker: string) -> bool {
	if pid <= 0 do return false
	process, err := os.process_open(pid)
	if err != nil do return false
	state, wait_err := os.process_wait(process, 0)
	running := wait_err == .Timeout || wait_err == nil && !state.exited // Timeout: still running
	if !running do return false
	info, info_err := os.process_info_by_pid(pid, {.Command_Args}, context.temp_allocator)
	if info_err != nil || .Command_Args not_in info.fields do return true
	for arg in info.command_args {
		if strings.contains(slashed(arg), slashed(marker)) do return true
	}
	return false
}

// Launches the game with its control socket (a window as AGENT_WINDOW places it, or headless) and waits until it
// answers; its output goes to .out/drive/<name>.log.
@(private)
drive_start :: proc(game: Game, opts: Drive_Opts, game_args: []string) -> Result {
	if !has_extension(game) do usage("%s has no extension to drive", game.name)
	name := opts.name
	taken := drive_instances(game)
	for instance in taken {
		if !instance_alive(game, instance) {
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
		append(&cmd, ..window_args(AGENT_WINDOW)) // the project's window size
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
	process, err := spawn(
		{command = cmd[:], env = user_env(game.dir), stdin = stdin, stdout = log_file, stderr = log_file},
		stdin,
		log_file,
	)
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
	// up: a scene is current and has run DRIVE_START_FRAMES frames (the socket answers once a frame), so the
	// scripts its start loads have been parsed
	reply := ""
	frames := 0
	for frames < DRIVE_START_FRAMES {
		answer, ok := drive_request(instance.port, {op = "status", timeout = 10})
		if !ok do return drive_failed("the control socket does not answer: %s", answer)
		reply = answer
		if !strings.contains(reply, `"scene":null`) do frames += 1
		if time.tick_diff(deadline, time.tick_now()) > 0 do break
	}
	log_text, _ := read_text(log_path)
	if errors := script_errors(log_text); len(errors) > 0 {
		drive_stop(game, instance) // lists every problem of its log
		encoded, _ := json.marshal(errors)
		quoted_first, _ := json.marshal(aprintf("script error: %s", errors[0]))
		return {
			ok      = false,
			summary = aprintf(
				`{{"ok":false,"error":%s,"script_errors":%s,"name":%q,"log":%q}}`,
				string(quoted_first),
				string(encoded),
				name,
				log_path,
			),
		}
	}
	// the reply with the instance's name and log in front
	summary := aprintf(`{{"name":%q,"log":%q,%s`, name, log_path, strings.trim_prefix(reply, "{"))
	return {ok = true, summary = summary}
}

// The script errors in the instance's log so far (script_errors), as a reply's members (`,"script_errors":[...]`), or
// "" when there are none.
@(private)
drive_script_errors :: proc(instance: Drive_Instance) -> string {
	text, _ := read_text(instance.log)
	errors := script_errors(text)
	if len(errors) == 0 do return ""
	encoded, _ := json.marshal(errors)
	return aprintf(`,"script_errors":%s`, string(encoded))
}

// Quits the instance through the game (its own quit: sounds stopped, a clean exit), waits for it (killing it past
// DRIVE_STOP_TIMEOUT) and judges its log as a tool run's: an error line, a leak at exit or a GDScript warning fails.
@(private)
drive_stop :: proc(game: Game, instance: Drive_Instance) -> Result {
	defer drive_forget(game, instance.name)
	if !instance_alive(game, instance) {
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

// A node path back from what Git Bash made of it: it rewrites an argument starting with / into a Windows path
// (`/root/Main` arrives as `C:/Program Files/Git/root/Main`), so a drive-letter path holding a /root/ part becomes the
// node path from there. Anything else comes back as it is.
node_path_unmangled :: proc(arg: string) -> string {
	if len(arg) < 3 || arg[1] != ':' || (arg[2] != '/' && arg[2] != '\\') do return arg
	forward := slashed(arg)
	if i := strings.index(forward, "/root/"); i >= 0 do return forward[i:]
	if strings.has_suffix(forward, "/root") do return "/root"
	return arg
}

// `drive eval`'s expression: its arguments joined with spaces, unless Windows' argument rules dropped its double
// quotes. They keep a quote only when it is written \" (a POSIX shell and Git Bash do that; PowerShell 5.1 and cmd
// pass a quote as typed, which splitting then drops), so when the arguments hold no quote and the raw command line
// (`raw`, raw_command_line: "" elsewhere) does after its ` eval `, the expression is the rest of that line as typed;
// wrapped in quotes as a whole with a space inside (PowerShell 5.1 wraps an argument with a space that way) it is
// what is inside them.
eval_expression :: proc(args: []string, raw: string) -> string {
	joined := strings.join(args, " ")
	if strings.contains_rune(joined, '"') do return joined
	at := strings.index(raw, " eval ")
	if at < 0 do return joined
	tail := strings.trim_space(raw[at + len(" eval "):])
	for trimmed := true; trimmed; { 	// the global flags, which the arguments never hold
		trimmed = false
		for flag in ([]string{" --json", " --verbose"}) {
			if strings.has_suffix(tail, flag) do tail, trimmed = strings.trim_space(tail[:len(tail) - len(flag)]), true
		}
	}
	if !strings.contains_rune(tail, '"') do return joined
	inner := len(tail) >= 2 && tail[0] == '"' && tail[len(tail) - 1] == '"' ? tail[1:len(tail) - 1] : ""
	if strings.contains_rune(inner, ' ') do return inner
	return tail
}

// A failed verb's reply, as the game's are: `{"ok":false,"error":...}`.
@(private)
drive_failed :: proc(format: string, args: ..any) -> Result {
	text, _ := json.marshal(aprintf(format, ..args))
	return {ok = false, summary = aprintf(`{{"ok":false,"error":%s}}`, string(text))}
}

// The godot suite's `drive` step: the game, headless with a single-player session at once, driven the way an agent
// drives it: status, pause, exact steps, a timed press stepped while paused (an _unhandled_input handler sees it; the
// action released after), the state, the sampled input, events, the menus' controls, a node found by its class, an
// expression, a refused screenshot (no window), a resume and a wait on the session's own clock; its log clean until a
// script with a parse error is loaded, which its log then names as `file:line` and which is all a stop finds. Quiet
// unless it fails.
drive_check :: proc(game: Game) -> bool {
	NAME :: "suite-check"
	if instance, ok := drive_find(game, NAME); ok && instance_alive(game, instance) {
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
	// a node whose _unhandled_input records the press, as a game that sends its commands from a handler. The press is
	// of an action of the probe's own, bound to no event: a built-in one (ui_right) is focus navigation, which a
	// focused Control consumes before _unhandled_input, so the check would measure the game's UI, not the delivery.
	PROBE_ACTION :: "unified_drive_probe"
	for expression in ([]string {
			`Engine.get_singleton("InputMap").add_action("` + PROBE_ACTION + `")`,
			`root.set_meta("drive_probe", Engine.get_singleton("ClassDB").instantiate("GDScript"))`,
			`root.get_meta("drive_probe").set_source_code("extends Node
var seen: bool = false
func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(\"` + PROBE_ACTION + `\"):
		seen = true
")`,
			`root.get_meta("drive_probe").reload()`,
			`root.set_meta("drive_probe_node", Engine.get_singleton("ClassDB").instantiate("Node"))`,
			`root.get_meta("drive_probe_node").set_script(root.get_meta("drive_probe"))`,
			`root.add_child(root.get_meta("drive_probe_node"))`,
		}) {
		call(&instance, &failed, true, "eval", expression)
	}
	pressed := tick(call(&instance, &failed, true, "press", PROBE_ACTION, "4"))
	check(&failed, pressed == stepped + 4, "a press for 4 ticks went from %d to %d", stepped, pressed)
	held := call(&instance, &failed, true, "eval", `Input.is_action_pressed("` + PROBE_ACTION + `")`)
	still, _ := held["value"].(json.Boolean)
	check(&failed, !still, "the press was not released: %v", held["value"])
	probe := call(&instance, &failed, true, "eval", `root.get_meta("drive_probe_node").seen`)
	seen, _ := probe["value"].(json.Boolean)
	check(&failed, failed != "" || bool(seen), "an _unhandled_input handler never saw the press: %v", probe["value"])
	state := call(&instance, &failed, true, "state")
	state_tick := tick(state)
	check(&failed, state_tick == pressed, "the state is of tick %d, the session's newest is %d", state_tick, pressed)
	_, is_object := state["value"].(json.Object)
	check(&failed, failed != "" || is_object, "the state is no object")
	call(&instance, &failed, true, "input")
	drive_check_values(&instance, &failed)
	call(&instance, &failed, true, "events")
	call(&instance, &failed, true, "ui")
	sessions, _ := call(&instance, &failed, true, "find", "UnifiedSession")["nodes"].(json.Array)
	check(&failed, len(sessions) >= 1, "find UnifiedSession found no node")
	if len(sessions) >= 1 {
		first, _ := sessions[0].(json.Object)
		class, _ := first["class"].(json.String)
		check(&failed, class == "UnifiedSession", "find UnifiedSession found a %v first", first)
	}
	nothing, _ := call(&instance, &failed, true, "find", "no node is named this")["nodes"].(json.Array)
	check(&failed, failed != "" || len(nothing) == 0, "find of no name found %d nodes", len(nothing))
	sum := call(&instance, &failed, true, "eval", "6 * 7")
	product, _ := sum["value"].(json.Integer)
	check(&failed, product == 42, "eval 6 * 7 gave %v", sum["value"])
	call(&instance, &failed, false, "shot", join(drive_dir(game), "suite-check.png")) // headless: refused
	call(&instance, &failed, false, "state", "no_such_field")
	call(&instance, &failed, true, "resume")
	call(&instance, &failed, true, "wait", "ticks", "8")
	// no timeout given: the game's, scaled for the ticks; one given: that, however many ticks are asked
	if failed == "" {
		reply, _ := drive_request(instance.port, {op = "wait", args = {"ticks", "4"}})
		check(&failed, strings.has_prefix(reply, `{"ok":true`), "wait ticks 4 with the game's timeout: %s", reply)
		asked := time.tick_now()
		reply, _ = drive_request(instance.port, {op = "wait", args = {"ticks", "100000"}, timeout = 0.3})
		waited := time.duration_seconds(time.tick_since(asked))
		check(
			&failed,
			strings.contains(reply, "timed out") && waited < 5,
			"wait ticks 100000 --timeout 0.3: %s after %.1fs",
			reply,
			waited,
		)
	}
	// a clean log so far; then a script with a parse error loaded: status names it (drive_script_errors), and it is
	// all stop finds
	log_text, _ := read_text(instance.log)
	early := godot_problems(log_text)
	check(&failed, len(early) == 0, "the log has problems before the broken script: %v", early)
	BROKEN :: "suite-check-broken.gd"
	write_text(join(drive_dir(game), BROKEN), "extends Node\n\nvar x: int = \n")
	call(
		&instance,
		&failed,
		true,
		"eval",
		`Engine.get_singleton("ResourceLoader").load("res://.out/drive/` + BROKEN + `")`,
	)
	if failed == "" && !strings.contains(drive_script_errors(instance), "res://.out/drive/" + BROKEN + ":3: ") {
		failed = aprintf("status names no script error at %s:3: %s", BROKEN, drive_script_errors(instance))
	}
	stopped := drive_stop(game, instance)
	stop_reply, _ := json.parse_string(stopped.summary)
	problems, _ := stop_reply.(json.Object)["problems"].(json.Array)
	for problem in problems {
		text, _ := problem.(json.String)
		ours :=
			strings.contains(text, BROKEN) || strings.contains(text, "Expected expression for variable initial value")
		check(&failed, ours, "stop: a problem besides the broken script: %s", text)
	}
	check(&failed, len(problems) > 0, "stop found no problem with the broken script: %s", stopped.summary)
	if failed != "" {
		log("uni: %s drive: %s", game.name, failed)
		if text, ok := read_text(instance.log); ok do log("%s", tail(text, 3000))
	}
	return failed == ""
}

// The drive step's `values` (a paused session): a game without input values says so; one with them holds a number
// field (the first by name, or its first element) at what was set while frames step, whatever its scripts set every
// frame (whole numbers for an integer field), and lets go at `values clear`.
@(private)
drive_check_values :: proc(instance: ^Drive_Instance, failed: ^string) {
	if failed^ != "" do return
	values :: proc(instance: ^Drive_Instance, args: ..string) -> (object: json.Object, reply: string) {
		reply, _ = drive_request(instance.port, {op = "values", args = args, timeout = 10})
		value, _ := json.parse_string(reply, parse_integers = true)
		object, _ = value.(json.Object)
		return
	}
	shown, reply := values(instance)
	if replied_ok, _ := shown["ok"].(json.Boolean); !replied_ok {
		if !strings.contains(reply, "no input values") do failed^ = aprintf("values: %s", reply)
		return
	}
	fields, _ := shown["value"].(json.Object)
	names: [dynamic]string
	for name in fields do append(&names, name)
	slice.sort(names[:])
	key := ""
	integer := false // an integer field takes whole numbers (a float is refused)
	for name in names {
		#partial switch field in fields[name] {
		case json.Float, json.Integer:
			key = name
			_, integer = field.(json.Integer)
		case json.Array:
			if len(field) > 0 {
				#partial switch _ in field[0] {
				case json.Float, json.Integer:
					key = aprintf("%s[0]", name)
					_, integer = field[0].(json.Integer)
				}
			}
		}
		if key != "" do break
	}
	if key == "" do return // no number to hold
	number :: proc(object: json.Object, key: string) -> f64 {
		fields, _ := object["value"].(json.Object)
		name, _, _ := strings.partition(key, "[")
		field := fields[name]
		if list, is_list := field.(json.Array); is_list && len(list) > 0 do field = list[0]
		#partial switch value in field {
		case json.Float:
			return value
		case json.Integer:
			return f64(value)
		}
		return -1
	}
	first, second: f64 = 0.375, 0.25
	if integer do first, second = 3, 2
	assignment := aprintf("%s=%v", key, first)
	set, reply_set := values(instance, assignment)
	held, _ := set["held"].(json.Array)
	if ok, _ := set["ok"].(json.Boolean); !ok || len(held) != 1 || number(set, key) != first {
		failed^ = aprintf("values %s: %s", assignment, reply_set)
		return
	}
	if reply_step, reached := drive_request(instance.port, {op = "step", args = {"3"}, timeout = 10}); !reached {
		failed^ = aprintf("step 3 with %s held: %s", assignment, reply_step)
		return
	}
	after, reply_after := values(instance)
	if number(after, key) != first do failed^ = aprintf("%s did not stay held over 3 stepped frames: %s", assignment, reply_after)
	again := aprintf("%s=%v", key, second) // the same place again: replaces the held one, not a second
	replaced, reply_replaced := values(instance, again)
	held_now, _ := replaced["held"].(json.Array)
	if (len(held_now) != 1 || number(replaced, key) != second) && failed^ == "" {
		failed^ = aprintf("values %s after %s: %s", again, assignment, reply_replaced)
	}
	refused, reply_refused := values(instance, "no_such_field=1")
	if ok, _ := refused["ok"].(json.Boolean); ok && failed^ == "" do failed^ = aprintf("values no_such_field=1: %s", reply_refused)
	cleared, reply_cleared := values(instance, "clear")
	held_after, _ := cleared["held"].(json.Array)
	if ok, _ := cleared["ok"].(json.Boolean); (!ok || len(held_after) != 0) && failed^ == "" {
		failed^ = aprintf("values clear: %s", reply_cleared)
	}
}

// The instance record `name`, if there is one.
@(private)
drive_find :: proc(game: Game, name: string) -> (Drive_Instance, bool) {
	for instance in drive_instances(game) {
		if instance.name == name do return instance, true
	}
	return {}, false
}
