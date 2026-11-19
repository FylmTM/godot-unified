// UnifiedSession: the GDScript-facing session node; each member's doc is where it is bound (src/godot/README.md,
// Godot side).
package godot

import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:time"
import gd "unified:gdext"
import "unified:gdext/gdi"
import "unified:netcode"
import "unified:sim"

@(private)
Session_Node :: struct {
	using hdr:   gd.Instance_Header,
	view_root:   gd.Node, // where scene views are spawned, as its children (once root_set; before: the session's parent)
	root_id:     u64,
	root_set:    bool, // view_root was assigned (null included: no scene views)
	synced_root: u64, // the instance id of the root the scene views live under (views_root_changed when it changes)
	seed:        i64,
	ticks:       i64,
	name:        string,
	status:      Status_Kind,
	detail:      string,
	join_code:   string, // UnifiedSession.join_code ("": none)
	args:        Args,
	args_read:   bool,
	frame:       ^Frame_Data, // newest frame taken this process step (valid until the next one; nil once over)
	ended:       bool, // the session's Result came: one more frame is taken (its last), then none
	over:        bool, // that last frame was shown: views keep their pose, nothing is synced until the next start
	last_tick:   u32,
	quit_at_end: bool,
	sync_us:     f32,
	pending:     Start, // a start that waits for the previous session's goodbye (has_pending)
	has_pending: bool,
	roster_seen: u32, // roster.changes when roster_changed was last emitted
	slots_seen:  [sim.MAX_PLAYERS]u64, // the shown frame's slots when roster_changed was last emitted
	known_seen:  int, // the shown frame's n_members then
	mode:        Mode, // the session started last (UnifiedSession.mode; the dev UI: no netsim in single player)
	level:       Level_Host, // the level on screen and its scene (level_host.odin)
	locals_seen: [LOCAL_MAX]u64, // the local players' keys when local_players_changed was last emitted
	quitting:    Quit_Wait, // a quit the session asked for, waiting for the sounds it stopped (quit.odin)
	link_slow:   bool, // UnifiedSession.link_slow
	saves_seen:  u32, // the shown frame's save count when save_changed was last emitted
}

@(private)
Args :: struct {
	autostart:        bool, // start single player at once (headless checks)
	join:             string, // join_direct this address at once
	host_port:        int, // host_direct on this port at once
	local_net:        bool, // direct hosting listens on 127.0.0.1 only (tool runs: no firewall prompt)
	scripted:         bool, // scripted input (the offline binary's), for hash checks
	slot:             string, // --slot n: a joiner asks for slot n (scripted: and joins as the offline run's player n)
	ticks:            int, // session length (0: endless)
	seed:             i64,
	quit:             bool, // quit when the session ends, printing its result
	devui:            bool, // dev UI shown at start
	lag_ms:           int, // netsim on remote links: this one-way latency, a quarter of it as jitter, 1% loss
	bench:            int, // single player sessions hold this many entities (Game.bench_prepare)
	online:           bool, // host_online at once
	join_code:        string, // join_online this code at once
	draw:             string, // the debug draw groups shown (UnifiedSession.debug_draw)
	setup:            string, // --setup key=value,...: the Setup of sessions this process hosts (the game's default with them)
	profile:          string, // --profile key=value,...: set on Unified.profile at the start
	replay:           string, // replay this folder at once
	no_watchdog:      bool, // no session-thread watchdog (watchdog.odin)
	verified_players: bool, // other players start on the verified timeline (a dev option, verified_players.odin)
	control:          string, // open the control socket and write its port to this file (control.odin)
}

@(private)
session_class: gd.Class
@(private)
active: ^Session_Node

