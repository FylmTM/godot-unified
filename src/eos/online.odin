// Online play through EOS: one process-wide session (the EOS platform is per process). The flow:
//
//   init       load the SDK library next to the game, EOS_Initialize, create the platform
//   open_host  device-ID login -> create a lobby (the game's player count) with a random code attribute -> Ready;
//              returns a netcode.Link over P2P (peers 1.. = joiners) that carries nothing until Ready
//   open_join  device-ID login -> search the lobby by code -> join -> host = lobby owner -> Ready; the link's
//              peer 0 is the host
//   close      destroy/leave the lobby, close P2P connections -> Idle (login is kept)
//
// Every EOS call happens under one mutex, from whichever thread calls `pump` or uses the link; EOS callbacks run
// inside Platform_Tick, so they never lock. Callbacks build a fresh context on the thread that ticks (a session thread
// may be gone by the next session). The thread running the netcode drives EOS (the link's recv ticks the platform,
// `pump` too). Status is read with `status`, from any thread. lobby.odin makes these a netcode.Lobby. What the package
// and the SDK say goes to the logger of the context `init` ran in (stderr when it set none).
package eos

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:time"

import "unified:netcode"

// Which side of a session this process is on.
Role :: enum u8 {
	None,
	Host,
	Join,
}

// Where the session stands (Status.stage; pump maps it onto netcode.Lobby_Stage).
Stage :: enum u8 {
	Off, // not initialized (or the SDK failed to load)
	Idle, // initialized, no session
	Login, // device-ID login in flight
	Lobby, // creating, searching or joining the lobby
	Ready, // host: lobby open, code set; joiner: in the lobby, host known
	Failed, // see detail; `close` returns to Idle
}

@(private)
MAX_REMOTES :: netcode.MAX_PEERS // a host's peers 1.. (a joiner's peer 0 is its host)
@(private)
TICK_EVERY_US :: 500 // the link ticks EOS at most this often when it finds no packet
@(private)
SOCKET_PREFIX :: "unified-"
@(private)
SEARCH_TRIES :: 5 // a just-created lobby can take a second or two to show up in searches
@(private)
SEARCH_RETRY_US :: 1_200_000
// A joiner whose P2P connection to the host isn't up this long after joining (or after its last
// try) closes it and asks again; after CONNECT_TRIES it fails. EOS's signalling sometimes delivers
// the host's offer to the joiner only after ~30 s: a fresh request gets a fresh offer.
@(private)
CONNECT_WAIT_US :: 5_000_000
CONNECT_TRIES :: 4

// A P2P peer of the session: the host's joiners at 1.., a joiner's host at 0.
Remote :: struct {
	used:      bool,
	id:        Product_User_Id,
	id_str:    [PRODUCTUSERID_MAX_LENGTH + 1]u8,
	network:   Network_Connection_Type,
	connected: bool,
	forgotten: bool, // host: closed by link_forget; its close notification is ours, not news for the netcode
	heard:     bool, // a packet came in on this connection since it came up
	// Host: the netcode got a packet from this peer and hasn't forgotten it since (link_forget). A remote whose user
	// left the lobby is freed once the netcode doesn't know it: its number goes to the next new user.
	known:     bool,
}

// What keeps builds apart (netcode.Lobby_Build). Lobbies are found per game (the bucket is the game's name); the
// host publishes its build and readable version as lobby attributes, and a joiner on another build is told so
// instead of joining. The lobby's member limit is the game's player count.
Build :: netcode.Lobby_Build

// EOS packets carry 1170 bytes: a netcode datagram always fits one, so datagrams go as they are.
P2P_MAX_PACKET :: 1170 // EOS_P2P_MAX_PACKET_SIZE
#assert(netcode.MAX_DATAGRAM <= P2P_MAX_PACKET)

// The `build` attribute of a lobby: the compat and the netcode protocol version.
build_id :: proc(compat: u64, allocator := context.temp_allocator) -> string {
	return fmt.aprintf("%016x-p%d", compat, netcode.PROTOCOL_VERSION, allocator = allocator)
}

// A user the host knows by id: a lobby member it saw join, or a connection request it holds until the user
// joins (P2P is accepted from lobby members only).
User :: struct {
	used:   bool,
	id:     Product_User_Id,
	id_str: [PRODUCTUSERID_MAX_LENGTH + 1]u8,
}

@(private)
HELD_REQUESTS :: 8 // connection requests from users not (yet) seen in the lobby; the oldest is dropped

// How init starts EOS. A game passes these through Lobby_Config (eos.lobby); tests call init with a fake SDK.
Init_Options :: struct {
	lib_dirs:            []string, // where to look for the SDK library; empty = default_lib_dirs()
	product_name:        string,
	product_version:     string,
	cache_dir:           string, // EOS cache; empty = <tmp>/unified-eos
	relay_control:       Maybe(Relay_Control), // default Allow_Relays
	// macOS: fail instead of asking the user when the stored device ID belongs to another build of
	// the program (headless tools; a dialog would block the session thread until answered). Games
	// leave it off: the player allows access once per build (never for runs inside Godot.app,
	// whose signature is stable).
	no_keychain_prompts: bool,
	// Tests: use these entry points instead of loading the SDK library (no credentials needed).
	sdk:                 ^Api,
	// Tests: how long a joiner waits for its P2P connection before asking again (0: CONNECT_WAIT_US).
	connect_wait_us:     i64,
}

// The process-wide session's state (one per process, as the EOS platform is): every field is read and written
// under `mu`. Callers go through the procs, never through this.
Online :: struct {
	mu:             sync.Mutex,
	api:            Api,
	platform:       H_Platform,
	connect:        H_Connect,
	p2p:            H_P2P,
	lobby:          H_Lobby,
	relay_control:  Relay_Control,
	stage:          Stage,
	role:           Role,
	detail:         [320]u8,
	detail_len:     int,
	lib_path:       [512]u8,
	// login
	local:          Product_User_Id,
	local_str:      [PRODUCTUSERID_MAX_LENGTH + 1]u8,
	login_busy:     bool,
	device_tries:   int,
	fresh_device:   bool,
	notify_auth:    Notification_Id,
	notify_member:  Notification_Id,
	// session
	bucket:         [64]u8, // the game's name
	build_id:       [40]u8, // build_id(compat)
	version:        [64]u8,
	code:           Code,
	lobby_id:       [128]u8,
	in_lobby:       bool,
	host:           Product_User_Id,
	socket:         P2P_Socket_Id,
	notify_req:     Notification_Id,
	notify_est:     Notification_Id,
	notify_closed:  Notification_Id,
	remotes:        [MAX_REMOTES]Remote,
	members:        [netcode.MAX_PEERS]User, // host: the lobby's members it saw join (P2P is accepted from them only)
	max_members:    int, // the lobby's limit: the game's player count
	held:           [HELD_REQUESTS]User, // host: connection requests waiting for their user to join the lobby
	held_next:      int, // the held slot the next request takes (a ring: a stranger can't pin a slot)
	last_tick_us:   i64,
	sent, received: int,
	send_errors:    int,
	gen:            u32, // session generation: callbacks of an abandoned session are recognized by it
	searches:       int, // lobby searches made for this join (a new lobby takes a moment to be found)
	search_at_us:   i64, // when to search again (0: not scheduled)
	relogin_at_us:  i64, // when to retry a failed token refresh (0: not scheduled)
	connect_wait:   i64, // CONNECT_WAIT_US, or the test's
	connect_at_us:  i64, // joiner: when to give up on this P2P connection try (0: connected or not joined)
	connect_tries:  int, // joiner: P2P connection tries to the host in this session
	joined_us:      i64, // joiner: when it joined the lobby
	events:         [32]Link_Event,
	n_events:       int,
}

// A transport-level event for netcode.Link.event.
Link_Event :: struct {
	peer:      netcode.Peer,
	connected: bool,
}

