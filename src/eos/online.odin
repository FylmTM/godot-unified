// Online play through EOS: one process-wide session (the EOS platform is per process). The flow:
//
//   init      load the SDK library next to the game, EOS_Initialize, create the platform
//   host      device-ID login -> create a lobby (max 4) with a random code attribute -> Ready
//   join      device-ID login -> search the lobby by code -> join -> host = lobby owner -> Ready
//   link      once Ready: a netcode.Link over P2P (host: peers 1.. = joiners; joiner: peer 0 = host)
//   leave     destroy/leave the lobby, close P2P connections -> Idle (login is kept)
//
// Every EOS call happens under one mutex, from whichever thread calls `poll` or uses the link; EOS
// callbacks run inside Platform_Tick, so they never lock. The netcode thread drives EOS through the
// link (recv ticks the platform); while no link is in use, the host program calls `poll` (e.g.
// each frame). Status is read with `status`, from any thread.
package eos

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"

import "../netcode"

Role :: enum u8 {
	None,
	Host,
	Join,
}

Stage :: enum u8 {
	Off, // not initialized (or the SDK failed to load)
	Idle, // initialized, no session
	Login, // device-ID login in flight
	Lobby, // creating, searching or joining the lobby
	Ready, // host: lobby open, code set; joiner: in the lobby, host known
	Failed, // see detail; `leave` returns to Idle
}

MAX_REMOTES :: 16
STAGED_SDK_BIN :: #directory + "/../../third_party/eos/SDK/Bin"
TICK_EVERY_US :: 500 // the link ticks EOS at most this often when it finds no packet
SOCKET_PREFIX :: "unified-"
MAX_MEMBERS :: 4

Remote :: struct {
	used:      bool,
	id:        Product_User_Id,
	id_str:    [PRODUCTUSERID_MAX_LENGTH + 1]u8,
	network:   Network_Connection_Type,
	connected: bool,
	reasm:     Reasm,
}

Init_Options :: struct {
	lib_dirs:        []string, // where to look for the SDK library; empty = default_lib_dirs()
	product_name:    string,
	product_version: string,
	cache_dir:       string, // EOS cache; empty = <tmp>/unified-eos
	relay_control:   Maybe(Relay_Control), // default Allow_Relays
}

Online :: struct {
	mu:             sync.Mutex,
	ctx:            runtime.Context,
	api:            Api,
	platform:       H_Platform,
	connect:        H_Connect,
	p2p:            H_P2P,
	lobby:          H_Lobby,
	relay_control:  Relay_Control,
	stage:          Stage,
	role:           Role,
	detail:         [160]u8,
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
	bucket:         [64]u8,
	code:           Code,
	lobby_id:       [128]u8,
	in_lobby:       bool,
	host:           Product_User_Id,
	socket:         P2P_Socket_Id,
	notify_req:     Notification_Id,
	notify_est:     Notification_Id,
	notify_closed:  Notification_Id,
	remotes:        [MAX_REMOTES]Remote,
	next_frag:      u16,
	last_tick_us:   i64,
	sent, received: int,
	send_errors:    int,
}

@(private)
g: Online

// --- public API ---------------------------------------------------------------------------------

// The directories searched for the SDK library when none are given: $UNIFIED_EOS_LIB_DIR, the
// executable's directory, then (dev builds on the machine that built them) the SDK staged in this
// repo by tools/eos.py.
default_lib_dirs :: proc(allocator := context.temp_allocator) -> []string {
	dirs := make([dynamic]string, allocator)
	if d := os.get_env("UNIFIED_EOS_LIB_DIR", allocator); d != "" {
		append(&dirs, d)
	}
	if exe, err := os.get_executable_directory(allocator); err == nil {
		append(&dirs, exe)
	}
	append(&dirs, STAGED_SDK_BIN)
	return dirs[:]
}