@(private)
register_session_class :: proc() {
	session_class = {
		name = "UnifiedSession",
		parent = "Node",
		size = size_of(Session_Node),
		doc_brief = "Runs a unified session (single player, host or join) and shows it: views, events, commands.",
		doc = "One per app. The session runs the game's deterministic sim on its own thread; this node takes the newest frame every process step (at priority -1000, before every other node), moves the scene views under [member view_root], fills the MultiMesh views, and routes the sim's events to their views and to [signal sim_event]. The game's extension decides what the views are (src/godot/README.md). Reach it typed: [code]@onready var session: UnifiedSession = %UnifiedSession[/code], or [code]Unified.session[/code]. Players are ints: a player's key, the same while they are in the session whatever slot they hold (0: nobody).",
		init = proc(instance: rawptr) {
			session := (^Session_Node)(instance)
			session.seed = 1 // local_name stays "": the roster shows "P" and the slot from 1
			level_host_reset(&session.level)
		},
		fini = proc(instance: rawptr) {
			session := (^Session_Node)(instance)
			if active == session {
				session_end(session)
				active = nil
			}
			clear_pending(session)
			level_scene_free(&session.level)
			level_load_drop(&session.level)
			level_host_collect(&session.level, wait = true)
			delete(session.level.dropped)
			delete(session.name)
			delete(session.detail)
			delete(session.join_code)
		},
		ready = proc(instance: rawptr) {session_ready((^Session_Node)(instance))},
		process = proc(instance: rawptr, dt: f64) {session_process((^Session_Node)(instance), dt)},
		input = proc(instance: rawptr, event: gd.InputEvent) {
			if !is_editor() && active == (^Session_Node)(instance) do input_event(event)
		},
		notification = proc(instance: rawptr, what: i32) {
			session := (^Session_Node)(instance)
			switch what {
			case gd.Node_NOTIFICATION_EXIT_TREE:
				if active == session {
					session_end(session)
					views_clear()
					dev_shutdown()
					active = nil
				}
			case gd.Object_NOTIFICATION_EXTENSION_RELOADED:
				// New code, same Godot object: Odin state is fresh; Godot restored the saved properties.
				if !is_editor() && gd.Node_is_inside_tree(node_of(session)) do session_ready(session)
			}
		},
	}
	class := &session_class
	gd.register_class(class)
	// what the next session starts with
	gd.bind_property(
		class,
		"seed",
		proc(session: ^Session_Node) -> i64 {return session.seed},
		proc(session: ^Session_Node, value: i64) {session.seed = value},
		doc = "The next session's seed.",
	)
	gd.bind_property(
		class,
		"ticks",
		proc(session: ^Session_Node) -> i64 {return session.ticks},
		proc(session: ^Session_Node, value: i64) {session.ticks = value},
		doc = "The next session's length in ticks (0: endless).",
	)
	gd.bind_property(
		class,
		"local_name",
		proc(session: ^Session_Node) -> string {return session.name},
		proc(session: ^Session_Node, name: string) {
			delete(session.name)
			session.name = strings.clone(name)
		},
		doc = "The name the next session shows to other players (\"\", the default: \"P\" and the player's slot from 1).",
	)
	gd.bind_property(
		class,
		"game_input",
		proc(session: ^Session_Node) -> bool {return !input_sample.off},
		proc(session: ^Session_Node, on: bool) {set_game_input(on)},
		doc = "Off, the game's input helpers read nothing (a pause menu, a chat field: their keys and clicks don't reach the sim); [member Unified.input] still flows. When it is turned back on, an action still held counts only once it is released.",
	)
	gd.bind_property(class, "paused", proc(session: ^Session_Node) -> bool {
			if session.mode == .Replay do return session.frame != nil && session.frame.replay.paused
			return sync.atomic_load(&pause_on)
		}, proc(session: ^Session_Node, paused: bool) {
			if session.mode == .Replay do replay_control({kind = paused ? .Pause : .Play})
			else do sync.atomic_store(&pause_want, paused)
		}, doc = "Stops a single-player session's clock: no tick is sampled or stepped until it is false again, and the session goes on as if no time had passed (exact: nobody else waits). Reads true once the session thread paused it, false while a session has other players (online a pause is the game's own state: a command) and when a session starts, so a pause menu can set it in every mode. Views hold their last pose meanwhile. A replay's playhead stops the same way (playing again from its last tick starts over).")
	gd.bind_property(class, "view_root", view_root_of, proc(session: ^Session_Node, node: gd.Node) {
			session.view_root = node
			session.root_id = node.ptr != nil ? gdi.object_get_instance_id(node.ptr) : 0
			session.root_set = true
		}, .NODE_TYPE, "Node", doc = "Where scene views are made, as its children: set in the inspector or from a script; until it is set, the session's parent. Null, or a node outside the tree: no scene views.")
	gd.bind_property(class, "level_root", level_root_of, proc(session: ^Session_Node, node: gd.Node) {
			session.level.root = node
			session.level.root_id = node.ptr != nil ? gdi.object_get_instance_id(node.ptr) : 0
		}, .NODE_TYPE, "Node", doc = "Where the active level's scene is instanced (the scene its .level file was exported from): the session loads it on a thread and swaps it in when the verified level changes, freeing the old level's instance and every scene view with it. Null (the default): the game shows its level itself; [member level] and the level signals work all the same.")
	gd.bind_property(
		class,
		"devui_visible",
		proc(session: ^Session_Node) -> bool {return dev_visible()},
		proc(session: ^Session_Node, visible: bool) {dev_set_visible(visible)},
		doc = "The dev UI is shown (F1 toggles it; always false in a build without it).",
	)
	gd.bind_property(
		class,
		"debug_draw",
		proc(session: ^Session_Node) -> string {return debug_draw_wanted()},
		proc(session: ^Session_Node, groups: string) {debug_draw_want(groups)},
		doc = "The sim's debug draw groups shown besides the dev UI's toggles: \"all\", or group names, comma-separated (a zone's lowercased name, \"other\", a library's such as \"physics_shapes\"); \"\": none. [code]--draw[/code] sets it. A build without the dev UI draws nothing.",
	)
	gd.bind_property(
		class,
		"debug_draw_count",
		proc(session: ^Session_Node) -> i64 {return i64(debug_draw_count())},
		doc = "How many debug draws (shapes and texts) the shown tick has on screen.",
	)
	gd.bind_property(
		class,
		"level",
		proc(session: ^Session_Node) -> i64 {return i64(session.level.shown.id)},
		nil,
		doc = "The level on screen: its index in the game's levels, an [EnumLevel] value (-1: none yet, or the game keeps no level). It follows the verified level, so a mispredicted change never shows.",
	)
	gd.bind_property(class, "level_scene", proc(session: ^Session_Node) -> gd.Node {
			host := &session.level
			return host.scene if host.scene.ptr != nil && alive(host.scene_id) else {}
		}, nil, .NODE_TYPE, "Node", doc = "The shown level's instance under [member level_root] (null: none, or while the first level loads).")
	// the running session, at the shown tick
	gd.bind_property(
		class,
		"status",
		proc(session: ^Session_Node) -> i64 {return i64(session.status)},
		class_name = "UnifiedSession.Status",
		doc = "The session's status ([signal status_changed] says when it changes).",
	)
	gd.bind_property(
		class,
		"mode",
		proc(session: ^Session_Node) -> i64 {return i64(session.mode)},
		class_name = "UnifiedSession.Mode",
		doc = "How the session started last began (single player, hosting or joining), whoever started it: a script, the menus or the command line's flags. Read it once [member status] leaves STATUS_IDLE.",
	)
	gd.bind_property(
		class,
		"join_code",
		proc(session: ^Session_Node) -> string {return session.join_code},
		doc = "What others join this session with, once the host knows it (\"\": none, or not hosting): online, the lobby code ([method join_online]); hosting direct, this machine's private IPv4 address and the port ([method join_direct], 127.0.0.1 when it has none). [signal join_code_changed] says when it changes.",
	)
	gd.bind_property(
		class,
		"running",
		proc(session: ^Session_Node) -> bool {return api.installed && api.running()},
		doc = "A session is running (until its thread ended, after a goodbye).",
	)
	gd.bind_property(
		class,
		"tick",
		proc(session: ^Session_Node) -> i64 {return i64(session.last_tick)},
		doc = "The tick shown (the newest predicted one).",
	)
	gd.bind_property(
		class,
		"round_trip_ms",
		proc(session: ^Session_Node) -> f64 {return session.frame != nil ? session.frame.net.rtt_ms : 0},
		doc = "The round trip to the host the input delay is computed from, in milliseconds, at the shown frame (next to 0 in single player and for the host: its relay is in-process).",
	)
	gd.bind_property(
		class,
		"round_trip_ceiling_ms",
		proc(session: ^Session_Node) -> f64 {return session.frame != nil ? session.frame.net.ceiling_ms : 0},
		doc = "The longest round trip this game plays smoothly at, in milliseconds (from its tick rate; 0 before a session runs). Past it the player's view stalls; their inputs still count.",
	)
	gd.bind_property(
		class,
		"input_delay_ticks",
		proc(session: ^Session_Node) -> i64 {return session.frame != nil ? i64(session.frame.net.delay) : 0},
		doc = "The input delay in ticks (the lag the player feels: [code]input_delay_ticks * 1000 / tick_hz[/code] ms) at the shown frame; at least the game's floor.",
	)
	gd.bind_property(
		class,
		"link_slow",
		proc(session: ^Session_Node) -> bool {return session.link_slow},
		doc = "The round trip to the host is past [member round_trip_ceiling_ms] ([signal link_slow_changed] says when it changes): show a warning, or leave in the game's own words. Judged after a few round trips; it clears after 2 s back under the ceiling.",
	)
	gd.bind_property(class, "host_silent_ms", proc(session: ^Session_Node) -> f64 {
			if session.frame == nil || session.frame.net.last_msg_us == 0 do return 0
			return f64(netcode.now_us() - session.frame.net.last_msg_us) / 1000
		}, doc = "How long nothing has come from the host, in milliseconds (0 before the first). The world freezes while the link is down; past a second or so, a game may say \"connection problems\".")
	gd.bind_property(class, "local_player", proc(session: ^Session_Node) -> i64 {
			return session.frame != nil ? i64(session.frame.local_player) : 0
		}, doc = "The first local player's key at the shown tick (0 until it joins, and once the session is over): a game of one local player reads this; [member local_players] has them all.")
	gd.bind_dynamic_method(class, "get_players", proc(_: rawptr, instance: rawptr, _: []^gd.Variant) -> gd.Variant {
			session := (^Session_Node)(instance)
			players := player_array()
			if session.frame != nil {
				for key in session.frame.slots do if key != 0 do gd.array_push(&players, i64(key))
			}
			return array_variant(&players)
		}, nil, nil, gd.Dynamic_Arg{"", .ARRAY, "int"}, doc = "The keys of the players present at the shown tick, in slot order.")
	gd.bind_dynamic_method(class, "get_known_players", proc(_: rawptr, instance: rawptr, _: []^gd.Variant) -> gd.Variant {
			session := (^Session_Node)(instance)
			players := player_array()
			if session.frame != nil {
				for key in session.frame.members[:session.frame.n_members] do gd.array_push(&players, i64(key))
			}
			return array_variant(&players)
		}, nil, nil, gd.Dynamic_Arg{"", .ARRAY, "int"}, doc = "The keys of every player the session remembers at the shown tick, present or not.")
	gd.bind_method(class, "get_player_slot", proc(session: ^Session_Node, player: i64) -> i64 {
			return i64(shown_slot(session, player))
		}, {"player"}, doc = "The slot (input index) [param player] holds at the shown tick; -1 when absent.")
	gd.bind_method(class, "get_player_name", proc(session: ^Session_Node, player: i64) -> string {
			return player_name(session, player)
		}, {
			"player",
		}, doc = "The name [param player] goes by in the session: the one they gave, else \"P\" and their slot counted from 1 while they hold one (\"\" for a player the session doesn't know); still answers after they left.")
	gd.bind_method(class, "get_player_platform", proc(session: ^Session_Node, player: i64) -> string {
			entry, ok := roster_entry(player)
			return ok ? strings.clone(netcode.text_string(&entry.platform), context.temp_allocator) : ""
		}, {
			"player",
		}, doc = "The platform of the account the lobby's link vouched for (\"eos\"); empty on LAN, in single player and in replays.")
	gd.bind_method(class, "get_player_platform_id", proc(session: ^Session_Node, player: i64) -> string {
			entry, ok := roster_entry(player)
			return ok ? strings.clone(netcode.text_string(&entry.account), context.temp_allocator) : ""
		}, {
			"player",
		}, doc = "The account id the lobby's link vouched for (EOS: the product user id); empty on LAN, in single player and in replays.")
	// the scene views, from the host's own tables
	gd.bind_method(
		class,
		"get_view",
		proc(session: ^Session_Node, kind: i64, key: i64) -> gd.Node {return view_of_key(kind, u64(key))},
		{"kind", "key"},
		doc = "The scene view of [param kind] (an [EnumView] value; another is an error, once) and [param key], null when there is none (or it lingers, gone from the sim).",
	)
	gd.bind_method(
		class,
		"get_player_view",
		proc(session: ^Session_Node, kind: i64, player: i64) -> gd.Node {return view_of_player(kind, u64(player))},
		{"kind", "player"},
		doc = "The scene view of [param kind] (an [EnumView] value) that shows [param player] (its marker's [member UnifiedView.player]), null when there is none.",
	)
	gd.bind_dynamic_method(class, "get_views", proc(_: rawptr, _: rawptr, args: []^gd.Variant) -> gd.Variant {
			kind, _ := gd.from_variant(i64, args[0])
			views := views_of_kind(kind)
			return array_variant(&views)
		}, nil, {{"kind", .INT, ""}}, gd.Dynamic_Arg{"", .ARRAY, "Node"}, doc = "Every scene view of [param kind] (an [EnumView] value) that is in the sim (not lingering), by key.")
	// starting, leaving, sending
	setup_arg := gd.Dynamic_Arg{"setup", .OBJECT, SETUP_CLASS}
	no_setup := []gd.Variant{gd.variant_nil()}
	gd.bind_dynamic_method(
		class,
		"start_single",
		proc(_: rawptr, instance: rawptr, args: []^gd.Variant) -> gd.Variant {
			request := Start {
				mode = .Single,
			}
			ok := setup_of(args[0], &request, "start_single") && session_start((^Session_Node)(instance), request)
			return gd.to_variant(ok)
		},
		nil,
		{setup_arg},
		gd.Dynamic_Arg{"", .BOOL, ""},
		doc = "Starts a single player session playing [param setup] (null: the game's default Setup). False, with an error, when it can't start or the setup does not read on this build.",
		defaults = no_setup,
	)
	gd.bind_dynamic_method(class, "host_online", proc(_: rawptr, instance: rawptr, args: []^gd.Variant) -> gd.Variant {
			request := Start {
				mode = .Host_Online,
			}
			ok := setup_of(args[0], &request, "host_online") && session_start((^Session_Node)(instance), request)
			return gd.to_variant(ok)
		}, nil, {setup_arg}, gd.Dynamic_Arg{"", .BOOL, ""}, doc = "Hosts an online session through the game's lobby service, playing [param setup] (null: the game's default); [member join_code] is the code to share once it is known.", defaults = no_setup)
	gd.bind_dynamic_method(class, "host_direct", proc(_: rawptr, instance: rawptr, args: []^gd.Variant) -> gd.Variant {
			port, _ := gd.from_variant(i64, args[0])
			request := Start {
				mode = .Host_Direct,
				port = int(port),
			}
			ok := setup_of(args[1], &request, "host_direct") && session_start((^Session_Node)(instance), request)
			return gd.to_variant(ok)
		}, nil, {{"port", .INT, ""}, setup_arg}, gd.Dynamic_Arg{"", .BOOL, ""}, doc = "Hosts on a UDP port (LAN), playing [param setup] (null: the game's default); 127.0.0.1 only when the process got [code]--local-net[/code].", defaults = no_setup)
	gd.bind_dynamic_property(class, {"setup", .OBJECT, SETUP_CLASS}, proc(_: rawptr, instance: rawptr, _: []^gd.Variant) -> gd.Variant {
			session := (^Session_Node)(instance)
			if D.setup == nil do return gd.variant_nil()
			bytes := session.frame != nil ? session.frame.setup[:] : api.setup_default
			return nested_variant(D.setup, bytes[:D.setup.layout.type.size], .View)
		}, nil, doc = "The running session's Setup (a joiner's is the host's), as a new [UnifiedSetup]; the game's default before the first frame.")
	gd.bind_method(class, "join_online", proc(session: ^Session_Node, code: string) -> bool {
			return session_start(session, {mode = .Join_Online, arg = code})
		}, {"code"}, doc = "Joins an online session by its lobby code.")
	gd.bind_method(class, "join_direct", proc(session: ^Session_Node, address: string) -> bool {
			return session_start(session, {mode = .Join_Direct, arg = address})
		}, {"address"}, doc = "Joins a directly hosted session at [code]host:port[/code].")
	// replays
	gd.bind_method(class, "replay", proc(session: ^Session_Node, folder: string) -> bool {
			return session_start(session, {mode = .Replay, arg = globalize(folder)})
		}, {
			"folder",
		}, doc = "Replays a recording: an F3 note's folder, a session's under [code]user://recordings[/code], or a freeze's (its [code]inputs.unil[/code], and the [code]snapshot.unis[/code] it continues, if any). The game's views, events and session data work as live; every tick is final (events arrive EVENT_EMITTED and EVENT_CONFIRMED together); [member local_player] is [member replay_player]. A note starts some seconds before its noted tick and pauses on it; a recording of another build plays, checked against its checkpoints. False, with a failed status, when the folder holds no recording of this game.")
	gd.bind_property(
		class,
		"replay_speed",
		proc(session: ^Session_Node) -> f64 {return session.frame != nil ? f64(session.frame.replay.speed) : 1},
		proc(session: ^Session_Node, speed: f64) {replay_control({kind = .Speed, speed = f32(speed)})},
		doc = "A replay's speed, 0.25 to 4 (1: real time).",
	)
	gd.bind_property(
		class,
		"replay_player",
		proc(session: ^Session_Node) -> i64 {return session.frame != nil ? i64(session.frame.replay.follow) : 0},
		proc(session: ^Session_Node, player: i64) {replay_control({kind = .Follow, value = player})},
		doc = "The player a replay follows ([member local_player]: the game's camera and \"my view\" code follow them); at first whoever recorded it.",
	)
	gd.bind_property(
		class,
		"replay_first_tick",
		proc(session: ^Session_Node) -> i64 {return session.frame != nil ? i64(session.frame.replay.first) : 0},
		doc = "The first tick a replay can show (its snapshot's).",
	)
	gd.bind_property(
		class,
		"replay_last_tick",
		proc(session: ^Session_Node) -> i64 {return session.frame != nil ? i64(session.frame.replay.last) : 0},
		doc = "The last tick a replay can show.",
	)
	gd.bind_property(
		class,
		"replay_agreed_tick",
		proc(session: ^Session_Node) -> i64 {return session.frame != nil ? i64(session.frame.replay.agreed) : 0},
		doc = "The last of the recording's checkpoints this build computed the same so far (0: none yet).",
	)
	gd.bind_property(
		class,
		"replay_diverged_tick",
		proc(session: ^Session_Node) -> i64 {return session.frame != nil ? i64(session.frame.replay.diverged) : 0},
		doc = "The first of the recording's checkpoints this build computed differently (0: none): the bug is between it and [member replay_agreed_tick].",
	)
	gd.bind_method(class, "replay_step", proc(session: ^Session_Node, ticks: i64) {
			replay_control({kind = .Step, value = ticks})
		}, {"ticks"}, doc = "Steps a replay [param ticks] ticks forward (negative: back) and pauses it.")
	gd.bind_method(class, "replay_seek", proc(session: ^Session_Node, tick: i64) {
			replay_control({kind = .Seek, value = tick})
		}, {
			"tick",
		}, doc = "Moves a replay to [param tick] (clamped to its ticks); the views snap, the ticks between show nothing.")
	gd.bind_method(class, "replay_loop", proc(session: ^Session_Node, from: i64, to: i64) {
			replay_control({kind = .Loop, value = from, other = to})
		}, {
			"from",
			"to",
		}, doc = "Plays the ticks [param from] to [param to] over and over; [code]replay_loop(0, 0)[/code] stops looping.")
	gd.bind_method(
		class,
		"leave",
		session_leave,
		doc = "Ends the session: it says goodbye on its own thread, then the status is [constant STATUS_LEFT]. A start right after waits for it.",
	)
	gd.bind_method(class, "quit", proc(session: ^Session_Node, exit_code: i64) {
			session_leave(session)
			quit_when_quiet(session, int(exit_code))
		}, {
			"exit_code",
		}, doc = "Quits the app with [param exit_code]: ends the session as [method leave] does, stops every sound in the tree and quits once the AudioServer has freed their playbacks (at most a second later), so none is reported as leaked at exit. The session's own quit at the end of a [code]--quit-at-end[/code] run is this one. Stop the app's own sound sources first, or a sound started meanwhile is stopped too.")
	gd.bind_dynamic_method(class, "send_command", proc(_: rawptr, _: rawptr, args: []^gd.Variant) -> gd.Variant {
			command, _ := gd.from_variant(gd.Object, args[0])
			local, _ := gd.from_variant(i64, args[1])
			if local < 0 || local >= LOCAL_MAX do return gd.to_variant(false)
			return gd.to_variant(send_command(command, int(local)))
		}, nil, {{"command", .OBJECT, "UnifiedCommand"}, {"local", .INT, ""}}, gd.Dynamic_Arg{"", .BOOL, ""}, doc = "Sends one of the game's commands from local player [param local] (make one with its class, e.g. [code]CommandDrop.new()[/code]); the sim gets it exactly once, from that player. False, with an error naming why, when it can't be sent: not one of the game's commands, a property set to a wrong value, no running session, or a full queue.", defaults = {gd.to_variant(i64(0))})
	bind_local_players(class)
	bind_open_to_friends(class)
	gd.bind_method(
		class,
		"take_sync_stats",
		take_sync_stats,
		doc = "The view sync's cost since the last call, then counts anew. The main thread: frames, fresh (frames with a new tick), events (deliveries), and microseconds summed over the frames: scene_us, multi_build_us, multi_upload_us, delivery_us, total_us; total_max_us is the slowest frame's. The session thread: fills (published frames), fill_us summed (tracking the ticks' events, fill_frame, publishing), fill_max_us the slowest; wakes (its sleeps), how late they woke (wake_p50_us, wake_p99_us, wake_max_us) and how many woke more than 1 ms late (wakes_over_ms) or a whole tick late (wakes_over_tick).",
	)
	gd.bind_method(
		class,
		"level_marker",
		level_marker,
		{"index"},
		doc = "The shown level's marker node at [param index] (its index in the .level file: what a marker view's key names, [method Unified.level_markers]' order), or null.",
	)
	gd.bind_signal(
		class,
		"status_changed",
		{{"status", .INT, "UnifiedSession.Status"}, {"detail", .STRING, ""}},
		doc = "The session's status changed; [param detail] says why (a failure's reason).",
	)
	gd.bind_signal(
		class,
		"join_code_changed",
		{{"code", .STRING, ""}},
		doc = "[member join_code] changed: a host's code came, or went with its session.",
	)
	gd.bind_signal(
		class,
		"input_wanted",
		doc = "Every frame, just before the session samples the local player's input (at priority -1000, before every other node's [code]_process[/code]): set [code]Unified.input[/code]'s values here, whatever your node's priority, and this frame's sample takes them.",
	)
	gd.bind_signal(class, "link_slow_changed", {{"slow", .BOOL, ""}}, doc = "[member link_slow] changed.")
	gd.bind_signal(
		class,
		"save_changed",
		{{"setup", .OBJECT, SETUP_CLASS}},
		doc = "The game's save changed: [param setup] is the newest Setup that continues this session in a new one (Game.save, from a verified tick, so never a mispredicted one; src/sim/README.md, Saves), handed over with the frame shown (two saves verified between two frames come as the second). Every player gets it, so any of them can host the continuation: keep it ([method UnifiedSetup.to_json]) and pass it to a start method later.",
	)
	gd.bind_signal(
		class,
		"desync",
		{{"tick", .INT, ""}, {"detail", .STRING, ""}},
		doc = "The players' checksums of [param tick] differ.",
	)
	gd.bind_signal(
		class,
		"sim_event",
		{{"event", .OBJECT, "UnifiedEvent"}, {"state", .INT, "UnifiedSession.EventState"}},
		doc = "Every sim event in every state: EVENT_EMITTED once, then EVENT_CONFIRMED or EVENT_CANCELLED once. Its subject's view gets it first ([code]_sim_event(event, state)[/code]). Dispatch by class: [code]if event is EventRockHit: var hit := event as EventRockHit[/code].",
	)
	gd.bind_signal(
		class,
		"level_changing",
		{{"to", .INT, ""}},
		doc = "The verified level is now [param to] (an [EnumLevel] value) and its scene is loading (put up a loading view): the views hold until [signal level_changed]; the sim keeps ticking.",
	)
	gd.bind_signal(
		class,
		"level_changed",
		{{"level", .INT, ""}},
		doc = "[param level] is on screen ([member level]): its scene is under [member level_root], the old level's views are gone, and the views sync again.",
	)
	gd.bind_signal(
		class,
		"roster_changed",
		doc = "Who is in the session at the shown tick changed ([method get_players], [method get_known_players], [method get_player_slot]: a player joined, left or moved slots), or a player's name, connection or account did (the get_player_* methods): redraw a player list here.",
	)
	for name, status in STATUS_NAMES {
		gd.bind_constant(
			class,
			"Status",
			fmt.tprintf("STATUS_%s", strings.to_upper(name, context.temp_allocator)),
			i64(status),
			doc = STATUS_DOCS[status],
		)
	}
	for name, mode in MODE_NAMES do gd.bind_constant(class, "Mode", name, i64(mode), doc = MODE_DOCS[mode])
	gd.bind_constant(
		class,
		"",
		"DEVICE_ANY",
		DEVICE_ANY,
		doc = "A local player's device: every device, as one player plays (local player 0's, unless set).",
	)
	gd.bind_constant(
		class,
		"",
		"DEVICE_KEYBOARD",
		DEVICE_KEYBOARD,
		doc = "A local player's device: the keyboard and the mouse (a joypad is its id, 0 and up).",
	)
	gd.bind_constant(
		class,
		"",
		"LOCAL_MAX",
		LOCAL_MAX,
		doc = "The most local players one game has (couch co-op, guests of a remote-play stream).",
	)
	for name, state in EVENT_STATE_NAMES do gd.bind_constant(class, "EventState", name, i64(state), doc = EVENT_STATE_DOCS[state])
}

