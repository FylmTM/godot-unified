// unified:eos's lobby/login state machine against a fake SDK (Init_Options.sdk): no library, no network.
// The fake answers every request through a callback fired inside Platform_Tick, as EOS does. Sessions run
// on threads that exit before the next one starts (as godot_host's session threads do), so callbacks must
// never use a context captured on an earlier thread.
package test_eos

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

import "unified:eos"

@(private = "file")
Pending_Kind :: enum {
	Login,
	Lobby, // Lobby_Callback_Info: create, update, join, leave, destroy
	Result, // Result_Callback_Info: search
	Established, // a P2P connection came up (with `user`)
	Closed, // a P2P connection closed (with `user`)
	Request, // `user` asks the host for a P2P connection
	Member, // a lobby member status (`user`, `status`)
}

@(private = "file")
Pending :: struct {
	kind:        Pending_Kind,
	callback:    rawptr,
	client_data: rawptr,
	result:      eos.Result,
	lobby:       [32]u8,
	user:        int, // Established, Closed, Request, Member: the index into fake.users (0: means the owner)
	status:      eos.Lobby_Member_Status,
}

@(private = "file")
fake: struct {
	mu:                 sync.Mutex,
	queue:              [64]Pending,
	queued:             int,
	hold:               bool, // queue callbacks without firing them
	fail_create:        bool, // the next CreateLobby fails
	lobbies:            int,
	created, destroyed: [dynamic]string,
	left:               int,
	initialized:        int,
	shut_down:          int,
	released:           int,
	product_version:    string,
	last_code:          string, // the attributes the host published
	last_build:         string,
	last_version:       string,
	lobby_build:        cstring, // the attributes a search result has (nil: none)
	lobby_version:      cstring,
	attribute_data:     eos.Lobby_Attribute_Data, // what CopyAttributeByKey hands out
	attribute:          eos.Lobby_Attribute,
	joins:              int, // Lobby_JoinLobby calls
	closed_to_owner:    int, // P2P_CloseConnection calls for the lobby owner
	on_established:     rawptr, // the session's P2P notifications and their client data
	on_closed:          rawptr,
	on_request:         rawptr,
	p2p_data:           rawptr,
	on_member:          rawptr, // the lobby member status notification and its client data
	member_data:        rawptr,
	accepted:           [dynamic]int, // the users P2P_AcceptConnection was called for (fake.users indices)
	users:              [3]u8, // Product_User_Id values point here: [0] = local, [1] = lobby owner (or a joiner), [2] = a stranger
}

@(private = "file")
OWNER :: 1
@(private = "file")
STRANGER :: 2

@(private = "file")
user_id :: proc(index: int) -> eos.Product_User_Id {
	return eos.Product_User_Id(&fake.users[index == 0 ? OWNER : index])
}

@(private = "file")
enqueue :: proc(
	kind: Pending_Kind,
	callback: rawptr,
	client_data: rawptr,
	result: eos.Result,
	lobby := "",
	user := 0,
	status := eos.Lobby_Member_Status.Joined,
) {
	pending := Pending {
		kind        = kind,
		callback    = callback,
		client_data = client_data,
		result      = result,
		user        = user,
		status      = status,
	}
	copy(pending.lobby[:len(pending.lobby) - 1], lobby)
	fake.queue[fake.queued] = pending
	fake.queued += 1
}

