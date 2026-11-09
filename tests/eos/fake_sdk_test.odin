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
	cb:          rawptr,
	client_data: rawptr,
	result:      eos.Result,
	lobby:       [32]u8,
}

@(private = "file")
fake: struct {
	mu:                 sync.Mutex,
	queue:              [64]Pending,
	n:                  int,
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
enqueue :: proc(kind: Pending_Kind, cb: rawptr, client_data: rawptr, result: eos.Result, lobby := "") {
	p := Pending {
		kind        = kind,
		cb          = cb,
		client_data = client_data,
		result      = result,
	}
	copy(p.lobby[:len(p.lobby) - 1], lobby)
	fake.queue[fake.n] = p
	fake.n += 1
}

@(private = "file")
fire_all :: proc() {
	if fake.hold do return
	batch := fake.queue
	n := fake.n
	fake.n = 0
	for &p in batch[:n] {
		switch p.kind {
		case .Login:
			info := eos.Connect_Login_Callback_Info {
				result_code   = p.result,
				client_data   = p.client_data,
				local_user_id = eos.Product_User_Id(&fake.users[0]),
			}
			(proc "c" (_: ^eos.Connect_Login_Callback_Info))(p.cb)(&info)
		case .Lobby:
			info := eos.Lobby_Callback_Info {
				result_code = p.result,
				client_data = p.client_data,
				lobby_id    = cstring(&p.lobby[0]),
			}
			(proc "c" (_: ^eos.Lobby_Callback_Info))(p.cb)(&info)
		case .Result:
			info := eos.Result_Callback_Info {
				result_code = p.result,
				client_data = p.client_data,
			}
			(proc "c" (_: ^eos.Result_Callback_Info))(p.cb)(&info)
		}
	}
}

@(private = "file")
FAKE := eos.Api {
	Initialize = proc "c" (o: ^eos.Initialize_Options) -> eos.Result {
		context = runtime.default_context()
		fake.initialized += 1
		fake.product_version = strings.clone(string(o.product_version))
		return .Success
	},
	Shutdown = proc "c" () -> eos.Result {fake.shut_down += 1; return .Success},
	EResult_ToString = proc "c" (r: eos.Result) -> cstring {return r == .Success ? "success" : "fake error"},
	ProductUserId_ToString = proc "c" (id: eos.Product_User_Id, out: [^]u8, n: ^i32) -> eos.Result {
		s := (^u8)(id) == &fake.users[0] ? "fakeuser0" : "fakeowner"
		for i in 0 ..< len(s) do out[i] = s[i]
		out[len(s)] = 0
		n^ = i32(len(s) + 1)
		return .Success
	},
	ProductUserId_IsValid = proc "c" (id: eos.Product_User_Id) -> eos.Bool {return id != nil},
	Logging_SetCallback = proc "c" (cb: proc "c" (msg: ^eos.Log_Message)) -> eos.Result {return .Success},
	Logging_SetLogLevel = proc "c" (category: i32, level: eos.Log_Level) -> eos.Result {return .Success},
	Platform_Create = proc "c" (o: ^eos.Platform_Options) -> eos.H_Platform {return eos.H_Platform(&fake)},
	Platform_Tick = proc "c" (h: eos.H_Platform) {
		context = runtime.default_context()
		fire_all()
	},
	Platform_Release = proc "c" (h: eos.H_Platform) {fake.released += 1},
	Platform_GetConnectInterface = proc "c" (h: eos.H_Platform) -> eos.H_Connect {return eos.H_Connect(h)},
	Platform_GetP2PInterface = proc "c" (h: eos.H_Platform) -> eos.H_P2P {return eos.H_P2P(h)},
	Platform_GetLobbyInterface = proc "c" (h: eos.H_Platform) -> eos.H_Lobby {return eos.H_Lobby(h)},
	Connect_Login = proc "c" (
		h: eos.H_Connect,
		o: ^eos.Connect_Login_Options,
		cd: rawptr,
		cb: proc "c" (info: ^eos.Connect_Login_Callback_Info),
	) {
		context = runtime.default_context()
		enqueue(.Login, rawptr(cb), cd, .Success)
	},
	Connect_CreateUser = proc "c" (
		h: eos.H_Connect,
		o: ^eos.Connect_Create_User_Options,
		cd: rawptr,
		cb: proc "c" (info: ^eos.Connect_Create_User_Callback_Info),
	) {},
	Connect_CreateDeviceId = proc "c" (
		h: eos.H_Connect,
		o: ^eos.Connect_Create_Device_Id_Options,
		cd: rawptr,
		cb: proc "c" (info: ^eos.Result_Callback_Info),
	) {},
	Connect_DeleteDeviceId = proc "c" (
		h: eos.H_Connect,
		o: ^eos.Connect_Delete_Device_Id_Options,
		cd: rawptr,
		cb: proc "c" (info: ^eos.Result_Callback_Info),
	) {},
	Connect_AddNotifyAuthExpiration = proc "c" (
		h: eos.H_Connect,
		o: ^eos.Connect_Add_Notify_Auth_Expiration_Options,
		cd: rawptr,
		cb: proc "c" (info: ^eos.Connect_Auth_Expiration_Callback_Info),
	) -> eos.Notification_Id {return 1},
	Connect_RemoveNotifyAuthExpiration = proc "c" (h: eos.H_Connect, id: eos.Notification_Id) {},
	P2P_SendPacket = proc "c" (h: eos.H_P2P, o: ^eos.P2P_Send_Packet_Options) -> eos.Result {return .Success},
	P2P_GetNextReceivedPacketSize = proc "c" (
		h: eos.H_P2P,
		o: ^eos.P2P_Get_Next_Received_Packet_Size_Options,
		size: ^u32,
	) -> eos.Result {return .NotFound},
	P2P_ReceivePacket = proc "c" (
		h: eos.H_P2P,
		o: ^eos.P2P_Receive_Packet_Options,
		peer: ^eos.Product_User_Id,
		sock: ^eos.P2P_Socket_Id,
		channel: ^u8,
		data: rawptr,
		written: ^u32,
	) -> eos.Result {return .NotFound},
	P2P_AddNotifyPeerConnectionRequest = proc "c" (
		h: eos.H_P2P,
		o: ^eos.P2P_Socket_Options,
		cd: rawptr,
		cb: proc "c" (info: ^eos.P2P_On_Incoming_Connection_Request_Info),
	) -> eos.Notification_Id {return 2},
	P2P_RemoveNotifyPeerConnectionRequest = proc "c" (h: eos.H_P2P, id: eos.Notification_Id) {},
	P2P_AddNotifyPeerConnectionEstablished = proc "c" (
		h: eos.H_P2P,
		o: ^eos.P2P_Socket_Options,
		cd: rawptr,
		cb: proc "c" (info: ^eos.P2P_On_Peer_Connection_Established_Info),
	) -> eos.Notification_Id {return 3},
	P2P_RemoveNotifyPeerConnectionEstablished = proc "c" (h: eos.H_P2P, id: eos.Notification_Id) {},
	P2P_AddNotifyPeerConnectionClosed = proc "c" (
		h: eos.H_P2P,
		o: ^eos.P2P_Socket_Options,
		cd: rawptr,
		cb: proc "c" (info: ^eos.P2P_On_Remote_Connection_Closed_Info),
	) -> eos.Notification_Id {return 4},
	P2P_RemoveNotifyPeerConnectionClosed = proc "c" (h: eos.H_P2P, id: eos.Notification_Id) {},
	P2P_AcceptConnection = proc "c" (
		h: eos.H_P2P,
		o: ^eos.P2P_Accept_Connection_Options,
	) -> eos.Result {return .Success},
	P2P_CloseConnections = proc "c" (h: eos.H_P2P, o: ^eos.P2P_Socket_Options) -> eos.Result {return .Success},
	P2P_SetRelayControl = proc "c" (
		h: eos.H_P2P,
		o: ^eos.P2P_Set_Relay_Control_Options,
	) -> eos.Result {return .Success},
	P2P_SetPacketQueueSize = proc "c" (h: eos.H_P2P, o: ^eos.P2P_Set_Packet_Queue_Size_Options) -> eos.Result {
		return .Success
	},
	Lobby_CreateLobby = proc "c" (
		h: eos.H_Lobby,
		o: ^eos.Lobby_Create_Lobby_Options,
		cd: rawptr,
		cb: proc "c" (info: ^eos.Lobby_Callback_Info),
	) {
		context = runtime.default_context()
		if fake.fail_create {
			fake.fail_create = false
			enqueue(.Lobby, rawptr(cb), cd, .TooManyRequests)
			return
		}
		fake.lobbies += 1
		id := strings.clone(fake_lobby_name(fake.lobbies))
		append(&fake.created, id)
		enqueue(.Lobby, rawptr(cb), cd, .Success, id)
	},
	Lobby_UpdateLobbyModification = proc "c" (
		h: eos.H_Lobby,
		o: ^eos.Lobby_User_Lobby_Options,
		out: ^eos.H_Lobby_Modification,
	) -> eos.Result {
		out^ = eos.H_Lobby_Modification(&fake)
		return .Success
	},
	Lobby_UpdateLobby = proc "c" (
		h: eos.H_Lobby,
		o: ^eos.Lobby_Update_Lobby_Options,
		cd: rawptr,
		cb: proc "c" (info: ^eos.Lobby_Callback_Info),
	) {
		context = runtime.default_context()
		enqueue(.Lobby, rawptr(cb), cd, .Success, fake_lobby_name(fake.lobbies))
	},
	Lobby_JoinLobby = proc "c" (
		h: eos.H_Lobby,
		o: ^eos.Lobby_Join_Lobby_Options,
		cd: rawptr,
		cb: proc "c" (info: ^eos.Lobby_Callback_Info),
	) {
		context = runtime.default_context()
		enqueue(.Lobby, rawptr(cb), cd, .Success, "joined-lobby")
	},
	Lobby_LeaveLobby = proc "c" (
		h: eos.H_Lobby,
		o: ^eos.Lobby_User_Lobby_Options,
		cd: rawptr,
		cb: proc "c" (info: ^eos.Lobby_Callback_Info),
	) {
		context = runtime.default_context()
		fake.left += 1
		enqueue(.Lobby, rawptr(cb), cd, .Success, string(o.lobby_id))
	},
	Lobby_DestroyLobby = proc "c" (
		h: eos.H_Lobby,
		o: ^eos.Lobby_User_Lobby_Options,
		cd: rawptr,
		cb: proc "c" (info: ^eos.Lobby_Callback_Info),
	) {
		context = runtime.default_context()
		append(&fake.destroyed, strings.clone(string(o.lobby_id)))
		enqueue(.Lobby, rawptr(cb), cd, .Success, string(o.lobby_id))
	},
	Lobby_CreateLobbySearch = proc "c" (
		h: eos.H_Lobby,
		o: ^eos.Lobby_Create_Lobby_Search_Options,
		out: ^eos.H_Lobby_Search,
	) -> eos.Result {
		out^ = eos.H_Lobby_Search(&fake)
		return .Success
	},
	Lobby_AddNotifyLobbyMemberStatusReceived = proc "c" (
		h: eos.H_Lobby,
		o: ^eos.Version_Options,
		cd: rawptr,
		cb: proc "c" (info: ^eos.Lobby_Member_Status_Received_Callback_Info),
	) -> eos.Notification_Id {return 5},
	Lobby_RemoveNotifyLobbyMemberStatusReceived = proc "c" (h: eos.H_Lobby, id: eos.Notification_Id) {},
	LobbyModification_AddAttribute = proc "c" (
		h: eos.H_Lobby_Modification,
		o: ^eos.Lobby_Modification_Add_Attribute_Options,
	) -> eos.Result {
		context = runtime.default_context()
		if string(o.attribute.key) == "code" {
			delete(fake.last_code)
			fake.last_code = strings.clone(string(o.attribute.value.as_utf8))
		}
		return .Success
	},
	LobbyModification_Release = proc "c" (h: eos.H_Lobby_Modification) {},
	LobbySearch_SetParameter = proc "c" (
		h: eos.H_Lobby_Search,
		o: ^eos.Lobby_Search_Set_Parameter_Options,
	) -> eos.Result {return .Success},
	LobbySearch_Find = proc "c" (
		h: eos.H_Lobby_Search,
		o: ^eos.Lobby_Search_Find_Options,
		cd: rawptr,
		cb: proc "c" (info: ^eos.Result_Callback_Info),
	) {
		context = runtime.default_context()
		enqueue(.Result, rawptr(cb), cd, .Success)
	},
	LobbySearch_GetSearchResultCount = proc "c" (h: eos.H_Lobby_Search, o: ^eos.Version_Options) -> u32 {return 1},
	LobbySearch_CopySearchResultByIndex = proc "c" (
		h: eos.H_Lobby_Search,
		o: ^eos.Lobby_Search_Copy_Search_Result_By_Index_Options,
		out: ^eos.H_Lobby_Details,
	) -> eos.Result {
		out^ = eos.H_Lobby_Details(&fake)
		return .Success
	},
	LobbySearch_Release = proc "c" (h: eos.H_Lobby_Search) {},
	LobbyDetails_GetLobbyOwner = proc "c" (h: eos.H_Lobby_Details, o: ^eos.Version_Options) -> eos.Product_User_Id {
		return eos.Product_User_Id(&fake.users[1])
	},
	LobbyDetails_Release = proc "c" (h: eos.H_Lobby_Details) {},
}

@(private = "file")
fake_lobby_name :: proc(n: int) -> string {
	return fmt.tprintf("lobby-%d", n)
}

// Pumps until the stage is `want` (or 2 s pass); returns the codes and failures pump reported.
@(private = "file")
pump_until :: proc(want: eos.Stage) -> (stage: eos.Stage, code, failed: string) {
	for _ in 0 ..< 400 {
		r := eos.pump()
		if r.code != "" do code = r.code
		if r.failed != "" do failed = r.failed
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
host_session :: proc(r: ^Host_Run) {
	if r.init {
		ok := eos.init({product_name = "fake", product_version = "1.2.3", sdk = &FAKE})
		testing.expect(r.t, ok, "init with the fake SDK")
	}
	testing.expect(r.t, eos.host("fake-bucket"), "host")
	code: string
	r.stage, code, _ = pump_until(.Ready)
	r.code = strings.clone(code)
	eos.leave()
	r.stage_2 = eos.status().stage
}

@(test)
host_leave_host_on_fresh_threads :: proc(t: ^testing.T) {
	// the fake allocates in its callbacks' fresh contexts: the heap, not the test's tracking allocator
	heap := runtime.heap_allocator()
	defer {
		for s in fake.created do delete(s, heap)
		for s in fake.destroyed do delete(s, heap)
		delete(fake.created)
		delete(fake.destroyed)
		delete(fake.product_version, heap)
		delete(fake.last_code, heap)
		fake = {}
	}
	// Two sessions, each on a thread that exits before the next starts.
	runs := [2]Host_Run{{t = t, init = true}, {t = t}}
	for &r in runs {
		th := thread.create_and_start_with_poly_data(&r, host_session)
		thread.join(th)
		thread.destroy(th)
		testing.expect_value(t, r.stage, eos.Stage.Ready)
		testing.expect_value(t, r.stage_2, eos.Stage.Idle)
		testing.expect_value(t, len(r.code), eos.CODE_LEN)
		testing.expect_value(t, r.code, fake.last_code) // the published attribute is the reported code
	}
	testing.expect(t, runs[0].code != runs[1].code, "a new code per session")
	for r in runs do delete(r.code, heap) // cloned on the session threads
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