// The link's slow flag changed (Message.Link_Slow), or went with the session: link_slow_changed, and a mark in the dev
// UI's timeline.
@(private)
set_link_slow :: proc(session: ^Session_Node, slow: bool) {
	if session.link_slow == slow do return
	session.link_slow = slow
	if session.frame != nil do dev_note(session.frame.tick, slow ? "link slow" : "link fast again")
	gd.emit_signal(session.obj, gd.sn("link_slow_changed"), slow)
}

@(private)
STATUS_DOCS := [Status_Kind]string {
	.Idle         = "No session has started.",
	.Connecting   = "A session is starting: hosting, joining, or waiting for the previous one's goodbye.",
	.Connected    = "In the session.",
	.Failed       = "The session could not start or ended on an error ([code]detail[/code] says which).",
	.Disconnected = "The session ended without this player leaving: the host left or ended it, or the link was lost ([code]detail[/code] says which).",
	.Left         = "This player ended the session ([method leave]), from the menus, a tool or the dev UI.",
	.Recovering   = "In the session, the state being replaced: it diverged from the other players, or fell too far behind, and the host sends a majority player's snapshot (under a second for most games). The view holds; the player's input still counts. Then [constant STATUS_CONNECTED] again, or [constant STATUS_DISCONNECTED] when it can't be repaired.",
	.Reconnecting = "The link to the host was lost: the session holds the world and opens a new connection by itself (up to 30 s), then fast-forwards to the live tick and is [constant STATUS_CONNECTED] again, or ends [constant STATUS_DISCONNECTED]. Show a \"Reconnecting\" overlay; the player's place, member and progress are kept.",
}