@(private = "file")
fire_all :: proc() {
	if fake.hold do return
	batch := fake.queue
	count := fake.queued
	fake.queued = 0
	for &pending in batch[:count] {
		switch pending.kind {
		case .Login:
			info := eos.Connect_Login_Callback_Info {
				result_code   = pending.result,
				client_data   = pending.client_data,
				local_user_id = eos.Product_User_Id(&fake.users[0]),
			}
			(proc "c" (_: ^eos.Connect_Login_Callback_Info))(pending.callback)(&info)
		case .Lobby:
			info := eos.Lobby_Callback_Info {
				result_code = pending.result,
				client_data = pending.client_data,
				lobby_id    = cstring(&pending.lobby[0]),
			}
			(proc "c" (_: ^eos.Lobby_Callback_Info))(pending.callback)(&info)
		case .Result:
			info := eos.Result_Callback_Info {
				result_code = pending.result,
				client_data = pending.client_data,
			}
			(proc "c" (_: ^eos.Result_Callback_Info))(pending.callback)(&info)
		case .Established:
			info := eos.P2P_On_Peer_Connection_Established_Info {
				client_data    = pending.client_data,
				remote_user_id = user_id(pending.user),
				network_type   = .Direct,
			}
			(proc "c" (_: ^eos.P2P_On_Peer_Connection_Established_Info))(pending.callback)(&info)
		case .Closed:
			info := eos.P2P_On_Remote_Connection_Closed_Info {
				client_data    = pending.client_data,
				remote_user_id = user_id(pending.user),
			}
			(proc "c" (_: ^eos.P2P_On_Remote_Connection_Closed_Info))(pending.callback)(&info)
		case .Request:
			info := eos.P2P_On_Incoming_Connection_Request_Info {
				client_data    = pending.client_data,
				remote_user_id = user_id(pending.user),
			}
			(proc "c" (_: ^eos.P2P_On_Incoming_Connection_Request_Info))(pending.callback)(&info)
		case .Member:
			info := eos.Lobby_Member_Status_Received_Callback_Info {
				client_data    = pending.client_data,
				lobby_id       = cstring(&pending.lobby[0]),
				target_user_id = user_id(pending.user),
				current_status = pending.status,
			}
			(proc "c" (_: ^eos.Lobby_Member_Status_Received_Callback_Info))(pending.callback)(&info)
		}
	}
}