@(private)
session: Online

// --- public API ---------------------------------------------------------------------------------

// The directories searched for the SDK library when none are given: $UNIFIED_EOS_LIB_DIR, the
// executable's directory (and ../Frameworks on macOS, where an exported .app keeps it), then the SDK
// $UNIFIED_EOS_SDK names (its SDK/Bin: tests and headless tools on a developer's machine).
@(private)
default_lib_dirs :: proc(allocator := context.temp_allocator) -> []string {
	dirs := make([dynamic]string, allocator)
	if dir := os.get_env("UNIFIED_EOS_LIB_DIR", allocator); dir != "" {
		append(&dirs, dir)
	}
	if exe, err := os.get_executable_directory(allocator); err == nil {
		append(&dirs, exe)
		when ODIN_OS == .Darwin {
			frameworks, _ := filepath.join({exe, "..", "Frameworks"}, allocator)
			append(&dirs, frameworks)
		}
	}
	if sdk := os.get_env("UNIFIED_EOS_SDK", allocator); sdk != "" {
		if filepath.base(sdk) != "SDK" do sdk, _ = filepath.join({sdk, "SDK"}, allocator)
		bin, _ := filepath.join({sdk, "Bin"}, allocator)
		append(&dirs, bin)
	}
	return dirs[:]
}

// Loads the SDK and creates the platform. Safe to call again (returns the first result). On
// failure, `status` says why and online play stays off. The first call's context.logger takes every line the package
// and the SDK log from then on, on any thread (none set: stderr), so it must outlive the platform (shutdown).
init :: proc(opts: Init_Options) -> bool {
	online := &session
	sync.guard(&online.mu)
	if online.stage != .Off {
		return true
	}
	eos_logger = context.logger
	if online.platform != nil || online.detail_len > 0 {
		return false // a previous init failed
	}
	online.relay_control = opts.relay_control.? or_else .Allow_Relays
	online.connect_wait = opts.connect_wait_us > 0 ? opts.connect_wait_us : CONNECT_WAIT_US
	// $UNIFIED_EOS_RELAYS=force|none overrides the default (testing relays from a game build).
	switch os.get_env("UNIFIED_EOS_RELAYS", context.temp_allocator) {
	case "force":
		online.relay_control = .Force_Relays
	case "none":
		online.relay_control = .No_Relays
	}
	if opts.no_keychain_prompts {
		disable_keychain_prompts()
	}
	dirs := opts.lib_dirs
	if len(dirs) == 0 && opts.sdk == nil {
		dirs = default_lib_dirs()
	}
	loaded := false
	if opts.sdk != nil {
		online.api = opts.sdk^
		copy(online.lib_path[:len(online.lib_path) - 1], "(test SDK)")
		loaded = true
		dirs = nil
	}
	for dir in dirs {
		path, _ := filepath.join({dir, LIB_NAME}, context.temp_allocator)
		if !os.exists(path) {
			continue
		}
		if api_load(&online.api, path) {
			copy(online.lib_path[:len(online.lib_path) - 1], path)
			loaded = true
			break
		}
		set_detail(online, "%s: cannot load it or a symbol is missing (SDK too old?)", path)
		return false
	}
	if !loaded {
		set_detail(online, "%s not found (looked in %s)", LIB_NAME, strings.join(dirs, ", ", context.temp_allocator))
		return false
	}

	creds := credentials_load(context.temp_allocator)
	if !credentials_complete(creds) && opts.sdk == nil {
		set_detail(online, "EOS credentials missing (compiled in, or UNIFIED_EOS_* in the environment or .env)")
		return false
	}

	init_options := Initialize_Options {
		api_version     = INITIALIZE_API_LATEST,
		product_name    = strings.clone_to_cstring(
			opts.product_name != "" ? opts.product_name : "unified",
			context.temp_allocator,
		),
		product_version = strings.clone_to_cstring(
			opts.product_version != "" ? opts.product_version : "0",
			context.temp_allocator,
		),
	}
	if result := online.api.Initialize(&init_options); result != .Success && result != .AlreadyConfigured {
		set_detail(online, "EOS_Initialize: %s", online.api.EResult_ToString(result))
		return false
	}
	online.api.Logging_SetCallback(on_log)
	online.api.Logging_SetLogLevel(LC_ALL_CATEGORIES, log_level_from_env())

	cache := opts.cache_dir
	if cache == "" {
		cache, _ = filepath.join(
			{os.temp_directory(context.temp_allocator) or_else ".", "unified-eos"},
			context.temp_allocator,
		)
	}
	_ = os.make_directory_all(cache)
	platform_options := Platform_Options {
		api_version = PLATFORM_OPTIONS_API_LATEST,
		product_id = strings.clone_to_cstring(creds.product_id, context.temp_allocator),
		sandbox_id = strings.clone_to_cstring(creds.sandbox_id, context.temp_allocator),
		deployment_id = strings.clone_to_cstring(creds.deployment_id, context.temp_allocator),
		client_credentials = {
			client_id     = strings.clone_to_cstring(creds.client_id, context.temp_allocator),
			client_secret = strings.clone_to_cstring(creds.client_secret, context.temp_allocator),
		},
		flags = PF_DISABLE_OVERLAY | PF_DISABLE_SOCIAL_OVERLAY,
		cache_directory = strings.clone_to_cstring(cache, context.temp_allocator),
	}
	online.platform = online.api.Platform_Create(&platform_options)
	if online.platform == nil {
		online.api.Shutdown() // EOS_Initialize succeeded: undo it
		set_detail(online, "EOS_Platform_Create failed (check the IDs in the credentials)")
		return false
	}
	online.connect = online.api.Platform_GetConnectInterface(online.platform)
	online.p2p = online.api.Platform_GetP2PInterface(online.platform)
	online.lobby = online.api.Platform_GetLobbyInterface(online.platform)
	relay_options := P2P_Set_Relay_Control_Options {
		api_version   = P2P_SETRELAYCONTROL_API_LATEST,
		relay_control = online.relay_control,
	}
	online.api.P2P_SetRelayControl(online.p2p, &relay_options)
	online.fresh_device = os.get_env("UNIFIED_EOS_FRESH_DEVICE", context.temp_allocator) == "1"
	online.stage = .Idle
	online.detail_len = 0
	return true
}

// Starts hosting: login if needed, then a lobby of `build.game` with a fresh code and the build's attributes.
// Pump until Ready, then read the code.
@(private)
host :: proc(build: Build) -> bool {
	return begin(.Host, build, {})
}

// Starts joining the lobby with `code` (as typed: case and dashes don't matter). A lobby of another build fails
// the join with a message naming both versions.
@(private)
join :: proc(build: Build, code: string) -> bool {
	game_code, ok := code_parse(code)
	if !ok {
		online := &session
		sync.guard(&online.mu)
		set_detail(online, "%q is not a game code (6 letters and digits)", code)
		return false
	}
	return begin(.Join, build, game_code)
}

// A copy of where the session stands, for a game's UI and the tools (status).
Status :: struct {
	stage:   Stage,
	role:    Role,
	code:    string, // host or joiner, once known
	detail:  string, // why it failed, or what it is doing
	local:   string, // our Product User ID
	host:    string, // the host's Product User ID (joiner)
	network: Network_Connection_Type, // joiner: how the P2P connection to the host goes
	peers:   int, // connected P2P peers
	lib:     string,
}

// A snapshot of the session, safe from any thread; strings are allocated with `allocator`.
status :: proc(allocator := context.temp_allocator) -> (snapshot: Status) {
	online := &session
	sync.guard(&online.mu)
	snapshot.stage = online.stage
	snapshot.role = online.role
	if online.role != .None && online.code[0] != 0 {
		snapshot.code = strings.clone(string(online.code[:]), allocator)
	}
	snapshot.detail = strings.clone(string(online.detail[:online.detail_len]), allocator)
	snapshot.local = strings.clone(cstr(online.local_str[:]), allocator)
	snapshot.lib = strings.clone(cstr(online.lib_path[:]), allocator)
	for &remote, i in online.remotes {
		if !remote.used {
			continue
		}
		if remote.connected {
			snapshot.peers += 1
		}
		if online.role == .Join && i == 0 {
			snapshot.host = strings.clone(cstr(remote.id_str[:]), allocator)
			snapshot.network = remote.network
		}
	}
	return
}