// A path as the session thread reads files: user:// and res:// made absolute (main thread; temp-allocated).
@(private)
globalize :: proc(path: string) -> string {
	return gd.ProjectSettings_globalize_path(gd.ProjectSettings_singleton(), path)
}

@(private)
MODE_NAMES := [Mode]string {
	.Single      = "MODE_SINGLE",
	.Host_Online = "MODE_HOST_ONLINE",
	.Host_Direct = "MODE_HOST_DIRECT",
	.Join_Online = "MODE_JOIN_ONLINE",
	.Join_Direct = "MODE_JOIN_DIRECT",
	.Replay      = "MODE_REPLAY",
}

@(private)
MODE_DOCS := [Mode]string {
	.Single      = "Single player ([method start_single], [code]--autostart[/code]).",
	.Host_Online = "Hosting through the game's lobby service ([method host_online], [code]--host-online[/code]): [member join_code] is the lobby code.",
	.Host_Direct = "Hosting on a UDP port ([method host_direct], [code]--host-port[/code]): [member join_code] is this machine's address and the port.",
	.Join_Online = "Joining by a lobby code ([method join_online], [code]--join-code[/code]).",
	.Join_Direct = "Joining a host:port ([method join_direct], [code]--join[/code]).",
	.Replay      = "Replaying a recording ([method replay], [code]--replay[/code]).",
}

// The name a player goes by: theirs, else "P<slot + 1>" while they hold a slot ("" for one the session doesn't know).
@(private)
player_name :: proc(session: ^Session_Node, player: i64) -> string {
	if entry, ok := roster_entry(player); ok {
		if name := netcode.text_string(&entry.name); name != "" do return strings.clone(name, context.temp_allocator)
	}
	slot := shown_slot(session, player)
	return slot >= 0 ? fmt.tprintf("P%d", slot + 1) : ""
}

@(private)
EVENT_STATE_DOCS := [Event_Action]string {
	.Emitted   = "The first time any simulation of its tick produced it (a prediction, or the verified tick): effects and sounds.",
	.Confirmed = "Its tick is verified: what must be final (score, banners).",
	.Cancelled = "A re-simulation no longer produces it: undo the effect its EVENT_EMITTED started (the same [member UnifiedEvent.id]).",
}

// An empty Array[int] of player keys.
@(private)
player_array :: proc() -> gd.Array {
	array := gd.array_new()
	gd.array_set_typed(&array, .INT)
	return array
}

// An owned Array as a dynamic method's result (the Variant holds its own reference).
@(private)
array_variant :: proc(array: ^gd.Array) -> gd.Variant {
	value := gd.to_variant(array^)
	gd.Array_destroy(array)
	return value
}

// `--lag MS`: the dev netsim on remote links, MS each way, a quarter of it jitter, 1% loss.
@(private)
lag_settings :: proc(lag_ms: int) -> Netsim_Settings {
	ms := f32(lag_ms)
	return {true, {ms, ms / 4, 1}, {ms, ms / 4, 1}}
}