@(private = "file")
FAKE := eos.Api {
	Initialize = proc "c" (options: ^eos.Initialize_Options) -> eos.Result {
		context = runtime.default_context()
		fake.initialized += 1
		fake.product_version = strings.clone(string(options.product_version))
		return .Success
	},
	Shutdown = proc "c" () -> eos.Result {fake.shut_down += 1; return .Success},
	EResult_ToString = proc "c" (result: eos.Result) -> cstring {return result == .Success ? "success" : "fake error"},
	ProductUserId_ToString = proc "c" (id: eos.Product_User_Id, out: [^]u8, length: ^i32) -> eos.Result {
		text :=
			(^u8)(id) == &fake.users[0] ? "fakeuser0" : (^u8)(id) == &fake.users[STRANGER] ? "fakestranger" : "fakeowner"
		for i in 0 ..< len(text) do out[i] = text[i]
		out[len(text)] = 0
		length^ = i32(len(text) + 1)
		return .Success
	},
	ProductUserId_IsValid = proc "c" (id: eos.Product_User_Id) -> eos.Bool {return id != nil},
	Logging_SetCallback = proc "c" (callback: proc "c" (msg: ^eos.Log_Message)) -> eos.Result {return .Success},
	Logging_SetLogLevel = proc "c" (category: i32, level: eos.Log_Level) -> eos.Result {return .Success},
	Platform_Create = proc "c" (options: ^eos.Platform_Options) -> eos.H_Platform {return eos.H_Platform(&fake)},
	Platform_Tick = proc "c" (handle: eos.H_Platform) {
		context = runtime.default_context()
		fire_all()
	},
	Platform_Release = proc "c" (handle: eos.H_Platform) {fake.released += 1},
	Platform_GetConnectInterface = proc "c" (handle: eos.H_Platform) -> eos.H_Connect {return eos.H_Connect(handle)},
	Platform_GetP2PInterface = proc "c" (handle: eos.H_Platform) -> eos.H_P2P {return eos.H_P2P(handle)},
	Platform_GetLobbyInterface = proc "c" (handle: eos.H_Platform) -> eos.H_Lobby {return eos.H_Lobby(handle)},
	Connect_Login = proc "c" (
		handle: eos.H_Connect,
		options: ^eos.Connect_Login_Options,
		client_data: rawptr,
		callback: proc "c" (info: ^eos.Connect_Login_Callback_Info),
	) {
		context = runtime.default_context()
		enqueue(.Login, rawptr(callback), client_data, .Success)
	},
	Connect_CreateUser = proc "c" (
		handle: eos.H_Connect,
		options: ^eos.Connect_Create_User_Options,
		client_data: rawptr,
		callback: proc "c" (info: ^eos.Connect_Create_User_Callback_Info),
	) {},
	Connect_CreateDeviceId = proc "c" (
		handle: eos.H_Connect,
		options: ^eos.Connect_Create_Device_Id_Options,
		client_data: rawptr,
		callback: proc "c" (info: ^eos.Result_Callback_Info),
	) {},
	Connect_DeleteDeviceId = proc "c" (
		handle: eos.H_Connect,
		options: ^eos.Connect_Delete_Device_Id_Options,
		client_data: rawptr,
		callback: proc "c" (info: ^eos.Result_Callback_Info),
	) {},
	Connect_AddNotifyAuthExpiration = proc "c" (
		handle: eos.H_Connect,
		options: ^eos.Connect_Add_Notify_Auth_Expiration_Options,
		client_data: rawptr,
		callback: proc "c" (info: ^eos.Connect_Auth_Expiration_Callback_Info),
	) -> eos.Notification_Id {return 1},
	Connect_RemoveNotifyAuthExpiration = proc "c" (handle: eos.H_Connect, id: eos.Notification_Id) {},
	P2P_SendPacket = proc "c" (
		handle: eos.H_P2P,
		options: ^eos.P2P_Send_Packet_Options,
	) -> eos.Result {return .Success},
	P2P_GetNextReceivedPacketSize = proc "c" (
		handle: eos.H_P2P,
		options: ^eos.P2P_Get_Next_Received_Packet_Size_Options,
		size: ^u32,
	) -> eos.Result {return .NotFound},
	P2P_ReceivePacket = proc "c" (
		handle: eos.H_P2P,
		options: ^eos.P2P_Receive_Packet_Options,
		peer: ^eos.Product_User_Id,
		sock: ^eos.P2P_Socket_Id,
		channel: ^u8,
		data: rawptr,
		written: ^u32,
	) -> eos.Result {return .NotFound},
	P2P_AddNotifyPeerConnectionRequest = proc "c" (
		handle: eos.H_P2P,
		options: ^eos.P2P_Socket_Options,
		client_data: rawptr,
		callback: proc "c" (info: ^eos.P2P_On_Incoming_Connection_Request_Info),
	) -> eos.Notification_Id {
		fake.on_request = rawptr(callback)
		return 2
	},
	P2P_RemoveNotifyPeerConnectionRequest = proc "c" (handle: eos.H_P2P, id: eos.Notification_Id) {},
	P2P_AddNotifyPeerConnectionEstablished = proc "c" (
		handle: eos.H_P2P,
		options: ^eos.P2P_Socket_Options,
		client_data: rawptr,
		callback: proc "c" (info: ^eos.P2P_On_Peer_Connection_Established_Info),
	) -> eos.Notification_Id {
		fake.on_established = rawptr(callback)
		fake.p2p_data = client_data
		return 3
	},
	P2P_RemoveNotifyPeerConnectionEstablished = proc "c" (handle: eos.H_P2P, id: eos.Notification_Id) {},
	P2P_AddNotifyPeerConnectionClosed = proc "c" (
		handle: eos.H_P2P,
		options: ^eos.P2P_Socket_Options,
		client_data: rawptr,
		callback: proc "c" (info: ^eos.P2P_On_Remote_Connection_Closed_Info),
	) -> eos.Notification_Id {
		fake.on_closed = rawptr(callback)
		return 4
	},
	P2P_RemoveNotifyPeerConnectionClosed = proc "c" (handle: eos.H_P2P, id: eos.Notification_Id) {},
	P2P_AcceptConnection = proc "c" (handle: eos.H_P2P, options: ^eos.P2P_Accept_Connection_Options) -> eos.Result {
		context = runtime.default_context()
		for i in 0 ..< len(fake.users) {
			if (^u8)(options.remote_user_id) == &fake.users[i] do append(&fake.accepted, i)
		}
		return .Success
	},
	P2P_CloseConnection = proc "c" (handle: eos.H_P2P, options: ^eos.P2P_Accept_Connection_Options) -> eos.Result {
		context = runtime.default_context()
		if (^u8)(options.remote_user_id) == &fake.users[1] && options.socket_id != nil {
			fake.closed_to_owner += 1
			enqueue(.Closed, fake.on_closed, fake.p2p_data, .Success) // EOS reports a local close too
		}
		return .Success
	},
	P2P_CloseConnections = proc "c" (
		handle: eos.H_P2P,
		options: ^eos.P2P_Socket_Options,
	) -> eos.Result {return .Success},
	P2P_SetRelayControl = proc "c" (
		handle: eos.H_P2P,
		options: ^eos.P2P_Set_Relay_Control_Options,
	) -> eos.Result {return .Success},
	P2P_SetPacketQueueSize = proc "c" (
		handle: eos.H_P2P,
		options: ^eos.P2P_Set_Packet_Queue_Size_Options,
	) -> eos.Result {
		return .Success
	},
	Lobby_CreateLobby = proc "c" (
		handle: eos.H_Lobby,
		options: ^eos.Lobby_Create_Lobby_Options,
		client_data: rawptr,
		callback: proc "c" (info: ^eos.Lobby_Callback_Info),
	) {
		context = runtime.default_context()
		if fake.fail_create {
			fake.fail_create = false
			enqueue(.Lobby, rawptr(callback), client_data, .TooManyRequests)
			return
		}
		fake.lobbies += 1
		id := strings.clone(fake_lobby_name(fake.lobbies))
		append(&fake.created, id)
		enqueue(.Lobby, rawptr(callback), client_data, .Success, id)
	},
	Lobby_UpdateLobbyModification = proc "c" (
		handle: eos.H_Lobby,
		options: ^eos.Lobby_User_Lobby_Options,
		out: ^eos.H_Lobby_Modification,
	) -> eos.Result {
		out^ = eos.H_Lobby_Modification(&fake)
		return .Success
	},
	Lobby_UpdateLobby = proc "c" (
		handle: eos.H_Lobby,
		options: ^eos.Lobby_Update_Lobby_Options,
		client_data: rawptr,
		callback: proc "c" (info: ^eos.Lobby_Callback_Info),
	) {
		context = runtime.default_context()
		enqueue(.Lobby, rawptr(callback), client_data, .Success, fake_lobby_name(fake.lobbies))
	},
	Lobby_JoinLobby = proc "c" (
		handle: eos.H_Lobby,
		options: ^eos.Lobby_Join_Lobby_Options,
		client_data: rawptr,
		callback: proc "c" (info: ^eos.Lobby_Callback_Info),
	) {
		context = runtime.default_context()
		fake.joins += 1
		enqueue(.Lobby, rawptr(callback), client_data, .Success, "joined-lobby")
	},
	Lobby_LeaveLobby = proc "c" (
		handle: eos.H_Lobby,
		options: ^eos.Lobby_User_Lobby_Options,
		client_data: rawptr,
		callback: proc "c" (info: ^eos.Lobby_Callback_Info),
	) {
		context = runtime.default_context()
		fake.left += 1
		enqueue(.Lobby, rawptr(callback), client_data, .Success, string(options.lobby_id))
	},
	Lobby_DestroyLobby = proc "c" (
		handle: eos.H_Lobby,
		options: ^eos.Lobby_User_Lobby_Options,
		client_data: rawptr,
		callback: proc "c" (info: ^eos.Lobby_Callback_Info),
	) {
		context = runtime.default_context()
		append(&fake.destroyed, strings.clone(string(options.lobby_id)))
		enqueue(.Lobby, rawptr(callback), client_data, .Success, string(options.lobby_id))
	},
	Lobby_CreateLobbySearch = proc "c" (
		handle: eos.H_Lobby,
		options: ^eos.Lobby_Create_Lobby_Search_Options,
		out: ^eos.H_Lobby_Search,
	) -> eos.Result {
		out^ = eos.H_Lobby_Search(&fake)
		return .Success
	},
	Lobby_AddNotifyLobbyMemberStatusReceived = proc "c" (
		handle: eos.H_Lobby,
		options: ^eos.Version_Options,
		client_data: rawptr,
		callback: proc "c" (info: ^eos.Lobby_Member_Status_Received_Callback_Info),
	) -> eos.Notification_Id {
		fake.on_member = rawptr(callback)
		fake.member_data = client_data
		return 5
	},
	Lobby_RemoveNotifyLobbyMemberStatusReceived = proc "c" (handle: eos.H_Lobby, id: eos.Notification_Id) {},
	LobbyModification_AddAttribute = proc "c" (
		handle: eos.H_Lobby_Modification,
		options: ^eos.Lobby_Modification_Add_Attribute_Options,
	) -> eos.Result {
		context = runtime.default_context()
		value := string(options.attribute.value.as_utf8)
		switch string(options.attribute.key) {
		case "code":
			delete(fake.last_code)
			fake.last_code = strings.clone(value)
		case "build":
			delete(fake.last_build)
			fake.last_build = strings.clone(value)
		case "version":
			delete(fake.last_version)
			fake.last_version = strings.clone(value)
		}
		return .Success
	},
	LobbyModification_Release = proc "c" (handle: eos.H_Lobby_Modification) {},
	LobbySearch_SetParameter = proc "c" (
		handle: eos.H_Lobby_Search,
		options: ^eos.Lobby_Search_Set_Parameter_Options,
	) -> eos.Result {return .Success},
	LobbySearch_Find = proc "c" (
		handle: eos.H_Lobby_Search,
		options: ^eos.Lobby_Search_Find_Options,
		client_data: rawptr,
		callback: proc "c" (info: ^eos.Result_Callback_Info),
	) {
		context = runtime.default_context()
		enqueue(.Result, rawptr(callback), client_data, .Success)
	},
	LobbySearch_GetSearchResultCount = proc "c" (
		handle: eos.H_Lobby_Search,
		options: ^eos.Version_Options,
	) -> u32 {return 1},
	LobbySearch_CopySearchResultByIndex = proc "c" (
		handle: eos.H_Lobby_Search,
		options: ^eos.Lobby_Search_Copy_Search_Result_By_Index_Options,
		out: ^eos.H_Lobby_Details,
	) -> eos.Result {
		out^ = eos.H_Lobby_Details(&fake)
		return .Success
	},
	LobbySearch_Release = proc "c" (handle: eos.H_Lobby_Search) {},
	LobbyDetails_GetLobbyOwner = proc "c" (
		handle: eos.H_Lobby_Details,
		options: ^eos.Version_Options,
	) -> eos.Product_User_Id {
		return eos.Product_User_Id(&fake.users[1])
	},
	LobbyDetails_CopyAttributeByKey = proc "c" (
		handle: eos.H_Lobby_Details,
		options: ^eos.LobbyDetails_Copy_Attribute_By_Key_Options,
		out: ^^eos.Lobby_Attribute,
	) -> eos.Result {
		value: cstring
		switch string(options.attr_key) {
		case "build":
			value = fake.lobby_build
		case "version":
			value = fake.lobby_version
		}
		if value == nil do return .NotFound
		fake.attribute_data = {
			key = options.attr_key,
			value = {as_utf8 = value},
			value_type = .String,
		}
		fake.attribute = {
			data = &fake.attribute_data,
		}
		out^ = &fake.attribute
		return .Success
	},
	Lobby_Attribute_Release = proc "c" (attribute: ^eos.Lobby_Attribute) {},
	LobbyDetails_Release = proc "c" (handle: eos.H_Lobby_Details) {},
}