// The datagram link over P2P for the netcode, valid once host/join started (it drops sends and
// receives nothing until Ready). Host: peer i >= 1 is the i-th joiner that sent a packet; joiner:
// peer 0 is the host. The link ticks EOS on every recv that finds nothing (at most every
// TICK_EVERY_US), so the thread running the netcode keeps EOS alive.
@(private)
link :: proc() -> (net_link: netcode.Link, ok: bool) {
	online := &session
	sync.guard(&online.mu)
	if online.stage == .Off || online.role == .None {
		return
	}
	return {
			data    = online,
			send    = link_send,
			recv    = link_recv,
			close   = link_close,
			event   = link_event,
			forget  = link_forget,
			account = link_account,
		}, true
}

// The account behind a peer: the remote's product user id, which EOS authenticated (what the relay knows a person
// by, src/netcode/README.md, Members).
@(private)
link_account :: proc(data: rawptr, peer: netcode.Peer) -> (account: netcode.Account, ok: bool) {
	online := (^Online)(data)
	sync.guard(&online.mu)
	if int(peer) < 0 || int(peer) >= MAX_REMOTES || !online.remotes[peer].used {
		return
	}
	@(static) id: [PRODUCTUSERID_MAX_LENGTH + 1]u8
	id = online.remotes[peer].id_str
	return {platform = PLATFORM, id = cstr(id[:])}, true
}

@(private)
PLATFORM :: "eos" // the platform name of EOS accounts (netcode.Account)

// The local user's account (logged in: its product user id; ok = false before): the host's own player's.
@(private)
local_account :: proc() -> (account: netcode.Account, ok: bool) {
	online := &session
	sync.guard(&online.mu)
	if online.local == nil {
		return
	}
	@(static) id: [PRODUCTUSERID_MAX_LENGTH + 1]u8
	id_to_string(online, online.local, id[:])
	return {platform = PLATFORM, id = cstr(id[:])}, true
}

// --- the way in (netcode.Lobby: eos.lobby) -------------------------------------------------------

// Starts hosting and returns the link at once (init must have succeeded).
open_host :: proc(build: Build) -> (net_link: netcode.Link, ok: bool) {
	if !host(build) {
		return
	}
	return link()
}

// Starts joining `code` and returns the link at once: login, a search by code, a build check, the join (pump says
// how it goes). A code that doesn't parse fails here.
open_join :: proc(build: Build, code: string) -> (net_link: netcode.Link, ok: bool) {
	if !join(build, code) {
		return
	}
	return link()
}

// Ticks EOS and says where the session stands (strings temp-allocated): the shape of netcode.Lobby.pump.
pump :: proc() -> (result: netcode.Lobby_Status) {
	{
		online := &session
		sync.guard(&online.mu)
		tick(online)
	}
	status := status()
	stages := [Stage]netcode.Lobby_Stage {
		.Off    = .Idle,
		.Idle   = .Idle,
		.Login  = .Opening,
		.Lobby  = .Opening,
		.Ready  = .Ready,
		.Failed = .Failed,
	}
	return {
		stage   = stages[status.stage],
		detail  = status.detail,
		code    = status.code,
		local   = status.local,
		host    = status.host,
		network = fmt.tprint(status.network),
		peers   = status.peers,
	}
}

// Ends the session: destroys (host) or leaves (joiner) the lobby, ticking EOS until the request went out, and
// closes P2P. The login stays.
close :: proc() {
	leave()
}

// Leaves the session: destroys (host) or leaves (joiner) the lobby, closes P2P. The login stays.
// Ticks EOS until the lobby request completed (at most LEAVE_FLUSH_MS): a game back in its menu,
// or quitting, may not tick EOS again for a long time, and an unsent leave keeps the player a lobby
// member (or the host's lobby open) until Epic notices, possibly after the player rejoined.
@(private)
leave :: proc() {
	online := &session
	sync.guard(&online.mu)
	end_session(online)
	for i := 0; i < LEAVE_FLUSH_MS / 5 && online.in_lobby && online.platform != nil; i += 1 {
		tick(online)
		time.sleep(5 * time.Millisecond)
	}
}

@(private)
LEAVE_FLUSH_MS :: 500

// forget_device's deletion completed (set by its EOS callback, which may come after forget_device gave up waiting).
@(private)
device_forgotten: bool

// Deletes this machine's device ID (the next login makes a new anonymous user). For test tools,
// so runs leave nothing behind; blocks up to ~5 s while EOS completes it.
@(private)
forget_device :: proc() {
	online := &session
	sync.guard(&online.mu)
	if online.platform == nil {
		return
	}
	// The callback's flag outlives this call (a package global, not a local): EOS may complete it after the wait gave up.
	sync.atomic_store(&device_forgotten, false)
	delete_options := Connect_Delete_Device_Id_Options {
		api_version = CONNECT_DELETEDEVICEID_API_LATEST,
	}
	online.api.Connect_DeleteDeviceId(online.connect, &delete_options, nil, proc "c" (info: ^Result_Callback_Info) {
		sync.atomic_store(&device_forgotten, true)
	})
	for _ in 0 ..< 500 {
		tick(online)
		if sync.atomic_load(&device_forgotten) {
			return
		}
		time.sleep(10 * time.Millisecond)
	}
}

// Releases the platform; call once at exit. EOS can't be initialized again in this process.
shutdown :: proc() {
	online := &session
	sync.guard(&online.mu)
	if online.platform == nil {
		return
	}
	end_session(online)
	// Let the leave requests go out.
	for _ in 0 ..< 50 {
		online.api.Platform_Tick(online.platform)
		if !online.in_lobby {
			break
		}
		time.sleep(10 * time.Millisecond)
	}
	online.api.Platform_Release(online.platform)
	online.api.Shutdown()
	online.platform = nil
	online.stage = .Off
	set_detail(online, "shut down")
}

// --- session state machine ----------------------------------------------------------------------

@(private)
begin :: proc(role: Role, build: Build, code: Code) -> bool {
	online := &session
	sync.guard(&online.mu)
	if online.stage == .Off {
		return false
	}
	if online.stage != .Idle && online.stage != .Failed {
		end_session(online)
	}
	online.gen += 1
	online.role = role
	online.code = code
	online.max_members = clamp(build.players, 1, len(online.members))
	online.searches = 0
	online.search_at_us = 0
	online.connect_at_us = 0
	online.connect_tries = 0
	online.members = {}
	online.held = {}
	online.held_next = 0
	online.n_events = 0
	online.bucket = {}
	copy(online.bucket[:len(online.bucket) - 1], build.game)
	online.build_id = {}
	copy(online.build_id[:len(online.build_id) - 1], build_id(build.compat))
	online.version = {}
	copy(online.version[:len(online.version) - 1], build.version)
	online.detail_len = 0
	if online.local == nil {
		online.stage = .Login
		if !online.login_busy {
			start_login(online)
		}
	} else {
		start_lobby(online)
	}
	return true
}

@(private)
tick :: proc(online: ^Online) {
	if online.platform == nil {
		return
	}
	online.api.Platform_Tick(online.platform)
	pump_main_run_loop()
	online.last_tick_us = netcode.now_us()
	if online.search_at_us != 0 &&
	   online.last_tick_us >= online.search_at_us &&
	   online.stage == .Lobby &&
	   online.role == .Join {
		online.search_at_us = 0
		start_lobby(online)
	}
	if online.relogin_at_us != 0 && online.last_tick_us >= online.relogin_at_us && !online.login_busy {
		online.relogin_at_us = 0
		start_login(online)
	}
	if online.connect_at_us != 0 && online.last_tick_us >= online.connect_at_us {
		connect_again(online)
	}
}