// The slot a player (by key) holds at the shown tick (-1: absent, unknown, or no frame yet).
@(private)
shown_slot :: proc(session: ^Session_Node, player: i64) -> int {
	if session.frame == nil || player == 0 do return -1
	for key, slot in session.frame.slots do if key == u64(player) do return slot
	return -1
}

@(private)
node_of :: proc(session: ^Session_Node) -> gd.Node {
	return gd.cast_to(gd.Node, session.obj)
}

// view_root as set (null, or a freed node: none); before it is set, the session's parent.
@(private)
view_root_of :: proc(session: ^Session_Node) -> gd.Node {
	if session.root_set do return alive(session.root_id) ? session.view_root : {}
	return gd.Node_get_parent(node_of(session))
}

// Where scene views go: view_root, unless it is outside the tree (its scene left: a play scene's teardown needs no
// code).
@(private)
effective_root :: proc(session: ^Session_Node) -> gd.Node {
	root := view_root_of(session)
	if root.ptr != nil && !gd.Node_is_inside_tree(root) do return {}
	return root
}

@(private)
alive :: proc(id: u64) -> bool {
	return id != 0 && gdi.object_get_instance_from_id(id) != nil
}

@(private)
session_ready :: proc(session: ^Session_Node) {
	if is_editor() do return // the editor shows scenes; the game never runs in it
	if active != nil && active != session {
		gd.print_warning("unified: a second UnifiedSession; only the first one runs")
		return
	}
	active = session
	gd.Node_set_process_priority(node_of(session), -1000) // views are written before any other _process
	gd.Node_set_process(node_of(session), true)
	if !session.args_read {
		session.args_read = true
		problems: []string
		session.args, problems = parse_args()
		if len(problems) > 0 {
			for problem in problems do gd.print_error(fmt.tprintf("unified: %s", problem))
			gd.SceneTree_quit(gd.Node_get_tree(node_of(session)), 2) // like uni: a bad command line runs nothing
			return
		}
		if session.args.seed != 0 do session.seed = session.args.seed
		if session.args.ticks != 0 do session.ticks = i64(session.args.ticks)
		session.quit_at_end = session.args.quit
		if session.args.lag_ms > 0 do set_netsim(lag_settings(session.args.lag_ms))
		if session.args.draw != "" do debug_draw_want(session.args.draw)
		if session.args.profile != "" && api.installed && D.profile != nil && D.profile.instance != nil {
			if problem := api.profile_text(D.profile.instance.bytes, session.args.profile); problem != "" {
				gd.print_error(fmt.tprintf("unified: --profile %s: %s", session.args.profile, problem))
				gd.SceneTree_quit(gd.Node_get_tree(node_of(session)), 2)
				return
			}
		}
		if session.args.control != "" && !control_open(session.args.control) {
			gd.SceneTree_quit(gd.Node_get_tree(node_of(session)), 2) // an agent asked for it: nothing to drive without it
			return
		}
		read_app_version()
	}
	dev_init(
		session.args.devui,
		session.args.lag_ms > 0 ? lag_settings(session.args.lag_ms) : {},
		session.args.verified_players,
	)
	switch {
	case session.args.autostart:
		session_start(session, {mode = .Single, scripted = session.args.scripted})
	case session.args.host_port != 0:
		session_start(session, {
			mode     = .Host_Direct,
			port     = session.args.host_port,
			scripted = session.args.scripted,
		})
	case session.args.join != "":
		session_start(session, {
			mode     = .Join_Direct,
			arg      = session.args.join,
			scripted = session.args.scripted,
		})
	case session.args.online:
		session_start(session, {mode = .Host_Online, scripted = session.args.scripted})
	case session.args.replay != "":
		session_start(session, {mode = .Replay, arg = globalize(session.args.replay)})
	case session.args.join_code != "":
		session_start(session, {
			mode     = .Join_Online,
			arg      = session.args.join_code,
			scripted = session.args.scripted,
		})
	}
	delete(session.args.join) // session_start keeps its own copy
	delete(session.args.join_code)
	delete(session.args.replay)
	session.args.replay = ""
	session.args.autostart, session.args.host_port, session.args.join, session.args.online, session.args.join_code =
		false, 0, "", false, ""
}

// UnifiedSession's open to friends: a running single-player session becomes a hosted one, nobody waits and no timer
// starts over (single player is a host with no remote links: netcode.host_add_link).
@(private)
bind_open_to_friends :: proc(class: ^gd.Class) {
	open :: proc(session: ^Session_Node, mode: Mode, port: int, method: string) -> bool {
		reason := ""
		switch {
		case !api.installed || !api.running() || session.status != .Connected:
			reason = "no single-player session is running"
		case session.mode != .Single && session.mode != mode:
			reason = "this session is not single player"
		case session.args.bench > 0:
			reason = "a --bench session's state is this process's alone"
		}
		if reason != "" {
			gd.print_error(fmt.tprintf("unified: %s: %s", method, reason))
			return false
		}
		return api.open(mode, port)
	}
	gd.bind_method(class, "open_online", proc(session: ^Session_Node) -> bool {
			return open(session, .Host_Online, 0, "open_online")
		}, doc = "Opens the running single-player session to friends through the game's lobby service: [member mode] becomes [constant MODE_HOST_ONLINE] and [member join_code] the code ([signal mode_changed], [signal join_code_changed]); the session goes on, nobody waits. False, with an error, when it isn't a running single-player session. A lobby that fails later closes again and the session plays on as single player ([signal mode_changed] says why).")
	gd.bind_method(class, "open_direct", proc(session: ^Session_Node, port: i64) -> bool {
			return open(session, .Host_Direct, int(port), "open_direct")
		}, {
			"port",
		}, doc = "Opens the running single-player session to friends on a UDP port (LAN): [member mode] becomes [constant MODE_HOST_DIRECT] and [member join_code] this machine's address and the port. A port that can't be opened leaves it single player ([signal mode_changed] says why).")
	gd.bind_method(class, "close_online", proc(session: ^Session_Node) -> bool {
			if !api.installed || !api.running() || session.mode == .Single do return false
			if session.mode != .Host_Online && session.mode != .Host_Direct do return false
			set_join_code(session, "")
			return api.open(.Single, 0)
		}, doc = "Lets nobody new into a hosted session, opened to friends or hosted from the start: the players in stay, and one who drops may come back; [member join_code] becomes \"\". Opening again the same way ([method open_online], [method open_direct]) lets new players in once more and shows the code again.")
	gd.bind_signal(
		class,
		"mode_changed",
		{{"mode", .INT, "UnifiedSession.Mode"}, {"detail", .STRING, ""}},
		doc = "[member mode] changed while the session ran (a single-player session opened to friends), or an open failed and it stays as it was: [param detail] says why.",
	)
}

