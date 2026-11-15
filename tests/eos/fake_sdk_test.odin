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
}

@(private = "file")
Pending :: struct {
	kind:        Pending_Kind,
	callback:    rawptr,
	client_data: rawptr,
	result:      eos.Result,
	lobby:       [32]u8,
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
	last_code:          string, // the code attribute the host published
	users:              [2]u8, // Product_User_Id values point here: [0] = local, [1] = lobby owner
}

@(private = "file")
enqueue :: proc(kind: Pending_Kind, callback: rawptr, client_data: rawptr, result: eos.Result, lobby := "") {
	pending := Pending {
		kind        = kind,
		callback    = callback,
		client_data = client_data,
		result      = result,
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
		text := (^u8)(id) == &fake.users[0] ? "fakeuser0" : "fakeowner"
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
	) -> eos.Notification_Id {return 2},
	P2P_RemoveNotifyPeerConnectionRequest = proc "c" (handle: eos.H_P2P, id: eos.Notification_Id) {},
	P2P_AddNotifyPeerConnectionEstablished = proc "c" (
		handle: eos.H_P2P,
		options: ^eos.P2P_Socket_Options,
		client_data: rawptr,
		callback: proc "c" (info: ^eos.P2P_On_Peer_Connection_Established_Info),
	) -> eos.Notification_Id {return 3},
	P2P_RemoveNotifyPeerConnectionEstablished = proc "c" (handle: eos.H_P2P, id: eos.Notification_Id) {},
	P2P_AddNotifyPeerConnectionClosed = proc "c" (
		handle: eos.H_P2P,
		options: ^eos.P2P_Socket_Options,
		client_data: rawptr,
		callback: proc "c" (info: ^eos.P2P_On_Remote_Connection_Closed_Info),
	) -> eos.Notification_Id {return 4},
	P2P_RemoveNotifyPeerConnectionClosed = proc "c" (handle: eos.H_P2P, id: eos.Notification_Id) {},
	P2P_AcceptConnection = proc "c" (
		handle: eos.H_P2P,
		options: ^eos.P2P_Accept_Connection_Options,
	) -> eos.Result {return .Success},
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
	) -> eos.Notification_Id {return 5},
	Lobby_RemoveNotifyLobbyMemberStatusReceived = proc "c" (handle: eos.H_Lobby, id: eos.Notification_Id) {},
	LobbyModification_AddAttribute = proc "c" (
		handle: eos.H_Lobby_Modification,
		options: ^eos.Lobby_Modification_Add_Attribute_Options,
	) -> eos.Result {
		context = runtime.default_context()
		if string(options.attribute.key) == "code" {
			delete(fake.last_code)
			fake.last_code = strings.clone(string(options.attribute.value.as_utf8))
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
	LobbyDetails_Release = proc "c" (handle: eos.H_Lobby_Details) {},
}

@(private = "file")
fake_lobby_name :: proc(index: int) -> string {
	return fmt.tprintf("lobby-%d", index)
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
		})
		testing.expect(run.t, ok, "init with the fake SDK")
	}
	testing.expect(run.t, eos.host("fake-bucket"), "host")
	code: string
	run.stage, code, _ = pump_until(.Ready)
	run.code = strings.clone(code)
	eos.leave()
	run.stage_2 = eos.status().stage
}

@(test)
host_leave_host_on_fresh_threads :: proc(t: ^testing.T) {
	// the fake allocates in its callbacks' fresh contexts: the heap, not the test's tracking allocator
	heap := runtime.heap_allocator()
	defer {
		for name in fake.created do delete(name, heap)
		for name in fake.destroyed do delete(name, heap)
		delete(fake.created)
		delete(fake.destroyed)
		delete(fake.product_version, heap)
		delete(fake.last_code, heap)
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
	testing.expect(t, eos.host("fake-bucket"))
	eos.leave()
	testing.expect(t, eos.host("fake-bucket"))
	fake.hold = false
	stage, code, _ := pump_until(.Ready)
	testing.expect_value(t, stage, eos.Stage.Ready)
	testing.expect_value(t, code, fake.last_code)
	testing.expect_value(t, len(fake.created), 4)
	testing.expect(t, len(fake.destroyed) == 3 && fake.destroyed[2] == fake.created[2], "the stale lobby is destroyed")
	eos.leave()

	// A failing lobby request: Failed, the reason reported by pump once, then leave returns to Idle.
	fake.fail_create = true
	testing.expect(t, eos.host("fake-bucket"))
	failed: string
	stage, _, failed = pump_until(.Failed)
	testing.expect_value(t, stage, eos.Stage.Failed)
	testing.expect(t, strings.contains(failed, "creating the lobby"), failed)
	testing.expect_value(t, eos.pump().failed, "")
	eos.leave()
	testing.expect_value(t, eos.status().stage, eos.Stage.Idle)

	// Join: search by code, the lobby owner becomes the host (peer 0).
	testing.expect(t, eos.join("fake-bucket", "ABCDEF"))
	stage, _, _ = pump_until(.Ready)
	testing.expect_value(t, stage, eos.Stage.Ready)
	testing.expect_value(t, eos.status().host, "fakeowner")
	eos.leave()
	testing.expect_value(t, fake.left, 1)

	eos.shutdown()
	testing.expect_value(t, fake.released, 1)
	testing.expect_value(t, fake.shut_down, 1)
}