// Joiner: the P2P connection to the host didn't come up in time. Close it, so the netcode's next
// packet makes a new connection request (and the host a new offer); after CONNECT_TRIES, fail.
@(private)
connect_again :: proc(online: ^Online) {
	online.connect_at_us = 0
	if online.stage != .Ready || online.role != .Join || online.remotes[0].connected {
		return
	}
	waited_s := f64(online.connect_tries) * f64(online.connect_wait) / 1e6
	if online.connect_tries >= CONNECT_TRIES {
		fail(
			online,
			"no connection to the host after %.0f s (%d tries): EOS's signalling didn't get through; join again",
			waited_s,
			online.connect_tries,
		)
		return
	}
	close_options := P2P_Accept_Connection_Options {
		api_version    = P2P_CLOSECONNECTION_API_LATEST,
		local_user_id  = online.local,
		remote_user_id = online.remotes[0].id,
		socket_id      = &online.socket,
	}
	if result := online.api.P2P_CloseConnection(online.p2p, &close_options); result != .Success {
		log_line("closing the P2P connection to the host: %s", online.api.EResult_ToString(result))
	}
	online.connect_tries += 1
	online.connect_at_us = online.last_tick_us + online.connect_wait
	log_line(
		"no P2P connection to the host after %.0f s: asking again (try %d of %d)",
		waited_s,
		online.connect_tries,
		CONNECT_TRIES,
	)
}

@(private)
RELOGIN_RETRY_US :: 15_000_000

@(private)
fail :: proc(online: ^Online, format: string, args: ..any) {
	set_detail(online, format, ..args)
	online.stage = .Failed
	log_line("session failed: %s", string(online.detail[:online.detail_len]))
}

@(private)
start_login :: proc(online: ^Online) {
	online.login_busy = true
	if online.fresh_device {
		// Test aid: a brand-new device ID gives this process its own Product User ID, so two
		// processes on one machine can play each other.
		online.fresh_device = false
		delete_options := Connect_Delete_Device_Id_Options {
			api_version = CONNECT_DELETEDEVICEID_API_LATEST,
		}
		online.api.Connect_DeleteDeviceId(online.connect, &delete_options, online, on_device_deleted)
		return
	}
	creds := Connect_Credentials {
		api_version = CONNECT_CREDENTIALS_API_LATEST,
		type        = ECT_DEVICEID_ACCESS_TOKEN,
	}
	info := Connect_User_Login_Info {
		api_version  = CONNECT_USERLOGININFO_API_LATEST,
		display_name = "player", // unused: names travel in the netcode's Hello
	}
	login_options := Connect_Login_Options {
		api_version     = CONNECT_LOGIN_API_LATEST,
		credentials     = &creds,
		user_login_info = &info,
	}
	online.api.Connect_Login(online.connect, &login_options, online, on_login)
}

@(private)
on_device_deleted :: proc "c" (info: ^Result_Callback_Info) {
	online := (^Online)(info.client_data)
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	log_line("device ID deleted: %s", online.api.EResult_ToString(info.result_code))
	create_device_id(online)
}

@(private)
create_device_id :: proc(online: ^Online) {
	online.device_tries += 1
	create_device_options := Connect_Create_Device_Id_Options {
		api_version  = CONNECT_CREATEDEVICEID_API_LATEST,
		device_model = ODIN_OS == .Windows ? "Windows PC" : ODIN_OS == .Darwin ? "Mac" : "Linux PC",
	}
	online.api.Connect_CreateDeviceId(online.connect, &create_device_options, online, on_device_created)
}

@(private)
on_device_created :: proc "c" (info: ^Result_Callback_Info) {
	online := (^Online)(info.client_data)
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	log_line("device ID: %s", online.api.EResult_ToString(info.result_code))
	if info.result_code != .Success && info.result_code != .DuplicateNotAllowed {
		online.login_busy = false
		fail(online, "creating a device ID: %s", online.api.EResult_ToString(info.result_code))
		return
	}
	start_login(online)
}

@(private)
on_login :: proc "c" (info: ^Connect_Login_Callback_Info) {
	online := (^Online)(info.client_data)
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	if info.result_code != .Success {
		log_line("login: %s", online.api.EResult_ToString(info.result_code))
	}
	if info.result_code != .Success && online.local != nil {
		// A token refresh (on_auth_expiring) failed, e.g. a network blip an hour into a session. The
		// session still runs on the current token: keep it and try again, rather than fail it.
		online.login_busy = false
		online.relogin_at_us = netcode.now_us() + RELOGIN_RETRY_US
		return
	}
	#partial switch info.result_code {
	case .Success:
		logged_in(online, info.local_user_id)
	case .NotFound:
		// No device ID on this machine yet.
		if online.device_tries >= 2 {
			online.login_busy = false
			fail(online, "login: no device ID after creating one")
			return
		}
		create_device_id(online)
	case .UnexpectedError:
		online.login_busy = false
		when ODIN_OS == .Darwin {
			// The keychain entry belongs to another build of this program and access was denied
			// (or prompts are off).
			fail(
				online,
				"login: the device ID in the keychain belongs to another build; allow access, or delete it: security delete-generic-password -s %s",
				KEYCHAIN_SERVICE,
			)
		} else {
			fail(online, "login: %s", online.api.EResult_ToString(info.result_code))
		}
	case .InvalidUser:
		// First login with this device ID: create the product user.
		create_user_options := Connect_Create_User_Options {
			api_version       = CONNECT_CREATEUSER_API_LATEST,
			continuance_token = info.continuance_token,
		}
		online.api.Connect_CreateUser(online.connect, &create_user_options, online, on_user_created)
	case:
		online.login_busy = false
		fail(online, "login: %s", online.api.EResult_ToString(info.result_code))
	}
}

@(private)
on_user_created :: proc "c" (info: ^Connect_Create_User_Callback_Info) {
	online := (^Online)(info.client_data)
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	if info.result_code != .Success {
		online.login_busy = false
		fail(online, "creating the user: %s", online.api.EResult_ToString(info.result_code))
		return
	}
	logged_in(online, info.local_user_id)
}

@(private)
logged_in :: proc(online: ^Online, id: Product_User_Id) {
	first := online.local == nil
	online.local = id
	online.login_busy = false
	id_to_string(online, id, online.local_str[:])
	if first {
		log_line("logged in as %s", cstr(online.local_str[:]))
		auth_notify_options := Connect_Add_Notify_Auth_Expiration_Options {
			api_version = CONNECT_ADDNOTIFYAUTHEXPIRATION_API_LATEST,
		}
		online.notify_auth = online.api.Connect_AddNotifyAuthExpiration(
			online.connect,
			&auth_notify_options,
			online,
			on_auth_expiring,
		)
		member_notify_options := Version_Options {
			api_version = LOBBY_ADDNOTIFYLOBBYMEMBERSTATUSRECEIVED_API_LATEST,
		}
		online.notify_member = online.api.Lobby_AddNotifyLobbyMemberStatusReceived(
			online.lobby,
			&member_notify_options,
			online,
			on_member_status,
		)
	}
	if online.stage == .Login {
		start_lobby(online)
	}
}

@(private)
on_auth_expiring :: proc "c" (info: ^Connect_Auth_Expiration_Callback_Info) {
	online := (^Online)(info.client_data)
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	// The access token lasts about an hour; refreshing is just logging in again.
	if !online.login_busy {
		start_login(online)
	}
}