// Loads the SDK and creates the platform. Safe to call again (returns the first result). On
// failure, `status` says why and online play stays off.
init :: proc(opts: Init_Options) -> bool {
	o := &g
	sync.guard(&o.mu)
	if o.stage != .Off {
		return true
	}
	if o.platform != nil || o.detail_len > 0 {
		return false // a previous init failed
	}
	o.ctx = runtime.default_context()
	o.relay_control = opts.relay_control.? or_else .Allow_Relays
	dirs := opts.lib_dirs
	if len(dirs) == 0 {
		dirs = default_lib_dirs()
	}
	loaded := false
	for d in dirs {
		path, _ := filepath.join({d, LIB_NAME}, context.temp_allocator)
		if !os.exists(path) {
			continue
		}
		if api_load(&o.api, path) {
			copy(o.lib_path[:len(o.lib_path) - 1], path)
			loaded = true
			break
		}
		set_detail(o, "%s: cannot load it or a symbol is missing (SDK too old?)", path)
		return false
	}
	if !loaded {
		set_detail(o, "%s not found (looked in %s)", LIB_NAME, strings.join(dirs, ", ", context.temp_allocator))
		return false
	}

	creds, source := credentials_load(context.temp_allocator)
	if !credentials_complete(creds) {
		set_detail(
			o,
			"EOS credentials missing (compiled in, EOS_* environment or %s)",
			ini_path(context.temp_allocator),
		)
		return false
	}
	_ = source

	io := Initialize_Options {
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
	if r := o.api.Initialize(&io); r != .Success && r != .AlreadyConfigured {
		set_detail(o, "EOS_Initialize: %s", o.api.EResult_ToString(r))
		return false
	}
	o.api.Logging_SetCallback(on_log)
	o.api.Logging_SetLogLevel(LC_ALL_CATEGORIES, log_level_from_env())

	cache := opts.cache_dir
	if cache == "" {
		cache, _ = filepath.join(
			{os.temp_directory(context.temp_allocator) or_else ".", "unified-eos"},
			context.temp_allocator,
		)
	}
	_ = os.make_directory_all(cache)
	po := Platform_Options {
		api_version = PLATFORM_OPTIONS_API_LATEST,
		product_id = strings.clone_to_cstring(creds.product_id, context.temp_allocator),
		sandbox_id = strings.clone_to_cstring(creds.sandbox_id, context.temp_allocator),
		deployment_id = strings.clone_to_cstring(creds.deployment_id, context.temp_allocator),
		client_credentials = {
			client_id = strings.clone_to_cstring(creds.client_id, context.temp_allocator),
			client_secret = strings.clone_to_cstring(creds.client_secret, context.temp_allocator),
		},
		flags = PF_DISABLE_OVERLAY | PF_DISABLE_SOCIAL_OVERLAY,
		cache_directory = strings.clone_to_cstring(cache, context.temp_allocator),
	}
	o.platform = o.api.Platform_Create(&po)
	if o.platform == nil {
		set_detail(o, "EOS_Platform_Create failed (check the IDs in the credentials)")
		return false
	}
	o.connect = o.api.Platform_GetConnectInterface(o.platform)
	o.p2p = o.api.Platform_GetP2PInterface(o.platform)
	o.lobby = o.api.Platform_GetLobbyInterface(o.platform)
	rc := P2P_Set_Relay_Control_Options {
		api_version   = P2P_SETRELAYCONTROL_API_LATEST,
		relay_control = o.relay_control,
	}
	o.api.P2P_SetRelayControl(o.p2p, &rc)
	o.fresh_device = os.get_env("UNIFIED_EOS_FRESH_DEVICE", context.temp_allocator) == "1"
	o.stage = .Idle
	o.detail_len = 0
	return true
}

// Starts hosting: login if needed, then a lobby for `bucket` (game + protocol version, so
// incompatible builds never meet) with a fresh code. Poll until Ready, then read the code.
host :: proc(bucket: string) -> bool {
	return begin(.Host, bucket, {})
}

// Starts joining the lobby with `code` (as typed: case and dashes don't matter).
join :: proc(bucket: string, code: string) -> bool {
	c, ok := code_parse(code)
	if !ok {
		o := &g
		sync.guard(&o.mu)
		set_detail(o, "%q is not a game code (6 letters and digits)", code)
		if o.stage != .Off {
			o.stage = .Failed
		}
		return false
	}
	return begin(.Join, bucket, c)
}

// Ticks EOS and advances the session. Call it regularly while no link is in use.
poll :: proc() {
	o := &g
	sync.guard(&o.mu)
	tick(o)
}

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

// A snapshot of the session; strings are allocated with `allocator`.
status :: proc(allocator := context.temp_allocator) -> (s: Status) {
	o := &g
	sync.guard(&o.mu)
	s.stage = o.stage
	s.role = o.role
	if o.role != .None && o.code[0] != 0 {
		s.code = strings.clone(string(o.code[:]), allocator)
	}
	s.detail = strings.clone(string(o.detail[:o.detail_len]), allocator)
	s.local = strings.clone(cstr(o.local_str[:]), allocator)
	s.lib = strings.clone(cstr(o.lib_path[:]), allocator)
	for &r, i in o.remotes {
		if !r.used {
			continue
		}
		if r.connected {
			s.peers += 1
		}
		if o.role == .Join && i == 0 {
			s.host = strings.clone(cstr(r.id_str[:]), allocator)
			s.network = r.network
		}
	}
	return
}

// The datagram link over P2P for the netcode (call once Ready). Host: peer i >= 1 is the i-th
// joiner that sent a packet; joiner: peer 0 is the host. The link ticks EOS on every recv that
// finds nothing (at most every TICK_EVERY_US), so the thread running the netcode keeps EOS alive.
link :: proc() -> (l: netcode.Link, ok: bool) {
	o := &g
	sync.guard(&o.mu)
	if o.stage != .Ready {
		return
	}
	return {data = o, send = link_send, recv = link_recv, close = link_close}, true
}

// Leaves the session: destroys (host) or leaves (joiner) the lobby, closes P2P. The login stays.
leave :: proc() {
	o := &g
	sync.guard(&o.mu)
	end_session(o)
}

// Releases the platform; call once at exit. EOS can't be initialized again in this process.
shutdown :: proc() {
	o := &g
	sync.guard(&o.mu)
	if o.platform == nil {
		return
	}
	end_session(o)
	// Let the leave requests go out.
	for _ in 0 ..< 50 {
		o.api.Platform_Tick(o.platform)
		if !o.in_lobby {
			break
		}
		netcode.sleep_ms(10)
	}
	o.api.Platform_Release(o.platform)
	o.api.Shutdown()
	o.platform = nil
	o.stage = .Off
	set_detail(o, "shut down")
}

// --- session state machine ----------------------------------------------------------------------

@(private)
begin :: proc(role: Role, bucket: string, code: Code) -> bool {
	o := &g
	sync.guard(&o.mu)
	if o.stage == .Off {
		return false
	}
	if o.stage != .Idle && o.stage != .Failed {
		end_session(o)
	}
	o.role = role
	o.code = code
	o.bucket = {}
	copy(o.bucket[:len(o.bucket) - 1], bucket)
	o.detail_len = 0
	if o.local == nil {
		o.stage = .Login
		if !o.login_busy {
			start_login(o)
		}
	} else {
		start_lobby(o)
	}
	return true
}

@(private)
tick :: proc(o: ^Online) {
	if o.platform == nil {
		return
	}
	o.api.Platform_Tick(o.platform)
	pump_main_run_loop()
	o.last_tick_us = netcode.now_us()
}

@(private)
fail :: proc(o: ^Online, format: string, args: ..any) {
	set_detail(o, format, ..args)
	o.stage = .Failed
	log_line("session failed: %s", string(o.detail[:o.detail_len]))
}

@(private)
start_login :: proc(o: ^Online) {
	o.login_busy = true
	if o.fresh_device {
		// Test aid: a brand-new device ID gives this process its own Product User ID, so two
		// processes on one machine can play each other.
		o.fresh_device = false
		do_ := Connect_Delete_Device_Id_Options {
			api_version = CONNECT_DELETEDEVICEID_API_LATEST,
		}
		o.api.Connect_DeleteDeviceId(o.connect, &do_, o, on_device_deleted)
		return
	}
	name := os.get_env("UNIFIED_EOS_NAME", context.temp_allocator)
	if name == "" {
		name = "player"
	}
	creds := Connect_Credentials {
		api_version = CONNECT_CREDENTIALS_API_LATEST,
		type        = ECT_DEVICEID_ACCESS_TOKEN,
	}
	info := Connect_User_Login_Info {
		api_version  = CONNECT_USERLOGININFO_API_LATEST,
		display_name = strings.clone_to_cstring(name[:min(len(name), 32)], context.temp_allocator),
	}
	lo := Connect_Login_Options {
		api_version     = CONNECT_LOGIN_API_LATEST,
		credentials     = &creds,
		user_login_info = &info,
	}
	o.api.Connect_Login(o.connect, &lo, o, on_login)
}

@(private)
on_device_deleted :: proc "c" (info: ^Result_Callback_Info) {
	o := (^Online)(info.client_data)
	context = o.ctx
	log_line("device ID deleted: %s", o.api.EResult_ToString(info.result_code))
	create_device_id(o)
}

@(private)
create_device_id :: proc(o: ^Online) {
	o.device_tries += 1
	model := os.get_env("UNIFIED_EOS_DEVICE_MODEL", context.temp_allocator)
	if model == "" {
		model = ODIN_OS == .Windows ? "Windows PC" : ODIN_OS == .Darwin ? "Mac" : "Linux PC"
	}
	co := Connect_Create_Device_Id_Options {
		api_version  = CONNECT_CREATEDEVICEID_API_LATEST,
		device_model = strings.clone_to_cstring(model, context.temp_allocator),
	}
	o.api.Connect_CreateDeviceId(o.connect, &co, o, on_device_created)
}

@(private)
on_device_created :: proc "c" (info: ^Result_Callback_Info) {
	o := (^Online)(info.client_data)
	context = o.ctx
	log_line("device ID: %s", o.api.EResult_ToString(info.result_code))
	if info.result_code != .Success && info.result_code != .DuplicateNotAllowed {
		o.login_busy = false
		fail(o, "creating a device ID: %s", o.api.EResult_ToString(info.result_code))
		return
	}
	start_login(o)
}

@(private)
on_login :: proc "c" (info: ^Connect_Login_Callback_Info) {
	o := (^Online)(info.client_data)
	context = o.ctx
	if info.result_code != .Success {
		log_line("login: %s", o.api.EResult_ToString(info.result_code))
	}
	#partial switch info.result_code {
	case .Success:
		logged_in(o, info.local_user_id)
	case .NotFound:
		// No device ID on this machine yet.
		if o.device_tries >= 2 {
			o.login_busy = false
			fail(o, "login: no device ID after creating one")
			return
		}
		create_device_id(o)
	case .UnexpectedError:
		// The stored device ID can't be read (macOS: the keychain entry belongs to another build of
		// this binary and prompts are off). The identity is anonymous, so start a fresh one.
		if o.device_tries >= 2 {
			o.login_busy = false
			fail(o, "login: the device ID can't be read or replaced")
			return
		}
		o.fresh_device = true
		start_login(o)
	case .InvalidUser:
		// First login with this device ID: create the product user.
		cu := Connect_Create_User_Options {
			api_version       = CONNECT_CREATEUSER_API_LATEST,
			continuance_token = info.continuance_token,
		}
		o.api.Connect_CreateUser(o.connect, &cu, o, on_user_created)
	case:
		o.login_busy = false
		fail(o, "login: %s", o.api.EResult_ToString(info.result_code))
	}
}

