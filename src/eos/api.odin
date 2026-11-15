// Bindings for the subset of the EOS C SDK we use: init and platform, logging, Connect (anonymous
// device-ID login), Lobby (create, attribute search, join, leave, member status) and P2P. The SDK
// library is loaded at run time (`api_load`), so nothing links against it and a missing library
// only disables online play. Struct layouts follow the SDK headers for the ApiVersion each struct
// declares; tests/eos checks them against the headers with a C compiler when the SDK is present.
package eos

import "core:dynlib"
import "core:reflect"

when ODIN_OS == .Darwin {
	LIB_NAME :: "libEOSSDK-Mac-Shipping.dylib"
} else when ODIN_OS == .Windows {
	LIB_NAME :: "EOSSDK-Win64-Shipping.dll"
} else when ODIN_ARCH == .arm64 {
	LIB_NAME :: "libEOSSDK-LinuxArm64-Shipping.so"
} else {
	LIB_NAME :: "libEOSSDK-Linux-Shipping.so"
}

// --- common ---------------------------------------------------------------------------------------

Result :: enum i32 {
	Success             = 0,
	NoConnection        = 1,
	InvalidCredentials  = 2,
	InvalidUser         = 3,
	InvalidAuth         = 4,
	AccessDenied        = 5,
	MissingPermissions  = 6,
	TooManyRequests     = 8,
	AlreadyPending      = 9,
	InvalidParameters   = 10,
	InvalidRequest      = 11,
	IncompatibleVersion = 13,
	NotConfigured       = 14,
	AlreadyConfigured   = 15,
	NotImplemented      = 16,
	Canceled            = 17,
	NotFound            = 18,
	OperationWillRetry  = 19,
	NoChange            = 20,
	VersionMismatch     = 21,
	LimitExceeded       = 22,
	Disabled            = 23,
	DuplicateNotAllowed = 24,
	InvalidSandboxId    = 26,
	TimedOut            = 27,
	UnexpectedError     = 0x7FFFFFFF,
}

Bool :: b32
Product_User_Id :: distinct rawptr
Continuance_Token :: distinct rawptr
Notification_Id :: u64
Lobby_Id :: cstring

H_Platform :: distinct rawptr
H_Connect :: distinct rawptr
H_P2P :: distinct rawptr
H_Lobby :: distinct rawptr
H_Lobby_Modification :: distinct rawptr
H_Lobby_Search :: distinct rawptr
H_Lobby_Details :: distinct rawptr

PRODUCTUSERID_MAX_LENGTH :: 32

// --- init, platform, logging ----------------------------------------------------------------------

INITIALIZE_API_LATEST :: 5
Initialize_Options :: struct {
	api_version:                i32,
	allocate_memory_function:   rawptr,
	reallocate_memory_function: rawptr,
	release_memory_function:    rawptr,
	product_name:               cstring,
	product_version:            cstring,
	reserved:                   rawptr,
	system_initialize_options:  rawptr,
	override_thread_affinity:   rawptr,
}

Platform_Client_Credentials :: struct {
	client_id:     cstring,
	client_secret: cstring,
}

PLATFORM_OPTIONS_API_LATEST :: 15
PF_DISABLE_OVERLAY :: 0x2
PF_DISABLE_SOCIAL_OVERLAY :: 0x4
Platform_Options :: struct {
	api_version:                                  i32,
	reserved:                                     rawptr,
	product_id:                                   cstring,
	sandbox_id:                                   cstring,
	client_credentials:                           Platform_Client_Credentials,
	is_server:                                    Bool,
	encryption_key:                               cstring,
	override_country_code:                        cstring,
	override_locale_code:                         cstring,
	deployment_id:                                cstring,
	flags:                                        u64,
	cache_directory:                              cstring,
	tick_budget_in_milliseconds:                  u32,
	rtc_options:                                  rawptr,
	integrated_platform_options_container_handle: rawptr,
	system_specific_options:                      rawptr,
	task_network_timeout_seconds:                 ^f64,
}

Log_Level :: enum i32 {
	Off          = 0,
	Fatal        = 100,
	Error        = 200,
	Warning      = 300,
	Info         = 400,
	Verbose      = 500,
	Very_Verbose = 600,
}
LC_ALL_CATEGORIES :: 0x7fffffff