@(private)
start_lobby :: proc(online: ^Online) {
	online.stage = .Lobby
	if online.role == .Host {
		online.code = code_new()
		open_socket(online)
		create_lobby_options := Lobby_Create_Lobby_Options {
			api_version            = LOBBY_CREATELOBBY_API_LATEST,
			local_user_id          = online.local,
			max_lobby_members      = u32(online.max_members),
			permission_level       = .Public_Advertised,
			bucket_id              = cstring(&online.bucket[0]),
			disable_host_migration = true,
		}
		online.api.Lobby_CreateLobby(online.lobby, &create_lobby_options, call_new(online), on_lobby_created)
		set_detail(online, "creating the lobby")
		return
	}
	search: H_Lobby_Search
	create_search_options := Lobby_Create_Lobby_Search_Options {
		api_version = LOBBY_CREATELOBBYSEARCH_API_LATEST,
		max_results = 2,
	}
	if result := online.api.Lobby_CreateLobbySearch(online.lobby, &create_search_options, &search);
	   result != .Success {
		fail(online, "lobby search: %s", online.api.EResult_ToString(result))
		return
	}
	code_c := strings.clone_to_cstring(string(online.code[:]), context.temp_allocator)
	params := [2]Lobby_Attribute_Data {
		{
			api_version = LOBBY_ATTRIBUTEDATA_API_LATEST,
			key = LOBBY_SEARCH_BUCKET_ID,
			value = {as_utf8 = cstring(&online.bucket[0])},
			value_type = .String,
		},
		{
			api_version = LOBBY_ATTRIBUTEDATA_API_LATEST,
			key = ATTR_CODE,
			value = {as_utf8 = code_c},
			value_type = .String,
		},
	}
	for &param in params {
		search_param_options := Lobby_Search_Set_Parameter_Options {
			api_version   = LOBBYSEARCH_SETPARAMETER_API_LATEST,
			parameter     = &param,
			comparison_op = CO_EQUAL,
		}
		if result := online.api.LobbySearch_SetParameter(search, &search_param_options); result != .Success {
			online.api.LobbySearch_Release(search)
			fail(online, "lobby search parameter: %s", online.api.EResult_ToString(result))
			return
		}
	}
	find_options := Lobby_Search_Find_Options {
		api_version   = LOBBYSEARCH_FIND_API_LATEST,
		local_user_id = online.local,
	}
	online.searches += 1
	online.api.LobbySearch_Find(search, &find_options, call_new(online, search), on_search_done)
	set_detail(online, "looking for game %s", string(online.code[:]))
}

@(private)
ATTR_CODE :: "code"
@(private)
ATTR_BUILD :: "build" // build_id: a joiner joins only the same build
@(private)
ATTR_VERSION :: "version" // the host's readable version, for the message when the builds differ

// What an async lobby request carries to its callback: the session generation it belongs to (a
// session left or replaced while the request was in flight must not be touched by its result) and
// the search handle to release.
@(private)
Call :: struct {
	gen:    u32,
	search: H_Lobby_Search,
}

@(private)
call_new :: proc(online: ^Online, search: H_Lobby_Search = nil) -> rawptr {
	call := new(Call, runtime.heap_allocator()) // freed in a callback, which runs with a fresh context
	call^ = {online.gen, search}
	return call
}

// Takes the callback's Call: (search handle, true if it belongs to the current session).
@(private)
call_take :: proc(online: ^Online, data: rawptr) -> (search: H_Lobby_Search, current: bool) {
	call := (^Call)(data)
	search, current = call.search, call.gen == online.gen
	free(call, runtime.heap_allocator())
	return
}

// Destroys (owner) or leaves a lobby that an abandoned session's request created or joined.
@(private)
drop_lobby :: proc(online: ^Online, id: Lobby_Id, owner: bool) {
	leave_options := Lobby_User_Lobby_Options {
		local_user_id = online.local,
		lobby_id      = id,
	}
	if owner {
		leave_options.api_version = LOBBY_DESTROYLOBBY_API_LATEST
		online.api.Lobby_DestroyLobby(online.lobby, &leave_options, online, on_lobby_left)
	} else {
		leave_options.api_version = LOBBY_LEAVELOBBY_API_LATEST
		online.api.Lobby_LeaveLobby(online.lobby, &leave_options, online, on_lobby_left)
	}
}

@(private)
on_lobby_created :: proc "c" (info: ^Lobby_Callback_Info) {
	online := &session
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	if _, current := call_take(online, info.client_data); !current || online.stage != .Lobby || online.role != .Host {
		// Left (or started another session) while the request was in flight.
		if info.result_code == .Success {
			drop_lobby(online, info.lobby_id, true)
		}
		return
	}
	if info.result_code != .Success {
		fail(online, "creating the lobby: %s", online.api.EResult_ToString(info.result_code))
		return
	}
	online.in_lobby = true
	online.lobby_id = {}
	copy(online.lobby_id[:len(online.lobby_id) - 1], string(info.lobby_id))
	mod: H_Lobby_Modification
	modify_options := Lobby_User_Lobby_Options {
		api_version   = LOBBY_UPDATELOBBYMODIFICATION_API_LATEST,
		local_user_id = online.local,
		lobby_id      = cstring(&online.lobby_id[0]),
	}
	if result := online.api.Lobby_UpdateLobbyModification(online.lobby, &modify_options, &mod); result != .Success {
		fail(online, "lobby modification: %s", online.api.EResult_ToString(result))
		return
	}
	defer online.api.LobbyModification_Release(mod)
	attributes := [3][2]string {
		{ATTR_CODE, string(online.code[:])},
		{ATTR_BUILD, cstr(online.build_id[:])},
		{ATTR_VERSION, cstr(online.version[:])},
	}
	for attribute in attributes {
		attr := Lobby_Attribute_Data {
			api_version = LOBBY_ATTRIBUTEDATA_API_LATEST,
			key = strings.clone_to_cstring(attribute[0], context.temp_allocator),
			value = {as_utf8 = strings.clone_to_cstring(attribute[1], context.temp_allocator)},
			value_type = .String,
		}
		attribute_options := Lobby_Modification_Add_Attribute_Options {
			api_version = LOBBYMODIFICATION_ADDATTRIBUTE_API_LATEST,
			attribute   = &attr,
			visibility  = LA_PUBLIC,
		}
		if result := online.api.LobbyModification_AddAttribute(mod, &attribute_options); result != .Success {
			fail(online, "lobby attribute %s: %s", attribute[0], online.api.EResult_ToString(result))
			return
		}
	}
	update_options := Lobby_Update_Lobby_Options {
		api_version               = LOBBY_UPDATELOBBY_API_LATEST,
		lobby_modification_handle = mod,
	}
	online.api.Lobby_UpdateLobby(online.lobby, &update_options, call_new(online), on_lobby_updated)
}

@(private)
on_lobby_updated :: proc "c" (info: ^Lobby_Callback_Info) {
	online := &session
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	if _, current := call_take(online, info.client_data); !current || online.stage != .Lobby {
		return
	}
	if info.result_code != .Success {
		fail(online, "publishing the lobby code: %s", online.api.EResult_ToString(info.result_code))
		return
	}
	online.stage = .Ready
	set_detail(online, "hosting game %s", string(online.code[:]))
	log_line("hosting game %s (lobby %s)", string(online.code[:]), cstr(online.lobby_id[:]))
}