@(private)
on_user_created :: proc "c" (info: ^Connect_Create_User_Callback_Info) {
	o := (^Online)(info.client_data)
	context = o.ctx
	if info.result_code != .Success {
		o.login_busy = false
		fail(o, "creating the user: %s", o.api.EResult_ToString(info.result_code))
		return
	}
	logged_in(o, info.local_user_id)
}

@(private)
logged_in :: proc(o: ^Online, id: Product_User_Id) {
	first := o.local == nil
	o.local = id
	o.login_busy = false
	id_to_string(o, id, o.local_str[:])
	if first {
		log_line("logged in as %s", cstr(o.local_str[:]))
		ao := Connect_Add_Notify_Auth_Expiration_Options {
			api_version = CONNECT_ADDNOTIFYAUTHEXPIRATION_API_LATEST,
		}
		o.notify_auth = o.api.Connect_AddNotifyAuthExpiration(o.connect, &ao, o, on_auth_expiring)
		mo := Version_Options {
			api_version = LOBBY_ADDNOTIFYLOBBYMEMBERSTATUSRECEIVED_API_LATEST,
		}
		o.notify_member = o.api.Lobby_AddNotifyLobbyMemberStatusReceived(o.lobby, &mo, o, on_member_status)
	}
	if o.stage == .Login {
		start_lobby(o)
	}
}