@(private = "file")
fake_lobby_name :: proc(index: int) -> string {
	return fmt.tprintf("lobby-%d", index)
}

// Pumps for `ms` milliseconds or until the stage leaves Ready.
@(private = "file")
pump_for :: proc(ms: int) {
	deadline := time.tick_now()
	for time.duration_milliseconds(time.tick_since(deadline)) < f64(ms) && eos.status().stage == .Ready {
		eos.pump()
		time.sleep(2 * time.Millisecond)
	}
}

// Pumps until the stage is `want` (or 2 s pass); returns the codes and failures pump reported.
@(private = "file")
pump_until :: proc(want: eos.Stage) -> (stage: eos.Stage, code, failed: string) {
	for _ in 0 ..< 400 {
		report := eos.pump()
		if report.code != "" do code = report.code
		if report.failed != "" do failed = report.failed
		stage = eos.status().stage
		if stage == want do return
		time.sleep(5 * time.Millisecond)
	}
	return
}

@(private = "file")
Host_Run :: struct {
	t:       ^testing.T,
	init:    bool,
	stage:   eos.Stage,
	code:    string,
	stage_2: eos.Stage, // after leave
}

// One hosted session on its own thread, like a godot_host session thread: (init), host, Ready, leave.
@(private = "file")
host_session :: proc(run: ^Host_Run) {
	if run.init {
		ok := eos.init({
			product_name    = "fake",
			product_version = "1.2.3",
			sdk             = &FAKE,
			connect_wait_us = CONNECT_WAIT_MS * 1000,
		})
		testing.expect(run.t, ok, "init with the fake SDK")
	}
	testing.expect(run.t, eos.host(BUILD), "host")
	code: string
	run.stage, code, _ = pump_until(.Ready)
	run.code = strings.clone(code)
	eos.leave()
	run.stage_2 = eos.status().stage
}