Log_Message :: struct {
	category: cstring,
	message:  cstring,
	level:    Log_Level,
}

// --- connect --------------------------------------------------------------------------------------

ECT_DEVICEID_ACCESS_TOKEN :: 10

CONNECT_CREDENTIALS_API_LATEST :: 1
Connect_Credentials :: struct {
	api_version: i32,
	token:       cstring,
	type:        i32,
}

CONNECT_USERLOGININFO_API_LATEST :: 2
Connect_User_Login_Info :: struct {
	api_version:  i32,
	display_name: cstring,
	nsa_id_token: cstring,
}

CONNECT_LOGIN_API_LATEST :: 2
Connect_Login_Options :: struct {
	api_version:     i32,
	credentials:     ^Connect_Credentials,
	user_login_info: ^Connect_User_Login_Info,
}

Connect_Login_Callback_Info :: struct {
	result_code:       Result,
	client_data:       rawptr,
	local_user_id:     Product_User_Id,
	continuance_token: Continuance_Token,
}

CONNECT_CREATEUSER_API_LATEST :: 1
Connect_Create_User_Options :: struct {
	api_version:       i32,
	continuance_token: Continuance_Token,
}

Connect_Create_User_Callback_Info :: struct {
	result_code:   Result,
	client_data:   rawptr,
	local_user_id: Product_User_Id,
}

CONNECT_CREATEDEVICEID_API_LATEST :: 1
Connect_Create_Device_Id_Options :: struct {
	api_version:  i32,
	device_model: cstring,
}

CONNECT_DELETEDEVICEID_API_LATEST :: 1
Connect_Delete_Device_Id_Options :: struct {
	api_version: i32,
}

// Create/DeleteDeviceId callbacks carry just these two fields.
Result_Callback_Info :: struct {
	result_code: Result,
	client_data: rawptr,
}

CONNECT_ADDNOTIFYAUTHEXPIRATION_API_LATEST :: 1
Connect_Add_Notify_Auth_Expiration_Options :: struct {
	api_version: i32,
}

Connect_Auth_Expiration_Callback_Info :: struct {
	client_data:   rawptr,
	local_user_id: Product_User_Id,
}

// --- P2P ------------------------------------------------------------------------------------------

P2P_SOCKETID_API_LATEST :: 1
P2P_SOCKETID_SOCKETNAME_SIZE :: 33
P2P_Socket_Id :: struct {
	api_version: i32,
	socket_name: [P2P_SOCKETID_SOCKETNAME_SIZE]u8,
}

Packet_Reliability :: enum i32 {
	Unreliable_Unordered = 0,
	Reliable_Unordered   = 1,
	Reliable_Ordered     = 2,
}

P2P_SENDPACKET_API_LATEST :: 3
P2P_Send_Packet_Options :: struct {
	api_version:                    i32,
	local_user_id:                  Product_User_Id,
	remote_user_id:                 Product_User_Id,
	socket_id:                      ^P2P_Socket_Id,
	channel:                        u8,
	data_length_bytes:              u32,
	data:                           rawptr,
	allow_delayed_delivery:         Bool,
	reliability:                    Packet_Reliability,
	disable_auto_accept_connection: Bool,
}

P2P_GETNEXTRECEIVEDPACKETSIZE_API_LATEST :: 2
P2P_Get_Next_Received_Packet_Size_Options :: struct {
	api_version:       i32,
	local_user_id:     Product_User_Id,
	requested_channel: ^u8,
}

P2P_RECEIVEPACKET_API_LATEST :: 2
P2P_Receive_Packet_Options :: struct {
	api_version:         i32,
	local_user_id:       Product_User_Id,
	max_data_size_bytes: u32,
	requested_channel:   ^u8,
}

P2P_ADDNOTIFYPEERCONNECTIONREQUEST_API_LATEST :: 1
P2P_ADDNOTIFYPEERCONNECTIONESTABLISHED_API_LATEST :: 1
P2P_ADDNOTIFYPEERCONNECTIONCLOSED_API_LATEST :: 1
P2P_CLOSECONNECTIONS_API_LATEST :: 1
// The AddNotify*, CloseConnections options all share this shape.
P2P_Socket_Options :: struct {
	api_version:   i32,
	local_user_id: Product_User_Id,
	socket_id:     ^P2P_Socket_Id,
}