@(private)
on_auth_expiring :: proc "c" (info: ^Connect_Auth_Expiration_Callback_Info) {
	o := (^Online)(info.client_data)
	context = o.ctx
	// The access token lasts about an hour; refreshing is just logging in again.
	if !o.login_busy {
		start_login(o)
	}
}

@(private)
start_lobby :: proc(o: ^Online) {
	o.stage = .Lobby
	if o.role == .Host {
		o.code = code_new()
		open_socket(o)
		co := Lobby_Create_Lobby_Options {
			api_version            = LOBBY_CREATELOBBY_API_LATEST,
			local_user_id          = o.local,
			max_lobby_members      = MAX_MEMBERS,
			permission_level       = .Public_Advertised,
			bucket_id              = cstring(&o.bucket[0]),
			disable_host_migration = true,
		}
		o.api.Lobby_CreateLobby(o.lobby, &co, o, on_lobby_created)
		set_detail(o, "creating the lobby")
		return
	}
	search: H_Lobby_Search
	so := Lobby_Create_Lobby_Search_Options {
		api_version = LOBBY_CREATELOBBYSEARCH_API_LATEST,
		max_results = 2,
	}
	if r := o.api.Lobby_CreateLobbySearch(o.lobby, &so, &search); r != .Success {
		fail(o, "lobby search: %s", o.api.EResult_ToString(r))
		return
	}
	code_c := strings.clone_to_cstring(string(o.code[:]), context.temp_allocator)
	params := [2]Lobby_Attribute_Data {
		{
			api_version = LOBBY_ATTRIBUTEDATA_API_LATEST,
			key = LOBBY_SEARCH_BUCKET_ID,
			value = {as_utf8 = cstring(&o.bucket[0])},
			value_type = .String,
		},
		{
			api_version = LOBBY_ATTRIBUTEDATA_API_LATEST,
			key = ATTR_CODE,
			value = {as_utf8 = code_c},
			value_type = .String,
		},
	}
	for &p in params {
		sp := Lobby_Search_Set_Parameter_Options {
			api_version   = LOBBYSEARCH_SETPARAMETER_API_LATEST,
			parameter     = &p,
			comparison_op = CO_EQUAL,
		}
		if r := o.api.LobbySearch_SetParameter(search, &sp); r != .Success {
			o.api.LobbySearch_Release(search)
			fail(o, "lobby search parameter: %s", o.api.EResult_ToString(r))
			return
		}
	}
	fo := Lobby_Search_Find_Options {
		api_version   = LOBBYSEARCH_FIND_API_LATEST,
		local_user_id = o.local,
	}
	pending_search = search
	o.api.LobbySearch_Find(search, &fo, o, on_search_done)
	set_detail(o, "looking for game %s", string(o.code[:]))
}