@(private = "file")
CONNECT_WAIT_MS :: 20 // the joiner's P2P wait, shortened

@(private = "file")
BUILD :: eos.Build{"fake", 0x1234, "1.2.3"}

// The whole session state machine in one test: EOS is per process and can't be initialized again.
@(test)
session_state_machine :: proc(t: ^testing.T) {
	// the fake allocates in its callbacks' fresh contexts: the heap, not the test's tracking allocator
	heap := runtime.heap_allocator()
	defer {
		for name in fake.created do delete(name, heap)
		for name in fake.destroyed do delete(name, heap)
		delete(fake.created)
		delete(fake.destroyed)
		delete(fake.product_version, heap)
		delete(fake.last_code, heap)
		delete(fake.last_build, heap)
		delete(fake.last_version, heap)
		fake = {}
	}
	// Two sessions, each on a thread that exits before the next starts.
	runs := [2]Host_Run{{t = t, init = true}, {t = t}}
	for &run in runs {
		worker := thread.create_and_start_with_poly_data(&run, host_session)
		thread.join(worker)
		thread.destroy(worker)
		testing.expect_value(t, run.stage, eos.Stage.Ready)
		testing.expect_value(t, run.stage_2, eos.Stage.Idle)
		testing.expect_value(t, len(run.code), eos.CODE_LEN)
		testing.expect_value(t, run.code, fake.last_code) // the published attribute is the reported code
		testing.expect_value(t, fake.last_build, eos.build_id(BUILD.compat)) // and the build, and its version
		testing.expect_value(t, fake.last_version, BUILD.version)
	}
	testing.expect(t, runs[0].code != runs[1].code, "a new code per session")
	for run in runs do delete(run.code, heap) // cloned on the session threads
	testing.expect_value(t, fake.initialized, 1)
	testing.expect_value(t, fake.product_version, "1.2.3")
	testing.expect_value(t, len(fake.created), 2)
	testing.expect_value(t, len(fake.destroyed), 2) // each leave destroyed its lobby

	// Leave while the lobby request is in flight, host again: the stale lobby is destroyed when it
	// arrives, the new session is unaffected.
	fake.hold = true
	testing.expect(t, eos.host(BUILD))
	eos.leave()
	testing.expect(t, eos.host(BUILD))
	fake.hold = false
	stage, code, _ := pump_until(.Ready)
	testing.expect_value(t, stage, eos.Stage.Ready)
	testing.expect_value(t, code, fake.last_code)
	testing.expect_value(t, len(fake.created), 4)
	testing.expect(t, len(fake.destroyed) == 3 && fake.destroyed[2] == fake.created[2], "the stale lobby is destroyed")
	eos.leave()

	// A failing lobby request: Failed, the reason reported by pump once, then leave returns to Idle.
	fake.fail_create = true
	testing.expect(t, eos.host(BUILD))
	failed: string
	stage, _, failed = pump_until(.Failed)
	testing.expect_value(t, stage, eos.Stage.Failed)
	testing.expect(t, strings.contains(failed, "creating the lobby"), failed)
	testing.expect_value(t, eos.pump().failed, "")
	eos.leave()
	testing.expect_value(t, eos.status().stage, eos.Stage.Idle)

	// #300: the host accepts P2P only from its lobby's members. A stranger who asks is never accepted; a
	// joiner whose request comes before the lobby says it joined is accepted when it does; one who left is
	// held again until it rejoins.
	testing.expect(t, eos.host(BUILD))
	stage, _, _ = pump_until(.Ready)
	testing.expect_value(t, stage, eos.Stage.Ready)
	lobby := fake_lobby_name(fake.lobbies)
	member :: proc(lobby: string, user: int, status: eos.Lobby_Member_Status) {
		enqueue(.Member, fake.on_member, fake.member_data, .Success, lobby, user, status)
		eos.pump()
	}
	request :: proc(user: int) {
		enqueue(.Request, fake.on_request, fake.p2p_data, .Success, user = user)
		eos.pump()
	}
	request(STRANGER)
	request(OWNER)
	testing.expect_value(t, len(fake.accepted), 0)
	member(lobby, OWNER, .Joined)
	testing.expect(t, len(fake.accepted) == 1 && fake.accepted[0] == OWNER, "the held request is accepted on join")
	request(OWNER) // a member's request: accepted at once
	testing.expect_value(t, len(fake.accepted), 2)
	request(STRANGER)
	enqueue(.Established, fake.on_established, fake.p2p_data, .Success, user = STRANGER)
	eos.pump()
	testing.expect_value(t, len(fake.accepted), 2)
	testing.expect_value(t, eos.status().peers, 0) // a stranger's connection never becomes a peer
	member(lobby, OWNER, .Left)
	request(OWNER)
	testing.expect_value(t, len(fake.accepted), 2)
	member(lobby, OWNER, .Joined)
	testing.expect_value(t, len(fake.accepted), 3)
	eos.leave()
	delete(fake.accepted)
	fake.accepted = {}

	// Join: search by code, the lobby owner becomes the host (peer 0); its lobby is this build.
	same_build := strings.clone_to_cstring(eos.build_id(BUILD.compat))
	defer delete(same_build)
	fake.lobby_build, fake.lobby_version = same_build, "1.2.3"
	testing.expect(t, eos.join(BUILD, "ABCDEF"))
	stage, _, _ = pump_until(.Ready)
	testing.expect_value(t, stage, eos.Stage.Ready)
	testing.expect_value(t, eos.status().host, "fakeowner")
	eos.leave()
	testing.expect_value(t, fake.left, 1)

	// #142: the joiner's P2P connection never comes up. Each wait it closes the connection (so the
	// netcode's next packet asks again), and the closes it causes don't reach the netcode as a lost
	// host; after eos.CONNECT_TRIES tries it fails with a clear reason.
	link_events :: proc() -> (count: int) {
		net_link, ok := eos.link()
		if !ok do return
		for {
			if _, _, has := net_link.event(net_link.data); !has do return
			count += 1
		}
	}
	testing.expect(t, eos.join(BUILD, "ABCDEF"))
	stage, _, _ = pump_until(.Ready)
	testing.expect_value(t, stage, eos.Stage.Ready)
	stage, _, failed = pump_until(.Failed)
	testing.expect_value(t, stage, eos.Stage.Failed)
	testing.expect(t, strings.contains(failed, "no connection to the host"), failed)
	testing.expect_value(t, fake.closed_to_owner, eos.CONNECT_TRIES - 1)
	testing.expect_value(t, link_events(), 0)
	eos.leave()

	// A retry that works: the connection comes up after the first close; no more closes, the
	// session stays Ready and the netcode hears the host connect.
	fake.closed_to_owner = 0
	testing.expect(t, eos.join(BUILD, "ABCDEF"))
	stage, _, _ = pump_until(.Ready)
	testing.expect_value(t, stage, eos.Stage.Ready)
	for _ in 0 ..< 400 {
		if fake.closed_to_owner > 0 do break
		eos.pump()
		time.sleep(2 * time.Millisecond)
	}
	testing.expect_value(t, fake.closed_to_owner, 1)
	enqueue(.Established, fake.on_established, fake.p2p_data, .Success)
	pump_for(CONNECT_WAIT_MS * (eos.CONNECT_TRIES + 1))
	testing.expect_value(t, eos.status().stage, eos.Stage.Ready)
	testing.expect_value(t, eos.status().peers, 1)
	testing.expect_value(t, fake.closed_to_owner, 1)
	testing.expect_value(t, link_events(), 1)
	eos.leave()

	// #304: a lobby of another build is not joined; the reason names both versions, or says the build differs
	// when the versions match (or the lobby has no build at all).
	joins := fake.joins
	other_build := strings.clone_to_cstring(eos.build_id(BUILD.compat + 1))
	defer delete(other_build)
	Case :: struct {
		build, version: cstring,
		message:        string,
	}
	cases := [?]Case {
		{other_build, "1.2.4", "that game runs fake 1.2.4; you have 1.2.3"},
		{other_build, "1.2.3", "that game runs a different build of fake 1.2.3"},
		{nil, nil, "that game runs a different build of fake"},
	}
	for test_case in cases {
		fake.lobby_build, fake.lobby_version = test_case.build, test_case.version
		testing.expect(t, eos.join(BUILD, "ABCDEF"))
		stage, _, failed = pump_until(.Failed)
		testing.expect_value(t, stage, eos.Stage.Failed)
		testing.expect_value(t, failed, test_case.message)
		eos.leave()
	}
	testing.expect_value(t, fake.joins, joins) // never joined
	fake.lobby_build, fake.lobby_version = nil, nil

	eos.shutdown()
	testing.expect_value(t, fake.released, 1)
	testing.expect_value(t, fake.shut_down, 1)
}