P2P_On_Incoming_Connection_Request_Info :: struct {
	client_data:    rawptr,
	local_user_id:  Product_User_Id,
	remote_user_id: Product_User_Id,
	socket_id:      ^P2P_Socket_Id,
}

Network_Connection_Type :: enum i32 {
	No_Connection = 0,
	Direct        = 1,
	Relayed       = 2,
}

P2P_On_Peer_Connection_Established_Info :: struct {
	client_data:     rawptr,
	local_user_id:   Product_User_Id,
	remote_user_id:  Product_User_Id,
	socket_id:       ^P2P_Socket_Id,
	connection_type: i32, // 0 new, 1 reconnection
	network_type:    Network_Connection_Type,
}

P2P_On_Remote_Connection_Closed_Info :: struct {
	client_data:    rawptr,
	local_user_id:  Product_User_Id,
	remote_user_id: Product_User_Id,
	socket_id:      ^P2P_Socket_Id,
	reason:         i32,
}

P2P_ACCEPTCONNECTION_API_LATEST :: 1
P2P_CLOSECONNECTION_API_LATEST :: 1
// AcceptConnection and CloseConnection (one peer) take this shape.
P2P_Accept_Connection_Options :: struct {
	api_version:    i32,
	local_user_id:  Product_User_Id,
	remote_user_id: Product_User_Id,
	socket_id:      ^P2P_Socket_Id,
}

Relay_Control :: enum i32 {
	No_Relays    = 0,
	Allow_Relays = 1,
	Force_Relays = 2,
}

P2P_SETRELAYCONTROL_API_LATEST :: 1
P2P_Set_Relay_Control_Options :: struct {
	api_version:   i32,
	relay_control: Relay_Control,
}

P2P_SETPACKETQUEUESIZE_API_LATEST :: 1
P2P_Set_Packet_Queue_Size_Options :: struct {
	api_version:                          i32,
	incoming_packet_queue_max_size_bytes: u64,
	outgoing_packet_queue_max_size_bytes: u64,
}

// --- lobby ----------------------------------------------------------------------------------------

Lobby_Permission_Level :: enum i32 {
	Public_Advertised = 0,
	Join_Via_Presence = 1,
	Invite_Only       = 2,
}

LOBBY_CREATELOBBY_API_LATEST :: 10
Lobby_Create_Lobby_Options :: struct {
	api_version:                       i32,
	local_user_id:                     Product_User_Id,
	max_lobby_members:                 u32,
	permission_level:                  Lobby_Permission_Level,
	presence_enabled:                  Bool,
	allow_invites:                     Bool,
	bucket_id:                         cstring,
	disable_host_migration:            Bool,
	enable_rtc_room:                   Bool,
	local_rtc_options:                 rawptr,
	lobby_id:                          cstring,
	enable_join_by_id:                 Bool,
	rejoin_after_kick_requires_invite: Bool,
	allowed_platform_ids:              ^u32,
	allowed_platform_ids_count:        u32,
	crossplay_opt_out:                 Bool,
	rtc_room_join_action_type:         i32,
}

// CreateLobby, UpdateLobby, JoinLobby, LeaveLobby and DestroyLobby callbacks share this shape.
Lobby_Callback_Info :: struct {
	result_code: Result,
	client_data: rawptr,
	lobby_id:    Lobby_Id,
}

LOBBY_UPDATELOBBYMODIFICATION_API_LATEST :: 1
LOBBY_LEAVELOBBY_API_LATEST :: 1
LOBBY_DESTROYLOBBY_API_LATEST :: 1
// UpdateLobbyModification, LeaveLobby and DestroyLobby options share this shape.
Lobby_User_Lobby_Options :: struct {
	api_version:   i32,
	local_user_id: Product_User_Id,
	lobby_id:      Lobby_Id,
}

Attribute_Type :: enum i32 {
	Boolean = 0,
	Int64   = 1,
	Double  = 2,
	String  = 3,
}