ATTR_CODE :: "code"

// The search handle in flight (one at a time; guarded by the mutex like everything else).
@(private)
pending_search: H_Lobby_Search

@(private)
on_lobby_created :: proc "c" (info: ^Lobby_Callback_Info) {
	o := (^Online)(info.client_data)
	context = o.ctx
	if info.result_code != .Success {
		fail(o, "creating the lobby: %s", o.api.EResult_ToString(info.result_code))
		return
	}
	o.in_lobby = true
	o.lobby_id = {}
	copy(o.lobby_id[:len(o.lobby_id) - 1], string(info.lobby_id))
	if o.stage != .Lobby || o.role != .Host {
		end_session(o) // left while the request was in flight
		return
	}
	mod: H_Lobby_Modification
	mo := Lobby_User_Lobby_Options {
		api_version   = LOBBY_UPDATELOBBYMODIFICATION_API_LATEST,
		local_user_id = o.local,
		lobby_id      = cstring(&o.lobby_id[0]),
	}
	if r := o.api.Lobby_UpdateLobbyModification(o.lobby, &mo, &mod); r != .Success {
		fail(o, "lobby modification: %s", o.api.EResult_ToString(r))
		return
	}
	defer o.api.LobbyModification_Release(mod)
	code_c := strings.clone_to_cstring(string(o.code[:]), context.temp_allocator)
	attr := Lobby_Attribute_Data {
		api_version = LOBBY_ATTRIBUTEDATA_API_LATEST,
		key = ATTR_CODE,
		value = {as_utf8 = code_c},
		value_type = .String,
	}
	ao := Lobby_Modification_Add_Attribute_Options {
		api_version = LOBBYMODIFICATION_ADDATTRIBUTE_API_LATEST,
		attribute   = &attr,
		visibility  = LA_PUBLIC,
	}
	if r := o.api.LobbyModification_AddAttribute(mod, &ao); r != .Success {
		fail(o, "lobby code attribute: %s", o.api.EResult_ToString(r))
		return
	}
	uo := Lobby_Update_Lobby_Options {
		api_version               = LOBBY_UPDATELOBBY_API_LATEST,
		lobby_modification_handle = mod,
	}
	o.api.Lobby_UpdateLobby(o.lobby, &uo, o, on_lobby_updated)
}

@(private)
on_lobby_updated :: proc "c" (info: ^Lobby_Callback_Info) {
	o := (^Online)(info.client_data)
	context = o.ctx
	if o.stage != .Lobby {
		return
	}
	if info.result_code != .Success {
		fail(o, "publishing the lobby code: %s", o.api.EResult_ToString(info.result_code))
		return
	}
	o.stage = .Ready
	set_detail(o, "hosting game %s", string(o.code[:]))
	log_line("hosting game %s (lobby %s)", string(o.code[:]), cstr(o.lobby_id[:]))
}