// UnifiedSession's local players: several people on one machine (a couch, guests of a remote-play stream), each
// its own player with its own device, joining and leaving the running session on its own.
@(private)
bind_local_players :: proc(class: ^gd.Class) {
	gd.bind_dynamic_method(class, "add_local_player", proc(_: rawptr, _: rawptr, args: []^gd.Variant) -> gd.Variant {
			device, _ := gd.from_variant(i64, args[0])
			name, _ := gd.from_variant(string, args[1])
			profile_object, _ := gd.from_variant(gd.Object, args[2])
			if !api.installed || !api.running() do return gd.to_variant(i64(-1))
			local := -1
			for active, k in input_sample.active do if !active && local < 0 do local = k
			if local < 0 do return gd.to_variant(i64(-1))
			profile: [sim.PROFILE_MAX]u8
			explicit := false
			if D.profile != nil && D.profile.instance != nil do copy(profile[:], D.profile.instance.bytes)
			if profile_object.ptr != nil && D.profile != nil {
				if given := (^Data_Object)(gd.instance_of(profile_object, &D.profile.class)); given != nil {
					copy(profile[:], given.bytes)
					explicit = true
				}
			}
			if !api.local_player(local, true, name, profile[:], explicit) do return gd.to_variant(i64(-1))
			input_sample.active[local], input_sample.devices[local] = true, int(device)
			return gd.to_variant(i64(local))
		}, nil, {{"device", .INT, ""}, {"name", .STRING, ""}, {"profile", .OBJECT, PROFILE_CLASS}}, gd.Dynamic_Arg{"", .INT, ""}, doc = "Adds a local player to the running session, played on [param device] ([constant DEVICE_ANY], [constant DEVICE_KEYBOARD], a joypad's id), named [param name], arriving with [param profile] (null: [code]Unified.profile[/code]'s). Returns its local index (1 and up; 0 is the first player), or -1 when no session runs or [constant LOCAL_MAX] play already. It joins like a late joiner, without a snapshot; [signal local_players_changed] says when it is in.", defaults = {gd.to_variant(i64(DEVICE_ANY)), gd.to_variant(""), gd.variant_nil()})
	gd.bind_method(class, "remove_local_player", proc(session: ^Session_Node, local: i64) -> bool {
			if local <= 0 || local >= LOCAL_MAX || !input_sample.active[local] do return false
			input_sample.active[local], input_sample.devices[local] = false, DEVICE_ANY
			return api.installed && api.local_player(int(local), false, "", nil)
		}, {"local"}, doc = "Local player [param local] (1 and up) leaves: its player is gone from the next tick, the others play on. (The first player leaves with [method leave].)")
	gd.bind_dynamic_property(class, {"local_players", .ARRAY, "int"}, proc(_: rawptr, instance: rawptr, _: []^gd.Variant) -> gd.Variant {
			session := (^Session_Node)(instance)
			players := player_array()
			if session.frame != nil {
				for key in session.frame.local_players do if key != 0 do gd.array_push(&players, i64(key))
			}
			return array_variant(&players)
		}, nil, doc = "The keys of this game's players in the session at the shown tick, in local order (the first player's first), compacted: not indexed by local index ([method get_local_player_key] is).")
	gd.bind_dynamic_method(class, "get_local_indices", proc(_: rawptr, _: rawptr, _: []^gd.Variant) -> gd.Variant {
			indices := player_array()
			for active, local in input_sample.active do if active do gd.array_push(&indices, i64(local))
			return array_variant(&indices)
		}, nil, {}, gd.Dynamic_Arg{"", .ARRAY, "int"}, doc = "The local indices of this game's local players (0, then the ones [method add_local_player] added), whether or not they are in yet.")
	gd.bind_method(class, "get_local_player_key", proc(session: ^Session_Node, local: i64) -> i64 {
			if session.frame == nil || local < 0 || local >= LOCAL_MAX do return 0
			return i64(session.frame.local_players[local])
		}, {"local"}, doc = "Local player [param local]'s key at the shown tick (0: not in).")
	gd.bind_method(class, "get_local_index", proc(session: ^Session_Node, player: i64) -> i64 {
			if session.frame == nil || player == 0 do return -1
			for key, local in session.frame.local_players do if i64(key) == player do return i64(local)
			return -1
		}, {"player"}, doc = "Which local player [param player] is (-1: not one of this game's): which camera, HUD row or controller an event or a view is for.")
	gd.bind_method(class, "get_local_device", proc(session: ^Session_Node, local: i64) -> i64 {
			return i64(local_device(int(local)))
		}, {
			"local",
		}, doc = "Local player [param local]'s device ([constant DEVICE_ANY], [constant DEVICE_KEYBOARD], or a joypad's id).")
	gd.bind_method(class, "set_local_device", proc(session: ^Session_Node, local: i64, device: i64) {
			if local >= 0 && local < LOCAL_MAX do input_sample.devices[local] = int(device)
		}, {"local", "device"}, doc = "Plays local player [param local] on [param device] from the next sample: the action helpers read that device only (the first player starts on [constant DEVICE_ANY]: every device).")
	gd.bind_signal(
		class,
		"local_players_changed",
		doc = "A local player came into the session or left it ([member local_players]).",
	)
	gd.bind_signal(
		class,
		"local_player_refused",
		{{"local", .INT, ""}, {"reason", .STRING, ""}},
		doc = "The session refused local player [param local] ([method add_local_player]'s index; [param reason] says why: full, closed, ...): its index is free again, the other players play on.",
	)
}

// A start method's setup argument into the request: null leaves the game's default; a UnifiedSetup is copied, unless it
// does not read on this build (false, with an error naming `method`).
@(private)
setup_of :: proc(variant: ^gd.Variant, request: ^Start, method: string) -> bool {
	object, _ := gd.from_variant(gd.Object, variant)
	if object.ptr == nil do return true
	instance := D.setup != nil ? (^Data_Object)(gd.instance_of(object, &D.setup.class)) : nil
	if instance == nil {
		gd.print_error(fmt.tprintf("unified: %s: setup is not a %s", method, SETUP_CLASS))
		return false
	}
	if problem := api.setup_problem(instance.bytes); problem != "" {
		gd.print_error(fmt.tprintf("unified: %s: the setup %s", method, problem))
		return false
	}
	copy(request.setup[:], instance.bytes)
	request.has_setup = true
	return true
}

@(private)
session_start :: proc(session: ^Session_Node, request: Start) -> bool {
	if !api.installed {
		reason := "no game installed in this extension"
		if len(api.problems) > 0 do reason = fmt.tprintf("the game %s failed to install: %s", api.game_name, api.problems[0])
		emit_status(session, .Failed, reason)
		if session.quit_at_end {
			// a run that ends by itself (a headless check) has no result to wait for: say why and quit
			fmt.eprintfln("unified: no session: %s", reason)
			quit_when_quiet(session, 1)
		}
		return false
	}
	if api.running() {
		// Leave, then Host or Join at once: the left session is still saying goodbye (<= 1 s once hurried). The
		// new one starts when it is gone (session_process); its own messages are dropped meanwhile.
		if !api.stopping() || session.has_pending {
			emit_status(session, .Failed, "a session is already running")
			return false
		}
		session.pending = request
		session.pending.arg = strings.clone(request.arg)
		session.has_pending = true
		session.mode = request.mode
		api.hurry()
		emit_status(session, .Connecting, "")
		return true
	}
	return session_launch(session, request)
}

@(private)
session_launch :: proc(session: ^Session_Node, request: Start) -> bool {
	session.frame = nil // it points into the finished session, which wait frees
	session.ended, session.over = false, false
	session.saves_seen = 0
	api.wait() // a finished session's thread
	request := request
	if request.mode == .Single do request.bench = session.args.bench
	request.local = session.args.local_net
	request.seed = u64(session.seed)
	request.ticks = u32(max(session.ticks, 0))
	request.name = session.name
	request.token = client_token()
	if D.profile != nil && D.profile.instance != nil do copy(request.profile[:], D.profile.instance.bytes)
	request.profile_text = session.args.profile
	request.slot = -1
	if session.args.slot != "" {
		slot, slot_ok := strconv.parse_int(session.args.slot, 10)
		if !slot_ok || slot < 0 || slot >= sim.MAX_PLAYERS {
			emit_status(session, .Failed, fmt.tprintf("--slot %s: not a slot", session.args.slot))
			return false
		}
		request.slot = slot
	}
	if !request.has_setup && session.args.setup != "" {
		// the command line's (--setup): the game's default with its assignments
		copy(request.setup[:], api.setup_default)
		request.has_setup = true
		if problem := api.setup_text(request.setup[:len(api.setup_default)], session.args.setup); problem != "" {
			emit_status(session, .Failed, fmt.tprintf("--setup %s: %s", session.args.setup, problem))
			return false
		}
	}
	request.quit = session.quit_at_end
	when DEVUI {
		request.watchdog = !session.args.no_watchdog
		request.dumps = fmt.tprintf("%s/feedback", gd.OS_get_user_data_dir(gd.OS_singleton()))
	}
	views_check_index()
	data_reset()
	// A new session starts with local player 0 alone: the others join it with add_local_player.
	for local in 1 ..< LOCAL_MAX do input_sample.active[local], input_sample.devices[local] = false, DEVICE_ANY
	session.locals_seen = {}
	level_host_reset(&session.level)
	session.mode = request.mode
	set_join_code(session, "")
	dev_session_started()
	ok, err := api.start(request)
	if !ok {
		emit_status(session, .Failed, err)
		return false
	}
	emit_status(session, .Connecting, "")
	return true
}

@(private)
clear_pending :: proc(session: ^Session_Node) {
	if session.has_pending do delete(session.pending.arg)
	session.pending, session.has_pending = {}, false
}

// Starts the waiting session once the previous one has finished.
@(private)
start_pending :: proc(session: ^Session_Node) {
	if !session.has_pending || api.running() do return
	request := session.pending
	session.has_pending = false
	session.pending = {}
	defer delete(request.arg)
	session_launch(session, request)
}

@(private)
session_end :: proc(session: ^Session_Node) {
	clear_pending(session)
	if api.installed {
		api.hurry() // a goodbye of at most 1 s on the main thread, not 3 (an unreachable peer)
		api.stop()
		api.wait()
	}
	session.frame = nil
	data_reset()
}

// Ends the active session, joins its thread and frees every view and the dev UI. Called when the extension
// unloads (exit or hot reload): the session thread runs this library's code, so it must be gone first.
@(private)
session_shutdown_all :: proc() {
	if active != nil do session_end(active)
	if api.installed do api.wait()
	views_clear()
	dev_shutdown()
	active = nil
}

// The code others join this session with (join_code), and join_code_changed when it changes.
@(private)
set_join_code :: proc(session: ^Session_Node, code: string) {
	if code == session.join_code do return
	delete(session.join_code)
	session.join_code = strings.clone(code)
	gd.emit_signal(session.obj, gd.sn("join_code_changed"), code)
}