@(private)
on_search_done :: proc "c" (info: ^Result_Callback_Info) {
	online := &session
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	search, current := call_take(online, info.client_data)
	defer online.api.LobbySearch_Release(search)
	if !current || online.stage != .Lobby || online.role != .Join {
		return
	}
	count: u32
	if info.result_code == .Success {
		count_options := Version_Options {
			api_version = LOBBYSEARCH_GETSEARCHRESULTCOUNT_API_LATEST,
		}
		count = online.api.LobbySearch_GetSearchResultCount(search, &count_options)
	} else if info.result_code != .NotFound {
		fail(online, "lobby search: %s", online.api.EResult_ToString(info.result_code))
		return
	}
	if count == 0 {
		if online.searches < SEARCH_TRIES {
			online.search_at_us = netcode.now_us() + SEARCH_RETRY_US
			return
		}
		fail(online, "no game with code %s", string(online.code[:]))
		return
	}
	details: H_Lobby_Details
	copy_options := Lobby_Search_Copy_Search_Result_By_Index_Options {
		api_version = LOBBYSEARCH_COPYSEARCHRESULTBYINDEX_API_LATEST,
	}
	if result := online.api.LobbySearch_CopySearchResultByIndex(search, &copy_options, &details); result != .Success {
		fail(online, "lobby search result: %s", online.api.EResult_ToString(result))
		return
	}
	defer online.api.LobbyDetails_Release(details)
	owner_options := Version_Options {
		api_version = LOBBYDETAILS_GETLOBBYOWNER_API_LATEST,
	}
	online.host = online.api.LobbyDetails_GetLobbyOwner(details, &owner_options)
	if online.host == nil {
		fail(online, "the game has no host")
		return
	}
	// Another build: say which, rather than join a session the relay would refuse.
	if lobby_attribute(online, details, ATTR_BUILD) != cstr(online.build_id[:]) {
		game, ours := cstr(online.bucket[:]), cstr(online.version[:])
		theirs := lobby_attribute(online, details, ATTR_VERSION)
		if theirs != "" && theirs != ours {
			fail(online, "that game runs %s %s; you have %s", game, theirs, ours if ours != "" else "another version")
		} else if theirs != "" {
			fail(online, "that game runs a different build of %s %s", game, theirs)
		} else {
			fail(online, "that game runs a different build of %s", game)
		}
		return
	}
	join_options := Lobby_Join_Lobby_Options {
		api_version          = LOBBY_JOINLOBBY_API_LATEST,
		lobby_details_handle = details,
		local_user_id        = online.local,
	}
	online.api.Lobby_JoinLobby(online.lobby, &join_options, call_new(online), on_lobby_joined)
	set_detail(online, "joining game %s", string(online.code[:]))
}

// A lobby's string attribute (temp-allocated), or "" when it has none.
@(private)
lobby_attribute :: proc(online: ^Online, details: H_Lobby_Details, key: cstring) -> string {
	options := LobbyDetails_Copy_Attribute_By_Key_Options {
		api_version = LOBBYDETAILS_COPYATTRIBUTEBYKEY_API_LATEST,
		attr_key    = key,
	}
	attribute: ^Lobby_Attribute
	if online.api.LobbyDetails_CopyAttributeByKey(details, &options, &attribute) != .Success || attribute == nil {
		return ""
	}
	defer online.api.Lobby_Attribute_Release(attribute)
	if attribute.data == nil || attribute.data.value_type != .String || attribute.data.value.as_utf8 == nil {
		return ""
	}
	return strings.clone(string(attribute.data.value.as_utf8), context.temp_allocator)
}

@(private)
on_lobby_joined :: proc "c" (info: ^Lobby_Callback_Info) {
	online := &session
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	if _, current := call_take(online, info.client_data); !current || online.stage != .Lobby || online.role != .Join {
		// Left (or started another session) while the request was in flight; keep the lobby if
		// the current session is in it.
		if info.result_code == .Success && !(online.in_lobby && string(info.lobby_id) == cstr(online.lobby_id[:])) {
			drop_lobby(online, info.lobby_id, false)
		}
		return
	}
	if info.result_code != .Success {
		fail(online, "joining the game: %s", online.api.EResult_ToString(info.result_code))
		return
	}
	online.in_lobby = true
	online.lobby_id = {}
	copy(online.lobby_id[:len(online.lobby_id) - 1], string(info.lobby_id))
	open_socket(online)
	remote := &online.remotes[0]
	remote^ = {
		used = true,
		id   = online.host,
	}
	id_to_string(online, online.host, remote.id_str[:])
	online.stage = .Ready
	online.connect_tries = 1 // the netcode's first packet makes the connection request
	online.joined_us = netcode.now_us()
	online.connect_at_us = online.joined_us + online.connect_wait
	set_detail(online, "joined game %s", string(online.code[:]))
	log_line("joined game %s, host %s", string(online.code[:]), cstr(remote.id_str[:]))
}

@(private)
on_member_status :: proc "c" (info: ^Lobby_Member_Status_Received_Callback_Info) {
	online := (^Online)(info.client_data)
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	if !online.in_lobby || string(info.lobby_id) != cstr(online.lobby_id[:]) {
		return
	}
	buf: [PRODUCTUSERID_MAX_LENGTH + 1]u8
	id_to_string(online, info.target_user_id, buf[:])
	log_line("lobby member %s: %v", cstr(buf[:]), info.current_status)
	if online.role == .Join && online.stage == .Ready {
		host_gone := info.current_status == .Closed
		if info.current_status == .Left || info.current_status == .Disconnected {
			host_gone = cstr(buf[:]) == cstr(online.remotes[0].id_str[:])
		}
		if host_gone {
			online.in_lobby = false
			push_event(online, 0, false)
			fail(online, "the host closed the game")
		}
	}
	if online.role != .Host {
		return
	}
	if info.current_status == .Joined {
		member_joined(online, info.target_user_id)
		return
	}
	gone := info.current_status == .Left || info.current_status == .Disconnected || info.current_status == .Kicked
	if gone {
		if i := user_index(online, online.members[:], info.target_user_id); i >= 0 {
			online.members[i] = {}
		}
		for &remote, i in online.remotes {
			if remote.used && cstr(remote.id_str[:]) == cstr(buf[:]) {
				remote.connected = false
				if remote.known {
					push_event(online, netcode.Peer(i), false) // the netcode forgets it: link_forget frees it then
				} else {
					free_remote(online, i)
				}
			}
		}
	}
}

// Host: a user joined the lobby. It may connect from now on; a connection request it made before the
// lobby told us (the two arrive in either order) is accepted now.
@(private)
member_joined :: proc(online: ^Online, id: Product_User_Id) {
	if user_index(online, online.members[:], id) < 0 {
		for &member in online.members {
			if !member.used {
				user_set(online, &member, id)
				break
			}
		}
	}
	if i := user_index(online, online.held[:], id); i >= 0 {
		log_line("%s joined the lobby: accepting its held connection request", cstr(online.held[i].id_str[:]))
		online.held[i] = {}
		accept(online, id)
	}
}

@(private)
accept :: proc(online: ^Online, id: Product_User_Id) {
	accept_options := P2P_Accept_Connection_Options {
		api_version    = P2P_ACCEPTCONNECTION_API_LATEST,
		local_user_id  = online.local,
		remote_user_id = id,
		socket_id      = &online.socket,
	}
	if result := online.api.P2P_AcceptConnection(online.p2p, &accept_options); result != .Success {
		log_line("accepting a P2P connection: %s", online.api.EResult_ToString(result))
	}
}

// P2P socket for this session: "unified-<code>", so packets of an old session never mix in.
@(private)
open_socket :: proc(online: ^Online) {
	online.socket = {
		api_version = P2P_SOCKETID_API_LATEST,
	}
	name := fmt.bprintf(
		online.socket.socket_name[:P2P_SOCKETID_SOCKETNAME_SIZE - 1],
		"%s%s",
		SOCKET_PREFIX,
		string(online.code[:]),
	)
	_ = name
	socket_options := P2P_Socket_Options {
		api_version   = P2P_ADDNOTIFYPEERCONNECTIONREQUEST_API_LATEST,
		local_user_id = online.local,
		socket_id     = &online.socket,
	}
	online.notify_req = online.api.P2P_AddNotifyPeerConnectionRequest(
		online.p2p,
		&socket_options,
		online,
		on_connection_request,
	)
	socket_options.api_version = P2P_ADDNOTIFYPEERCONNECTIONESTABLISHED_API_LATEST
	online.notify_est = online.api.P2P_AddNotifyPeerConnectionEstablished(
		online.p2p,
		&socket_options,
		online,
		on_connection_established,
	)
	socket_options.api_version = P2P_ADDNOTIFYPEERCONNECTIONCLOSED_API_LATEST
	online.notify_closed = online.api.P2P_AddNotifyPeerConnectionClosed(
		online.p2p,
		&socket_options,
		online,
		on_connection_closed,
	)
	queue_options := P2P_Set_Packet_Queue_Size_Options {
		api_version                          = P2P_SETPACKETQUEUESIZE_API_LATEST,
		incoming_packet_queue_max_size_bytes = 4 << 20,
		outgoing_packet_queue_max_size_bytes = 4 << 20,
	}
	online.api.P2P_SetPacketQueueSize(online.p2p, &queue_options)
}