@(private)
on_search_done :: proc "c" (info: ^Result_Callback_Info) {
	o := (^Online)(info.client_data)
	context = o.ctx
	search := pending_search
	pending_search = nil
	defer o.api.LobbySearch_Release(search)
	if o.stage != .Lobby || o.role != .Join {
		return
	}
	count: u32
	if info.result_code == .Success {
		co := Version_Options {
			api_version = LOBBYSEARCH_GETSEARCHRESULTCOUNT_API_LATEST,
		}
		count = o.api.LobbySearch_GetSearchResultCount(search, &co)
	} else if info.result_code != .NotFound {
		fail(o, "lobby search: %s", o.api.EResult_ToString(info.result_code))
		return
	}
	if count == 0 {
		fail(o, "no game with code %s", string(o.code[:]))
		return
	}
	details: H_Lobby_Details
	ro := Lobby_Search_Copy_Search_Result_By_Index_Options {
		api_version = LOBBYSEARCH_COPYSEARCHRESULTBYINDEX_API_LATEST,
	}
	if r := o.api.LobbySearch_CopySearchResultByIndex(search, &ro, &details); r != .Success {
		fail(o, "lobby search result: %s", o.api.EResult_ToString(r))
		return
	}
	defer o.api.LobbyDetails_Release(details)
	oo := Version_Options {
		api_version = LOBBYDETAILS_GETLOBBYOWNER_API_LATEST,
	}
	o.host = o.api.LobbyDetails_GetLobbyOwner(details, &oo)
	if o.host == nil {
		fail(o, "the game has no host")
		return
	}
	jo := Lobby_Join_Lobby_Options {
		api_version          = LOBBY_JOINLOBBY_API_LATEST,
		lobby_details_handle = details,
		local_user_id        = o.local,
	}
	o.api.Lobby_JoinLobby(o.lobby, &jo, o, on_lobby_joined)
	set_detail(o, "joining game %s", string(o.code[:]))
}

@(private)
on_lobby_joined :: proc "c" (info: ^Lobby_Callback_Info) {
	o := (^Online)(info.client_data)
	context = o.ctx
	if info.result_code != .Success {
		if o.stage == .Lobby {
			fail(o, "joining the game: %s", o.api.EResult_ToString(info.result_code))
		}
		return
	}
	o.in_lobby = true
	o.lobby_id = {}
	copy(o.lobby_id[:len(o.lobby_id) - 1], string(info.lobby_id))
	if o.stage != .Lobby || o.role != .Join {
		end_session(o)
		return
	}
	open_socket(o)
	r := &o.remotes[0]
	r^ = {
		used = true,
		id   = o.host,
	}
	id_to_string(o, o.host, r.id_str[:])
	o.stage = .Ready
	set_detail(o, "joined game %s", string(o.code[:]))
	log_line("joined game %s, host %s", string(o.code[:]), cstr(r.id_str[:]))
}

@(private)
on_member_status :: proc "c" (info: ^Lobby_Member_Status_Received_Callback_Info) {
	o := (^Online)(info.client_data)
	context = o.ctx
	if !o.in_lobby || string(info.lobby_id) != cstr(o.lobby_id[:]) {
		return
	}
	buf: [PRODUCTUSERID_MAX_LENGTH + 1]u8
	id_to_string(o, info.target_user_id, buf[:])
	log_line("lobby member %s: %v", cstr(buf[:]), info.current_status)
	if o.role == .Join && o.stage == .Ready {
		host_gone := info.current_status == .Closed
		if info.current_status == .Left || info.current_status == .Disconnected {
			host_gone = cstr(buf[:]) == cstr(o.remotes[0].id_str[:])
		}
		if host_gone {
			o.in_lobby = false
			fail(o, "the host closed the game")
		}
	}
}

// P2P socket for this session: "unified-<code>", so packets of an old session never mix in.
@(private)
open_socket :: proc(o: ^Online) {
	o.socket = {
		api_version = P2P_SOCKETID_API_LATEST,
	}
	name := fmt.bprintf(
		o.socket.socket_name[:P2P_SOCKETID_SOCKETNAME_SIZE - 1],
		"%s%s",
		SOCKET_PREFIX,
		string(o.code[:]),
	)
	_ = name
	so := P2P_Socket_Options {
		api_version   = P2P_ADDNOTIFYPEERCONNECTIONREQUEST_API_LATEST,
		local_user_id = o.local,
		socket_id     = &o.socket,
	}
	o.notify_req = o.api.P2P_AddNotifyPeerConnectionRequest(o.p2p, &so, o, on_connection_request)
	so.api_version = P2P_ADDNOTIFYPEERCONNECTIONESTABLISHED_API_LATEST
	o.notify_est = o.api.P2P_AddNotifyPeerConnectionEstablished(o.p2p, &so, o, on_connection_established)
	so.api_version = P2P_ADDNOTIFYPEERCONNECTIONCLOSED_API_LATEST
	o.notify_closed = o.api.P2P_AddNotifyPeerConnectionClosed(o.p2p, &so, o, on_connection_closed)
	qo := P2P_Set_Packet_Queue_Size_Options {
		api_version                          = P2P_SETPACKETQUEUESIZE_API_LATEST,
		incoming_packet_queue_max_size_bytes = 4 << 20,
		outgoing_packet_queue_max_size_bytes = 4 << 20,
	}
	o.api.P2P_SetPacketQueueSize(o.p2p, &qo)
}