Attribute_Value :: struct #raw_union {
	as_int64:  i64,
	as_double: f64,
	as_bool:   Bool,
	as_utf8:   cstring,
}

LOBBY_ATTRIBUTEDATA_API_LATEST :: 1
Lobby_Attribute_Data :: struct {
	api_version: i32,
	key:         cstring,
	value:       Attribute_Value,
	value_type:  Attribute_Type,
}

LOBBYMODIFICATION_ADDATTRIBUTE_API_LATEST :: 2
LA_PUBLIC :: 0
Lobby_Modification_Add_Attribute_Options :: struct {
	api_version: i32,
	attribute:   ^Lobby_Attribute_Data,
	visibility:  i32,
}

LOBBY_UPDATELOBBY_API_LATEST :: 1
Lobby_Update_Lobby_Options :: struct {
	api_version:               i32,
	lobby_modification_handle: H_Lobby_Modification,
}

LOBBY_CREATELOBBYSEARCH_API_LATEST :: 1
Lobby_Create_Lobby_Search_Options :: struct {
	api_version: i32,
	max_results: u32,
}

LOBBYSEARCH_SETPARAMETER_API_LATEST :: 1
CO_EQUAL :: 0
LOBBY_SEARCH_BUCKET_ID :: "bucket"
Lobby_Search_Set_Parameter_Options :: struct {
	api_version:   i32,
	parameter:     ^Lobby_Attribute_Data,
	comparison_op: i32,
}

LOBBYSEARCH_FIND_API_LATEST :: 1
Lobby_Search_Find_Options :: struct {
	api_version:   i32,
	local_user_id: Product_User_Id,
}

LOBBYSEARCH_GETSEARCHRESULTCOUNT_API_LATEST :: 1
LOBBYDETAILS_GETLOBBYOWNER_API_LATEST :: 1
// Options that carry only the ApiVersion.
Version_Options :: struct {
	api_version: i32,
}

LOBBYSEARCH_COPYSEARCHRESULTBYINDEX_API_LATEST :: 1
Lobby_Search_Copy_Search_Result_By_Index_Options :: struct {
	api_version: i32,
	lobby_index: u32,
}

LOBBY_JOINLOBBY_API_LATEST :: 5
Lobby_Join_Lobby_Options :: struct {
	api_version:               i32,
	lobby_details_handle:      H_Lobby_Details,
	local_user_id:             Product_User_Id,
	presence_enabled:          Bool,
	local_rtc_options:         rawptr,
	crossplay_opt_out:         Bool,
	rtc_room_join_action_type: i32,
}

Lobby_Member_Status :: enum i32 {
	Joined       = 0,
	Left         = 1,
	Disconnected = 2,
	Kicked       = 3,
	Promoted     = 4,
	Closed       = 5,
}

LOBBY_ADDNOTIFYLOBBYMEMBERSTATUSRECEIVED_API_LATEST :: 1
Lobby_Member_Status_Received_Callback_Info :: struct {
	client_data:    rawptr,
	lobby_id:       Lobby_Id,
	target_user_id: Product_User_Id,
	current_status: Lobby_Member_Status,
}

// --- the function table ---------------------------------------------------------------------------