@(private)
on_connection_request :: proc "c" (info: ^P2P_On_Incoming_Connection_Request_Info) {
	online := (^Online)(info.client_data)
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	if online.stage != .Ready {
		return
	}
	// The joiner only talks to the host.
	if online.role == .Join && !same_user(online, info.remote_user_id, &online.remotes[0]) {
		return
	}
	// The host only accepts its lobby's members. A request can arrive before the lobby tells us the user
	// joined: hold it, member_joined accepts it then.
	if online.role == .Host && user_index(online, online.members[:], info.remote_user_id) < 0 {
		if user_index(online, online.held[:], info.remote_user_id) < 0 {
			user_set(online, &online.held[online.held_next], info.remote_user_id)
			log_line(
				"connection request from %s, not in the lobby: held until it joins",
				cstr(online.held[online.held_next].id_str[:]),
			)
			online.held_next = (online.held_next + 1) % HELD_REQUESTS
		}
		return
	}
	accept(online, info.remote_user_id)
}

@(private)
on_connection_established :: proc "c" (info: ^P2P_On_Peer_Connection_Established_Info) {
	online := (^Online)(info.client_data)
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	i := remote_index(online, info.remote_user_id, online.role == .Host)
	if i < 0 {
		return
	}
	remote := &online.remotes[i]
	remote.connected = true
	remote.heard = false
	remote.network = info.network_type
	push_event(online, netcode.Peer(i), true)
	if online.role == .Join && online.connect_at_us != 0 {
		online.connect_at_us = 0
		log_line(
			"P2P connected to the host %s (%v), %.1f s after joining, try %d",
			cstr(remote.id_str[:]),
			info.network_type,
			f64(netcode.now_us() - online.joined_us) / 1e6,
			online.connect_tries,
		)
	} else {
		log_line("P2P connected to %s (%v)", cstr(remote.id_str[:]), info.network_type)
	}
}

@(private)
on_connection_closed :: proc "c" (info: ^P2P_On_Remote_Connection_Closed_Info) {
	online := (^Online)(info.client_data)
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	i := remote_index(online, info.remote_user_id, false)
	if i < 0 {
		return
	}
	was_connected := online.remotes[i].connected
	online.remotes[i].connected = false
	if online.remotes[i].forgotten {
		online.remotes[i].forgotten = false // our own close (link_forget): the netcode already knows
		return
	}
	if online.role == .Join && !was_connected {
		// A try that never connected, closed by connect_again: the netcode keeps waiting for the host.
		log_line("P2P connection to the host closed before it came up (reason %d)", info.reason)
		return
	}
	if online.role == .Join && !online.remotes[i].heard && online.stage == .Ready {
		// Up, but nothing ever came through it, then closed: after a crash the host's SDK can hold the old process's
		// connection, so the new one is half-open until the host closes it. Not a lost host: try again.
		online.connect_at_us = online.last_tick_us + online.connect_wait
		log_line(
			"P2P connection to the host closed before anything came through (reason %d): trying again",
			info.reason,
		)
		return
	}
	push_event(online, netcode.Peer(i), false)
	log_line("P2P connection to %s closed (reason %d)", cstr(online.remotes[i].id_str[:]), info.reason)
}

@(private)
end_session :: proc(online: ^Online) {
	if online.platform == nil {
		return
	}
	if online.socket.api_version != 0 {
		socket_options := P2P_Socket_Options {
			api_version   = P2P_CLOSECONNECTIONS_API_LATEST,
			local_user_id = online.local,
			socket_id     = &online.socket,
		}
		online.api.P2P_CloseConnections(online.p2p, &socket_options)
		online.api.P2P_RemoveNotifyPeerConnectionRequest(online.p2p, online.notify_req)
		online.api.P2P_RemoveNotifyPeerConnectionEstablished(online.p2p, online.notify_est)
		online.api.P2P_RemoveNotifyPeerConnectionClosed(online.p2p, online.notify_closed)
		online.socket = {}
	}
	if online.in_lobby {
		leave_options := Lobby_User_Lobby_Options {
			local_user_id = online.local,
			lobby_id      = cstring(&online.lobby_id[0]),
		}
		if online.role == .Host {
			leave_options.api_version = LOBBY_DESTROYLOBBY_API_LATEST
			online.api.Lobby_DestroyLobby(online.lobby, &leave_options, online, on_lobby_left)
		} else {
			leave_options.api_version = LOBBY_LEAVELOBBY_API_LATEST
			online.api.Lobby_LeaveLobby(online.lobby, &leave_options, online, on_lobby_left)
		}
	}
	online.gen += 1
	online.remotes = {}
	online.members = {}
	online.held = {}
	online.held_next = 0
	online.connect_at_us = 0
	online.host = nil
	online.role = .None
	online.code = {}
	if online.stage != .Off && online.stage != .Login {
		online.stage = .Idle
	}
}

@(private)
on_lobby_left :: proc "c" (info: ^Lobby_Callback_Info) {
	online := (^Online)(info.client_data)
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	if string(info.lobby_id) == cstr(online.lobby_id[:]) {
		online.in_lobby = false
	}
	log_line("left lobby %s: %s", string(info.lobby_id), online.api.EResult_ToString(info.result_code))
}

// --- the link -----------------------------------------------------------------------------------

@(private)
link_send :: proc(data: rawptr, to: netcode.Peer, bytes: []u8) {
	online := (^Online)(data)
	sync.guard(&online.mu)
	if online.stage != .Ready || int(to) < 0 || int(to) >= MAX_REMOTES || !online.remotes[to].used {
		return
	}
	send_packet(online, online.remotes[to].id, bytes)
}

@(private)
send_packet :: proc(online: ^Online, to: Product_User_Id, pkt: []u8) {
	send_options := P2P_Send_Packet_Options {
		api_version            = P2P_SENDPACKET_API_LATEST,
		local_user_id          = online.local,
		remote_user_id         = to,
		socket_id              = &online.socket,
		channel                = 0,
		data_length_bytes      = u32(len(pkt)),
		data                   = raw_data(pkt),
		allow_delayed_delivery = true,
		reliability            = .Unreliable_Unordered,
	}
	if result := online.api.P2P_SendPacket(online.p2p, &send_options); result != .Success {
		online.send_errors += 1
		if online.send_errors < 10 {
			log_line("P2P send: %s", online.api.EResult_ToString(result))
		}
		return
	}
	online.sent += 1
}