@(private)
emit_status :: proc(session: ^Session_Node, status: Status_Kind, detail: string) {
	if status == session.status && detail == session.detail do return
	session.status = status
	delete(session.detail)
	session.detail = strings.clone(detail)
	gd.emit_signal(session.obj, gd.sn("status_changed"), i64(status), detail)
}

// UnifiedSession.leave: the waiting session never starts; the running one says goodbye on its thread.
@(private)
session_leave :: proc(session: ^Session_Node) {
	if session.has_pending {
		clear_pending(session)
		emit_status(session, .Left, "")
	}
	if api.installed do api.stop()
}

@(private)
session_process :: proc(session: ^Session_Node, dt: f64) {
	if is_editor() || active != session do return
	if quit_step(session) do return // the run ended and the app quits once its sounds are stopped
	level_host_collect(&session.level, wait = false)
	dev_begin()
	input_sample_begin(dev_wants_keyboard())
	if api.installed {
		gd.emit_signal(session.obj, gd.sn("input_wanted")) // scripts set Unified.input for this very sample
		api.sample_input()
	}
	if lobby != nil && lobby.main_frame != nil && api.running() do lobby.main_frame()
	started := time.tick_now()
	// the newest frame: views first, then the events of the ticks it covers
	fresh := false
	if api.installed && !session.over {
		session.frame, fresh = api.front()
		session.over = session.ended
	} else {
		session.frame = nil
	}
	now := time.tick_now()
	if session.frame != nil {
		frame := session.frame
		session.last_tick = frame.tick
		tick_us := frame.tick_us != 0 ? frame.tick_us : i64(1_000_000 / max(frame.tick_hz, 1))
		alpha := alpha(now._nsec / 1000, frame.due_us, tick_us)
		root := effective_root(session)
		root_id := root.ptr != nil ? gdi.object_get_instance_id(root.ptr) : 0
		if root_id != session.synced_root {
			views_root_changed() // the views lived under the old root
			session.synced_root = root_id
			view_space_check(root)
		}
		if !level_host_process(session, frame) do views_sync(root, frame, fresh, alpha, f32(dt))
		debug_draw_sync(root, frame, fresh)
		if fresh && !session.ended do data_sync(frame) // data went back to zero at the Result
	}
	delivering := time.tick_now()
	drain_events(session)
	V.stats.delivery += time.tick_since(delivering)
	drain_messages(session)
	// The relay's roster and who the shown tick has present come apart: a joiner's roster entry arrives ticks before
	// the tick that seats them is on screen, so either one changing is a roster change.
	roster_moved := false
	if changes := sync.atomic_load(&roster.changes); changes != session.roster_seen {
		session.roster_seen = changes
		roster_moved = true
	}
	if frame := session.frame;
	   frame != nil && (frame.slots != session.slots_seen || frame.n_members != session.known_seen) {
		session.slots_seen, session.known_seen = frame.slots, frame.n_members
		roster_moved = true
	}
	if roster_moved do gd.emit_signal(session.obj, gd.sn("roster_changed"))
	if frame := session.frame; frame != nil && frame.saves != session.saves_seen && D.setup != nil {
		session.saves_seen = frame.saves
		save := nested_variant(D.setup, frame.save[:D.setup.layout.type.size], .View)
		gd.emit_signal(session.obj, gd.sn("save_changed"), save)
		gdi.variant_destroy(&save)
	}
	if session.frame != nil && session.frame.local_players != session.locals_seen {
		session.locals_seen = session.frame.local_players
		gd.emit_signal(session.obj, gd.sn("local_players_changed"))
	}
	start_pending(session)
	took := time.tick_since(started)
	session.sync_us = f32(time.duration_microseconds(took))
	if session.frame != nil {
		V.stats.frames += 1
		V.stats.fresh += fresh ? 1 : 0
		V.stats.total += took
		V.stats.total_max = max(V.stats.total_max, took)
	}
	sync.atomic_store(&want_state, dev_wants_state() || control_listening())
	dev_frame(session, dt)
	control_poll(session) // last: a reply sees this frame's views and events
}

// Delivers the queued events of the ticks the shown Frame covers (tick <= its tick), in order; newer ones wait for the
// frame that shows their tick, so an event never reaches a view before the view's tick is on screen.
@(private)
drain_events :: proc(session: ^Session_Node) {
	if !api.installed do return
	for session.frame != nil {
		event := api.next_event(session.frame.tick) or_break
		if !session.has_pending do route_event(session, event) // else: the left session's; the new one is connecting
	}
	if dropped := api.events_dropped(); dropped > 0 {
		report_once(
			"events-dropped",
			fmt.tprintf(
				"unified: %d events were dropped: the main thread stalled while the session thread queued more than it holds",
				dropped,
			),
			false,
		)
	}
}

@(private)
drain_messages :: proc(session: ^Session_Node) {
	if !api.installed do return
	for {
		message, ok := api.pop()
		if !ok do break
		text := string(message.text[:message.len])
		if session.has_pending && message.kind != .Result do continue // the left session's last words; the new one is connecting
		switch message.kind {
		case .Status:
			emit_status(session, message.status, text)
			if message.status == .Failed && session.quit_at_end && session.mode == .Replay {
				// a replay that can't start has no result to wait for: say why and quit (a tool run fails)
				fmt.eprintfln("unified: the replay failed: %s", text)
				quit_when_quiet(session, 1)
			}
		case .Join_Code:
			fmt.printfln("unified: join code %s", text)
			set_join_code(session, text)
		case .Local_Refused:
			local := int(message.local)
			fmt.printfln("unified: local player %d refused: %s", local, text)
			if local > 0 && local < LOCAL_MAX do input_sample.active[local], input_sample.devices[local] = false, DEVICE_ANY
			gd.emit_signal(session.obj, gd.sn("local_player_refused"), i64(local), text)
		case .Desync:
			fmt.printfln("unified: desync at tick %d: %s", message.tick, text)
			dev_note(message.tick, fmt.tprintf("desync: %s", text))
			gd.emit_signal(session.obj, gd.sn("desync"), i64(message.tick), text)
		case .Mode:
			if text != "" do fmt.printfln("unified: %s", text)
			session.mode = message.mode
			gd.emit_signal(session.obj, gd.sn("mode_changed"), i64(message.mode), text)
		case .Link_Slow:
			set_link_slow(session, message.tick != 0)
		case .Result:
			fmt.printfln("unified: result %s", api.result())
			dev_save_recording(session)
			if !session.has_pending {
				set_link_slow(session, false)
				data_reset()
				set_join_code(session, "")
				session.ended = true
			}
			if session.quit_at_end do quit_when_quiet(session, 0)
		}
	}
}

// An event in one of its states (EVENT_EMITTED, then EVENT_CONFIRMED or EVENT_CANCELLED), as an object of its
// class (sim_classes.odin): to the subject's view (_sim_event(event, state)), then to the sim_event signal, in the
// order the ticks emitted them.
@(private)
route_event :: proc(session: ^Session_Node, message: Event_Message) {
	raw := message.event
	if int(raw.kind) >= len(api.events) do return // another build's event: never from this game's sim
	layout := &api.events[raw.kind]
	event := new_event_object(int(raw.kind), message.tick, message.id, raw.data[:raw.size])
	if event.ptr == nil do return // its class failed to register (an error said why)
	// the Variant holds a reference and ours goes: the event is freed with the Variant unless a script kept it
	held := gd.variant_from_any(event)
	defer gd.variant_destroy(&held)
	gd.unref(transmute(gd.RefCounted)event)
	state := i64(message.action)
	V.stats.events += 1
	views_event(layout, &raw, state, held)
	gd.emit_signal(session.obj, NAMES.sim_event, held, state)
	dev_event(message.tick, message.id, message.action, layout, raw.data[:raw.size])
	control_event(message.tick, message.id, message.action, int(raw.kind), layout, raw.data[:raw.size])
}