@(private)
on_connection_request :: proc "c" (info: ^P2P_On_Incoming_Connection_Request_Info) {
	o := (^Online)(info.client_data)
	context = o.ctx
	if o.stage != .Ready {
		return
	}
	// The joiner only talks to the host.
	if o.role == .Join && !same_user(o, info.remote_user_id, &o.remotes[0]) {
		return
	}
	ao := P2P_Accept_Connection_Options {
		api_version    = P2P_ACCEPTCONNECTION_API_LATEST,
		local_user_id  = o.local,
		remote_user_id = info.remote_user_id,
		socket_id      = &o.socket,
	}
	r := o.api.P2P_AcceptConnection(o.p2p, &ao)
	if r != .Success {
		log_line("accepting a P2P connection: %s", o.api.EResult_ToString(r))
	}
}

@(private)
on_connection_established :: proc "c" (info: ^P2P_On_Peer_Connection_Established_Info) {
	o := (^Online)(info.client_data)
	context = o.ctx
	i := remote_index(o, info.remote_user_id, o.role == .Host)
	if i < 0 {
		return
	}
	r := &o.remotes[i]
	r.connected = true
	r.network = info.network_type
	log_line("P2P connected to %s (%v)", cstr(r.id_str[:]), info.network_type)
}

@(private)
on_connection_closed :: proc "c" (info: ^P2P_On_Remote_Connection_Closed_Info) {
	o := (^Online)(info.client_data)
	context = o.ctx
	i := remote_index(o, info.remote_user_id, false)
	if i < 0 {
		return
	}
	o.remotes[i].connected = false
	log_line("P2P connection to %s closed (reason %d)", cstr(o.remotes[i].id_str[:]), info.reason)
}

@(private)
end_session :: proc(o: ^Online) {
	if o.platform == nil {
		return
	}
	if o.socket.api_version != 0 {
		so := P2P_Socket_Options {
			api_version   = P2P_CLOSECONNECTIONS_API_LATEST,
			local_user_id = o.local,
			socket_id     = &o.socket,
		}
		o.api.P2P_CloseConnections(o.p2p, &so)
		o.api.P2P_RemoveNotifyPeerConnectionRequest(o.p2p, o.notify_req)
		o.api.P2P_RemoveNotifyPeerConnectionEstablished(o.p2p, o.notify_est)
		o.api.P2P_RemoveNotifyPeerConnectionClosed(o.p2p, o.notify_closed)
		o.socket = {}
	}
	if o.in_lobby {
		lo := Lobby_User_Lobby_Options {
			local_user_id = o.local,
			lobby_id      = cstring(&o.lobby_id[0]),
		}
		if o.role == .Host {
			lo.api_version = LOBBY_DESTROYLOBBY_API_LATEST
			o.api.Lobby_DestroyLobby(o.lobby, &lo, o, on_lobby_left)
		} else {
			lo.api_version = LOBBY_LEAVELOBBY_API_LATEST
			o.api.Lobby_LeaveLobby(o.lobby, &lo, o, on_lobby_left)
		}
	}
	o.remotes = {}
	o.host = nil
	o.role = .None
	o.code = {}
	if o.stage != .Off && o.stage != .Login {
		o.stage = .Idle
	}
}

@(private)
on_lobby_left :: proc "c" (info: ^Lobby_Callback_Info) {
	o := (^Online)(info.client_data)
	context = o.ctx
	if string(info.lobby_id) == cstr(o.lobby_id[:]) {
		o.in_lobby = false
	}
	log_line("left lobby %s: %s", string(info.lobby_id), o.api.EResult_ToString(info.result_code))
}

// --- the link -----------------------------------------------------------------------------------