@(private)
link_recv :: proc(data: rawptr, buf: []u8) -> (length: int, from: netcode.Peer, ok: bool) {
	online := (^Online)(data)
	sync.guard(&online.mu)
	if online.platform == nil {
		return
	}
	for attempt in 0 ..< 2 {
		for online.stage == .Ready {
			pkt: [P2P_MAX_PACKET]u8 = ---
			peer: Product_User_Id
			sock: P2P_Socket_Id
			channel: u8
			written: u32
			receive_options := P2P_Receive_Packet_Options {
				api_version         = P2P_RECEIVEPACKET_API_LATEST,
				local_user_id       = online.local,
				max_data_size_bytes = P2P_MAX_PACKET,
			}
			result := online.api.P2P_ReceivePacket(
				online.p2p,
				&receive_options,
				&peer,
				&sock,
				&channel,
				&pkt[0],
				&written,
			)
			if result != .Success {
				break
			}
			if cstr(sock.socket_name[:]) != cstr(online.socket.socket_name[:]) {
				continue
			}
			i := remote_index(online, peer, online.role == .Host)
			if i < 0 {
				continue
			}
			online.received += 1
			online.remotes[i].heard = true
			if int(written) > len(buf) {
				continue // larger than any netcode datagram: not ours, and the netcode never hears of the peer
			}
			online.remotes[i].known = true // the netcode now knows the peer: link_forget frees it
			return copy(buf, pkt[:written]), netcode.Peer(i), true
		}
		if attempt == 0 && netcode.now_us() - online.last_tick_us >= TICK_EVERY_US {
			tick(online)
			continue
		}
		break
	}
	return
}

@(private)
link_close :: proc(data: rawptr) {
	// The session outlives the netcode objects; `leave` ends it.
}

// Host: the netcode is done with a peer (10 s of silence, a goodbye, or garbage). Close our side of its P2P
// connection: after a crash, EOS would otherwise hold the dead connection for its 30 s reconnect window, and the same
// user's restarted game couldn't connect until then. While the user is a lobby member the peer number stays
// theirs: its next connection request opens a fresh connection on it. A user who left the lobby too is freed: the
// number goes to the next new user, so a long-lived lobby serves any number of people over time.
@(private)
link_forget :: proc(data: rawptr, peer: netcode.Peer) {
	online := (^Online)(data)
	sync.guard(&online.mu)
	if online.role != .Host || online.stage != .Ready || int(peer) < 1 || int(peer) >= MAX_REMOTES {
		return
	}
	remote := &online.remotes[peer]
	if !remote.used {
		return
	}
	remote.known = false
	defer if user_index(online, online.members[:], remote.id) < 0 {
		free_remote(online, int(peer))
	}
	close_options := P2P_Accept_Connection_Options {
		api_version    = P2P_CLOSECONNECTION_API_LATEST,
		local_user_id  = online.local,
		remote_user_id = remote.id,
		socket_id      = &online.socket,
	}
	remote.forgotten = true // before the call: EOS may report the close from inside it
	if result := online.api.P2P_CloseConnection(online.p2p, &close_options); result != .Success {
		remote.forgotten = false
		log_line("closing the P2P connection to %s: %s", cstr(remote.id_str[:]), online.api.EResult_ToString(result))
		return
	}
	remote.connected = false
	log_line("closed the P2P connection to %s: the session is done with it", cstr(remote.id_str[:]))
}

@(private)
link_event :: proc(data: rawptr) -> (peer: netcode.Peer, kind: netcode.Link_Event_Kind, ok: bool) {
	online := (^Online)(data)
	sync.guard(&online.mu)
	if online.n_events == 0 {
		return
	}
	event := online.events[0]
	copy(online.events[:], online.events[1:online.n_events])
	online.n_events -= 1
	return event.peer, event.connected ? .Connected : .Disconnected, true
}

@(private)
push_event :: proc(online: ^Online, peer: netcode.Peer, connected: bool) {
	if online.n_events < len(online.events) {
		online.events[online.n_events] = {peer, connected}
		online.n_events += 1
	}
}

// --- helpers ------------------------------------------------------------------------------------

// The remote slot of `id`, or -1. The host adds unknown users (from index 1, like the UDP relay)
// when `add` is set.
@(private)
remote_index :: proc(online: ^Online, id: Product_User_Id, add: bool) -> int {
	for &remote, i in online.remotes {
		if remote.used && same_user(online, id, &remote) {
			return i
		}
	}
	// Only a lobby member becomes a new peer (its connection was accepted for that reason).
	if !add || online.role != .Host || user_index(online, online.members[:], id) < 0 {
		return -1
	}
	for i in 1 ..< MAX_REMOTES {
		remote := &online.remotes[i]
		if !remote.used {
			remote^ = {
				used = true,
				id   = id,
			}
			id_to_string(online, id, remote.id_str[:])
			log_line("peer %d = %s", i, cstr(remote.id_str[:]))
			return i
		}
	}
	return -1
}

// Host: frees remote `i` (its user left the lobby and the netcode forgot the peer): the next new user gets it.
@(private)
free_remote :: proc(online: ^Online, i: int) {
	log_line("peer %d (%s) freed: left the lobby, forgotten by the session", i, cstr(online.remotes[i].id_str[:]))
	online.remotes[i] = {}
}

// The index of `id` among `users`, or -1.
@(private)
user_index :: proc(online: ^Online, users: []User, id: Product_User_Id) -> int {
	buf: [PRODUCTUSERID_MAX_LENGTH + 1]u8
	text := ""
	for &user, i in users {
		if !user.used do continue
		if user.id == id do return i
		if text == "" {
			id_to_string(online, id, buf[:])
			text = cstr(buf[:])
		}
		if text == cstr(user.id_str[:]) do return i
	}
	return -1
}

@(private)
user_set :: proc(online: ^Online, user: ^User, id: Product_User_Id) {
	user^ = {
		used = true,
		id   = id,
	}
	id_to_string(online, id, user.id_str[:])
}

@(private)
same_user :: proc(online: ^Online, id: Product_User_Id, remote: ^Remote) -> bool {
	if id == remote.id {
		return true
	}
	buf: [PRODUCTUSERID_MAX_LENGTH + 1]u8
	id_to_string(online, id, buf[:])
	return cstr(buf[:]) == cstr(remote.id_str[:])
}

@(private)
id_to_string :: proc(online: ^Online, id: Product_User_Id, out: []u8) {
	for &b in out {
		b = 0
	}
	length := i32(len(out))
	if online.api.ProductUserId_ToString(id, raw_data(out), &length) != .Success {
		out[0] = 0
	}
}

@(private)
cstr :: proc(bytes: []u8) -> string {
	for char, i in bytes {
		if char == 0 {
			return string(bytes[:i])
		}
	}
	return string(bytes)
}

@(private)
set_detail :: proc(online: ^Online, format: string, args: ..any) {
	text := fmt.bprintf(online.detail[:], format, ..args)
	online.detail_len = len(text)
}

// Where the package's and the SDK's lines go: the logger of the context `init` ran in (the SDK's log callback carries
// no user data; there is one platform per process). With none set there (runtime's default drops every line: the Godot
// session thread), stderr, so UNIFIED_EOS_LOG's lines reach someone.
@(private)
eos_logger: log.Logger

@(private)
log_line :: proc(format: string, args: ..any) {
	eos_log(.Info, fmt.tprintf(format, ..args))
}

// One line to eos_logger (or stderr), at `level`.
@(private)
eos_log :: proc(level: log.Level, text: string) {
	if eos_logger.procedure == nil || eos_logger.procedure == runtime.default_logger_proc {
		fmt.eprintfln("[eos] %s", text)
		return
	}
	context.logger = eos_logger
	log.logf(level, "[eos] %s", text)
}

@(private)
log_level_from_env :: proc() -> Log_Level {
	switch os.get_env("UNIFIED_EOS_LOG", context.temp_allocator) {
	case "off":
		return .Off
	case "error":
		return .Error
	case "info":
		return .Info
	case "verbose":
		return .Verbose
	case "very_verbose":
		return .Very_Verbose
	}
	return .Warning
}

@(private)
on_log :: proc "c" (msg: ^Log_Message) {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	level := log.Level.Debug
	#partial switch msg.level {
	case .Fatal:
		level = .Fatal
	case .Error:
		level = .Error
	case .Warning:
		level = .Warning
	case .Info:
		level = .Info
	}
	eos_log(level, fmt.tprintf("sdk %s: %s", msg.category, msg.message))
}