// The view sync's cost since the last call, and starts counting anew. The main thread's (Sync_Stats): `frames` and
// `fresh` (frames that showed a new tick), `events` (deliveries), and in microseconds summed over the frames
// `scene_us`, `multi_build_us`, `multi_upload_us`, `delivery_us`, `total_us`, plus the slowest frame's
// `total_max_us`. The session thread's frame hook (its events tracked, fill_frame, the Frame published): `fills`,
// `fill_us` summed and the slowest `fill_max_us`; its sleeps' lateness (`wakes`, `wake_p50_us`, `wake_p99_us`,
// `wake_max_us`, `wakes_over_ms`, `wakes_over_tick`: godot.Wake_Summary).
@(private)
take_sync_stats :: proc(session: ^Session_Node) -> gd.Dictionary {
	stats := V.stats
	V.stats = {}
	us :: time.duration_microseconds
	dict := gd.dict_new()
	gd.dict_set(&dict, "frames", i64(stats.frames))
	gd.dict_set(&dict, "fresh", i64(stats.fresh))
	gd.dict_set(&dict, "events", i64(stats.events))
	gd.dict_set(&dict, "scene_us", us(stats.scene))
	gd.dict_set(&dict, "multi_build_us", us(stats.multi_build))
	gd.dict_set(&dict, "multi_upload_us", us(stats.multi_upload))
	gd.dict_set(&dict, "delivery_us", us(stats.delivery))
	gd.dict_set(&dict, "total_us", us(stats.total))
	gd.dict_set(&dict, "total_max_us", us(stats.total_max))
	fill := api.take_fill_stats() if api.installed else {}
	gd.dict_set(&dict, "fills", i64(fill.frames))
	gd.dict_set(&dict, "fill_us", f64(fill.total_ns) / 1000)
	gd.dict_set(&dict, "fill_max_us", f64(fill.max_ns) / 1000)
	wakes := api.take_wake_stats() if api.installed else {}
	gd.dict_set(&dict, "wakes", i64(wakes.wakes))
	gd.dict_set(&dict, "wake_p50_us", wakes.p50_us)
	gd.dict_set(&dict, "wake_p99_us", wakes.p99_us)
	gd.dict_set(&dict, "wake_max_us", wakes.max_us)
	gd.dict_set(&dict, "wakes_over_ms", i64(wakes.over_ms))
	gd.dict_set(&dict, "wakes_over_tick", i64(wakes.over_tick))
	return dict
}

// ---- command line (user args after `--`)

@(private)
parse_args :: proc() -> (args: Args, problems: []string) {
	list := gd.OS_get_cmdline_user_args(gd.OS_singleton())
	defer gd.PackedStringArray_destroy(&list)
	count := int(gd.PackedStringArray_size(&list))
	user_args := make([]string, count, context.temp_allocator)
	for i in 0 ..< count {
		user_args[i] = gd.string_to_odin(cast(^gd.String)gdi.packed_string_array_operator_index(&list, i64(i)))
	}
	ignored: []string
	args, problems, ignored = parse_command_line(user_args, DEVUI)
	for flag in ignored {
		gd.print_warning(fmt.tprintf("unified: %s is a dev flag; this build has no dev UI and ignores it", flag))
	}
	return
}

// What a flag of unified:godot's sets in Args: a bool (no value), an int or i64 in [low, high], or a string (cloned;
// empty is a problem when the flag names what it wants).
@(private)
Flag_Kind :: enum u8 {
	Switch,
	Int,
	I64,
	Text,
}

// One flag unified:godot reads: whether it is a dev flag (a build without the dev UI ignores it) and the Args field it
// sets.
@(private)
Flag :: struct {
	name:      string,
	dev:       bool,
	kind:      Flag_Kind,
	field:     uintptr, // offset_of(Args, ...)
	low, high: i64, // .Int, .I64
	wants:     string, // .Text: what an empty value is told it wants ("": any value)
}

// The flags unified:godot reads, one row each. Every other flag on the command line belongs to the game or a tool
// script, which share it.
@(private)
FLAGS := [?]Flag {
	{"--autostart", false, .Switch, offset_of(Args, autostart), 0, 0, ""},
	{"--host-port", false, .Int, offset_of(Args, host_port), 1, 65535, ""},
	{"--join", false, .Text, offset_of(Args, join), 0, 0, "host:port"},
	{"--host-online", false, .Switch, offset_of(Args, online), 0, 0, ""},
	{"--join-code", false, .Text, offset_of(Args, join_code), 0, 0, "a code"},
	{"--local-net", false, .Switch, offset_of(Args, local_net), 0, 0, ""},
	{"--quit-at-end", false, .Switch, offset_of(Args, quit), 0, 0, ""},
	{"--scripted", true, .Switch, offset_of(Args, scripted), 0, 0, ""},
	{"--ticks", false, .Int, offset_of(Args, ticks), 0, 1 << 31 - 1, ""},
	{"--seed", true, .I64, offset_of(Args, seed), min(i64), max(i64), ""},
	{"--devui", true, .Switch, offset_of(Args, devui), 0, 0, ""},
	{"--lag", true, .Int, offset_of(Args, lag_ms), 0, 10_000, ""},
	{"--bench", true, .Int, offset_of(Args, bench), 0, 1 << 31 - 1, ""},
	{"--draw", true, .Text, offset_of(Args, draw), 0, 0, ""},
	{"--replay", true, .Text, offset_of(Args, replay), 0, 0, ""},
	{"--no-watchdog", true, .Switch, offset_of(Args, no_watchdog), 0, 0, ""},
	{"--verified-players", true, .Switch, offset_of(Args, verified_players), 0, 0, ""},
	{"--control", true, .Text, offset_of(Args, control), 0, 0, "a file for the port"},
	{"--setup", false, .Text, offset_of(Args, setup), 0, 0, "key=value[,key=value]"},
	{"--profile", false, .Text, offset_of(Args, profile), 0, 0, "key=value[,key=value]"},
	{"--slot", true, .Text, offset_of(Args, slot), 0, 0, "a slot (0 ..)"},
}

// Reads unified:godot's flags from the user args (after `--`; strings are cloned or temp-allocated). `problems`:
// a missing or bad value of one of its flags, or a near miss of one of its names (`--tiks`), each a line to report
// before quitting; any other flag is the game's. Without the dev UI (`dev_flags` false) the dev flags are `ignored`.
parse_command_line :: proc(
	user_args: []string,
	dev_flags: bool,
) -> (
	args: Args,
	problems: []string,
	ignored: []string,
) {
	found_problems := make([dynamic]string, context.temp_allocator)
	found_ignored := make([dynamic]string, context.temp_allocator)
	number :: proc(problems: ^[dynamic]string, flag: Flag, text: string) -> i64 {
		value, ok := strconv.parse_i64(text)
		if !ok || value < flag.low || value > flag.high {
			append(
				problems,
				fmt.tprintf("%s wants a whole number from %d to %d, got %q", flag.name, flag.low, flag.high, text),
			)
		}
		return value
	}
	for i := 0; i < len(user_args); i += 1 {
		arg := user_args[i]
		flag_index := -1
		for flag, k in FLAGS do if flag.name == arg do flag_index = k
		if flag_index < 0 {
			name := arg
			if eq := strings.index_byte(arg, '='); eq > 0 do name = arg[:eq]
			if !strings.has_prefix(name, "--") do continue // a value of the game's flags
			for flag in FLAGS {
				if name == flag.name {
					append(&found_problems, fmt.tprintf("%s: write %s VALUE", arg, flag.name))
				} else if near_miss(name, flag.name) {
					append(&found_problems, fmt.tprintf("unknown flag %s: did you mean %s?", arg, flag.name))
				}
			}
			continue
		}
		flag := FLAGS[flag_index]
		value := ""
		if flag.kind != .Switch {
			if i + 1 < len(user_args) {
				i += 1
				value = user_args[i]
			}
		}
		if flag.dev && !dev_flags {
			append(&found_ignored, flag.name)
			continue
		}
		field := rawptr(uintptr(&args) + flag.field)
		switch flag.kind {
		case .Switch:
			(^bool)(field)^ = true
		case .Int:
			(^int)(field)^ = int(number(&found_problems, flag, value))
		case .I64:
			(^i64)(field)^ = number(&found_problems, flag, value)
		case .Text:
			if value == "" && flag.wants != "" do append(&found_problems, fmt.tprintf("%s wants %s", flag.name, flag.wants))
			(^string)(field)^ = strings.clone(value)
		}
	}
	return args, found_problems[:], found_ignored[:]
}

// Whether `name` is one edit (insert, delete, replace, or swap of neighbours) from `flag`, or two for flags of seven
// letters or more: a mistyped flag of ours, not some other flag (our flags share the command line with the game's, so
// an unknown flag can't simply be refused). Flags under four letters match only exactly (the
// games' `--lan` is one edit from `--lag`).
@(private)
near_miss :: proc(name, flag: string) -> bool {
	letters := len(flag) - 2
	if letters < 4 do return false
	limit := letters >= 7 ? 2 : 1
	if abs(len(name) - len(flag)) > limit do return false
	// optimal string alignment distance, rows of at most 32 characters (flag names are short)
	if len(name) > 31 || len(flag) > 31 do return false
	rows: [3][32]int // row i (of name's prefix length i) is rows[(i + 1) % 3]
	for j in 0 ..= len(flag) do rows[1][j] = j
	for i in 1 ..= len(name) {
		before, previous, current := &rows[(i + 2) % 3], &rows[i % 3], &rows[(i + 1) % 3]
		current[0] = i
		for j in 1 ..= len(flag) {
			cost := name[i - 1] == flag[j - 1] ? 0 : 1
			current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
			if i > 1 && j > 1 && name[i - 1] == flag[j - 2] && name[i - 2] == flag[j - 1] {
				current[j] = min(current[j], before[j - 2] + 1)
			}
		}
	}
	return rows[(len(name) + 1) % 3][len(flag)] <= limit
}