@(private)
link_send :: proc(data: rawptr, to: netcode.Peer, bytes: []u8) {
	o := (^Online)(data)
	sync.guard(&o.mu)
	if o.stage != .Ready || int(to) < 0 || int(to) >= MAX_REMOTES || !o.remotes[to].used {
		return
	}
	Ctx :: struct {
		o:  ^Online,
		to: Product_User_Id,
	}
	c := Ctx{o, o.remotes[to].id}
	frame_split(bytes, &o.next_frag, proc(user: rawptr, pkt: []u8) {
			c := (^Ctx)(user)
			send_packet(c.o, c.to, pkt)
		}, &c)
}

@(private)
send_packet :: proc(o: ^Online, to: Product_User_Id, pkt: []u8) {
	so := P2P_Send_Packet_Options {
		api_version            = P2P_SENDPACKET_API_LATEST,
		local_user_id          = o.local,
		remote_user_id         = to,
		socket_id              = &o.socket,
		channel                = 0,
		data_length_bytes      = u32(len(pkt)),
		data                   = raw_data(pkt),
		allow_delayed_delivery = true,
		reliability            = .Unreliable_Unordered,
	}
	if r := o.api.P2P_SendPacket(o.p2p, &so); r != .Success {
		o.send_errors += 1
		if o.send_errors < 10 {
			log_line("P2P send: %s", o.api.EResult_ToString(r))
		}
		return
	}
	o.sent += 1
}

@(private)
link_recv :: proc(data: rawptr, buf: []u8) -> (n: int, from: netcode.Peer, ok: bool) {
	o := (^Online)(data)
	sync.guard(&o.mu)
	if o.platform == nil {
		return
	}
	for attempt in 0 ..< 2 {
		for {
			if o.stage != .Ready {
				break
			}
			pkt: [P2P_MAX_PACKET]u8
			peer: Product_User_Id
			sock: P2P_Socket_Id
			channel: u8
			written: u32
			ro := P2P_Receive_Packet_Options {
				api_version         = P2P_RECEIVEPACKET_API_LATEST,
				local_user_id       = o.local,
				max_data_size_bytes = P2P_MAX_PACKET,
			}
			r := o.api.P2P_ReceivePacket(o.p2p, &ro, &peer, &sock, &channel, &pkt[0], &written)
			if r != .Success {
				break
			}
			if cstr(sock.socket_name[:]) != cstr(o.socket.socket_name[:]) {
				continue
			}
			i := remote_index(o, peer, o.role == .Host)
			if i < 0 {
				continue
			}
			o.received += 1
			if nn, done := frame_join(&o.remotes[i].reasm, pkt[:written], buf); done {
				return nn, netcode.Peer(i), true
			}
		}
		if attempt == 0 && netcode.now_us() - o.last_tick_us >= TICK_EVERY_US {
			tick(o)
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

// --- helpers ------------------------------------------------------------------------------------

// The remote slot of `id`, or -1. The host adds unknown users (from index 1, like the UDP relay)
// when `add` is set.
@(private)
remote_index :: proc(o: ^Online, id: Product_User_Id, add: bool) -> int {
	for &r, i in o.remotes {
		if r.used && same_user(o, id, &r) {
			return i
		}
	}
	if !add || o.role != .Host {
		return -1
	}
	for i in 1 ..< MAX_REMOTES {
		r := &o.remotes[i]
		if !r.used {
			r^ = {
				used = true,
				id   = id,
			}
			id_to_string(o, id, r.id_str[:])
			log_line("peer %d = %s", i, cstr(r.id_str[:]))
			return i
		}
	}
	return -1
}

@(private)
same_user :: proc(o: ^Online, id: Product_User_Id, r: ^Remote) -> bool {
	if id == r.id {
		return true
	}
	buf: [PRODUCTUSERID_MAX_LENGTH + 1]u8
	id_to_string(o, id, buf[:])
	return cstr(buf[:]) == cstr(r.id_str[:])
}

@(private)
id_to_string :: proc(o: ^Online, id: Product_User_Id, out: []u8) {
	for &b in out {
		b = 0
	}
	n := i32(len(out))
	if o.api.ProductUserId_ToString(id, raw_data(out), &n) != .Success {
		out[0] = 0
	}
}

@(private)
cstr :: proc(b: []u8) -> string {
	for c, i in b {
		if c == 0 {
			return string(b[:i])
		}
	}
	return string(b)
}

@(private)
set_detail :: proc(o: ^Online, format: string, args: ..any) {
	s := fmt.bprintf(o.detail[:], format, ..args)
	o.detail_len = len(s)
}

@(private)
log_line :: proc(format: string, args: ..any) {
	fmt.eprint("[eos] ")
	fmt.eprintfln(format, ..args)
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
	context = g.ctx
	fmt.eprintfln("[eos sdk %v] %s: %s", msg.level, msg.category, msg.message)
}