Api :: struct {
	__handle:                                    dynlib.Library,
	Initialize:                                  proc "c" (opts: ^Initialize_Options) -> Result,
	Shutdown:                                    proc "c" () -> Result,
	EResult_ToString:                            proc "c" (result: Result) -> cstring,
	ProductUserId_ToString:                      proc "c" (id: Product_User_Id, out: [^]u8, inout_len: ^i32) -> Result,
	ProductUserId_IsValid:                       proc "c" (id: Product_User_Id) -> Bool,
	Logging_SetCallback:                         proc "c" (callback: proc "c" (msg: ^Log_Message)) -> Result,
	Logging_SetLogLevel:                         proc "c" (category: i32, level: Log_Level) -> Result,
	Platform_Create:                             proc "c" (opts: ^Platform_Options) -> H_Platform,
	Platform_Tick:                               proc "c" (handle: H_Platform),
	Platform_Release:                            proc "c" (handle: H_Platform),
	Platform_GetConnectInterface:                proc "c" (handle: H_Platform) -> H_Connect,
	Platform_GetP2PInterface:                    proc "c" (handle: H_Platform) -> H_P2P,
	Platform_GetLobbyInterface:                  proc "c" (handle: H_Platform) -> H_Lobby,
	Connect_Login:                               proc "c" (
		handle: H_Connect,
		opts: ^Connect_Login_Options,
		client_data: rawptr,
		callback: proc "c" (info: ^Connect_Login_Callback_Info),
	),
	Connect_CreateUser:                          proc "c" (
		handle: H_Connect,
		opts: ^Connect_Create_User_Options,
		client_data: rawptr,
		callback: proc "c" (info: ^Connect_Create_User_Callback_Info),
	),
	Connect_CreateDeviceId:                      proc "c" (
		handle: H_Connect,
		opts: ^Connect_Create_Device_Id_Options,
		client_data: rawptr,
		callback: proc "c" (info: ^Result_Callback_Info),
	),
	Connect_DeleteDeviceId:                      proc "c" (
		handle: H_Connect,
		opts: ^Connect_Delete_Device_Id_Options,
		client_data: rawptr,
		callback: proc "c" (info: ^Result_Callback_Info),
	),
	Connect_AddNotifyAuthExpiration:             proc "c" (
		handle: H_Connect,
		opts: ^Connect_Add_Notify_Auth_Expiration_Options,
		client_data: rawptr,
		callback: proc "c" (info: ^Connect_Auth_Expiration_Callback_Info),
	) -> Notification_Id,
	Connect_RemoveNotifyAuthExpiration:          proc "c" (handle: H_Connect, id: Notification_Id),
	P2P_SendPacket:                              proc "c" (handle: H_P2P, opts: ^P2P_Send_Packet_Options) -> Result,
	P2P_GetNextReceivedPacketSize:               proc "c" (
		handle: H_P2P,
		opts: ^P2P_Get_Next_Received_Packet_Size_Options,
		out_size: ^u32,
	) -> Result,
	P2P_ReceivePacket:                           proc "c" (
		handle: H_P2P,
		opts: ^P2P_Receive_Packet_Options,
		out_peer: ^Product_User_Id,
		out_socket: ^P2P_Socket_Id,
		out_channel: ^u8,
		out_data: rawptr,
		out_bytes_written: ^u32,
	) -> Result,
	P2P_AddNotifyPeerConnectionRequest:          proc "c" (
		handle: H_P2P,
		opts: ^P2P_Socket_Options,
		client_data: rawptr,
		callback: proc "c" (info: ^P2P_On_Incoming_Connection_Request_Info),
	) -> Notification_Id,
	P2P_RemoveNotifyPeerConnectionRequest:       proc "c" (handle: H_P2P, id: Notification_Id),
	P2P_AddNotifyPeerConnectionEstablished:      proc "c" (
		handle: H_P2P,
		opts: ^P2P_Socket_Options,
		client_data: rawptr,
		callback: proc "c" (info: ^P2P_On_Peer_Connection_Established_Info),
	) -> Notification_Id,
	P2P_RemoveNotifyPeerConnectionEstablished:   proc "c" (handle: H_P2P, id: Notification_Id),
	P2P_AddNotifyPeerConnectionClosed:           proc "c" (
		handle: H_P2P,
		opts: ^P2P_Socket_Options,
		client_data: rawptr,
		callback: proc "c" (info: ^P2P_On_Remote_Connection_Closed_Info),
	) -> Notification_Id,
	P2P_RemoveNotifyPeerConnectionClosed:        proc "c" (handle: H_P2P, id: Notification_Id),
	P2P_AcceptConnection:                        proc "c" (
		handle: H_P2P,
		opts: ^P2P_Accept_Connection_Options,
	) -> Result,
	P2P_CloseConnection:                         proc "c" (
		handle: H_P2P,
		opts: ^P2P_Accept_Connection_Options,
	) -> Result,
	P2P_CloseConnections:                        proc "c" (handle: H_P2P, opts: ^P2P_Socket_Options) -> Result,
	P2P_SetRelayControl:                         proc "c" (
		handle: H_P2P,
		opts: ^P2P_Set_Relay_Control_Options,
	) -> Result,
	P2P_SetPacketQueueSize:                      proc "c" (
		handle: H_P2P,
		opts: ^P2P_Set_Packet_Queue_Size_Options,
	) -> Result,
	Lobby_CreateLobby:                           proc "c" (
		handle: H_Lobby,
		opts: ^Lobby_Create_Lobby_Options,
		client_data: rawptr,
		callback: proc "c" (info: ^Lobby_Callback_Info),
	),
	Lobby_UpdateLobbyModification:               proc "c" (
		handle: H_Lobby,
		opts: ^Lobby_User_Lobby_Options,
		out: ^H_Lobby_Modification,
	) -> Result,
	Lobby_UpdateLobby:                           proc "c" (
		handle: H_Lobby,
		opts: ^Lobby_Update_Lobby_Options,
		client_data: rawptr,
		callback: proc "c" (info: ^Lobby_Callback_Info),
	),
	Lobby_JoinLobby:                             proc "c" (
		handle: H_Lobby,
		opts: ^Lobby_Join_Lobby_Options,
		client_data: rawptr,
		callback: proc "c" (info: ^Lobby_Callback_Info),
	),
	Lobby_LeaveLobby:                            proc "c" (
		handle: H_Lobby,
		opts: ^Lobby_User_Lobby_Options,
		client_data: rawptr,
		callback: proc "c" (info: ^Lobby_Callback_Info),
	),
	Lobby_DestroyLobby:                          proc "c" (
		handle: H_Lobby,
		opts: ^Lobby_User_Lobby_Options,
		client_data: rawptr,
		callback: proc "c" (info: ^Lobby_Callback_Info),
	),
	Lobby_CreateLobbySearch:                     proc "c" (
		handle: H_Lobby,
		opts: ^Lobby_Create_Lobby_Search_Options,
		out: ^H_Lobby_Search,
	) -> Result,
	Lobby_AddNotifyLobbyMemberStatusReceived:    proc "c" (
		handle: H_Lobby,
		opts: ^Version_Options,
		client_data: rawptr,
		callback: proc "c" (info: ^Lobby_Member_Status_Received_Callback_Info),
	) -> Notification_Id,
	Lobby_RemoveNotifyLobbyMemberStatusReceived: proc "c" (handle: H_Lobby, id: Notification_Id),
	LobbyModification_AddAttribute:              proc "c" (
		handle: H_Lobby_Modification,
		opts: ^Lobby_Modification_Add_Attribute_Options,
	) -> Result,
	LobbyModification_Release:                   proc "c" (handle: H_Lobby_Modification),
	LobbySearch_SetParameter:                    proc "c" (
		handle: H_Lobby_Search,
		opts: ^Lobby_Search_Set_Parameter_Options,
	) -> Result,
	LobbySearch_Find:                            proc "c" (
		handle: H_Lobby_Search,
		opts: ^Lobby_Search_Find_Options,
		client_data: rawptr,
		callback: proc "c" (info: ^Result_Callback_Info),
	),
	LobbySearch_GetSearchResultCount:            proc "c" (handle: H_Lobby_Search, opts: ^Version_Options) -> u32,
	LobbySearch_CopySearchResultByIndex:         proc "c" (
		handle: H_Lobby_Search,
		opts: ^Lobby_Search_Copy_Search_Result_By_Index_Options,
		out: ^H_Lobby_Details,
	) -> Result,
	LobbySearch_Release:                         proc "c" (handle: H_Lobby_Search),
	LobbyDetails_GetLobbyOwner:                  proc "c" (
		handle: H_Lobby_Details,
		opts: ^Version_Options,
	) -> Product_User_Id,
	LobbyDetails_Release:                        proc "c" (handle: H_Lobby_Details),
}

// Loads the SDK library from `path` and resolves every function; false if the file is missing or
// a symbol is absent (an SDK too old for these bindings).
api_load :: proc(api: ^Api, path: string) -> bool {
	count, ok := dynlib.initialize_symbols(api, path, "EOS_")
	if !ok {
		return false
	}
	return count == reflect.struct_field_count(Api) - 1 // every field but __handle
}
