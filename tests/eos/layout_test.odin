// The hand-written SDK bindings against the real headers: a generated C program prints sizeof and
// offsetof for every bound struct and the value of every constant we copied, and the test compares
// them with the Odin side. Needs the SDK UNIFIED_EOS_SDK names (the environment or .env; CI has none) and
// a C compiler (clang or cc); skipped with a log line otherwise. Re-run after any SDK upgrade.
package test_eos

import "core:fmt"
import "core:hash"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:reflect"
import "core:strconv"
import "core:strings"
import "core:testing"

import "unified:eos"

OUT_DIR :: #directory + "/../../.out"

// The SDK's SDK/ folder from UNIFIED_EOS_SDK (its root or SDK/ itself), or "" when it isn't set.
sdk_dir :: proc() -> string {
	sdk := os.get_env("UNIFIED_EOS_SDK", context.temp_allocator)
	if sdk == "" do return ""
	if filepath.base(sdk) == "SDK" do return sdk
	dir, _ := filepath.join({sdk, "SDK"}, context.temp_allocator)
	return dir
}

Layout :: struct {
	odin:   typeid,
	c:      string,
	fields: string, // C field names in Odin field order, space-separated
}

LAYOUTS := []Layout {
	{
		eos.Initialize_Options,
		"EOS_InitializeOptions",
		"ApiVersion AllocateMemoryFunction ReallocateMemoryFunction ReleaseMemoryFunction ProductName ProductVersion Reserved SystemInitializeOptions OverrideThreadAffinity",
	},
	{eos.Platform_Client_Credentials, "EOS_Platform_ClientCredentials", "ClientId ClientSecret"},
	{
		eos.Platform_Options,
		"EOS_Platform_Options",
		"ApiVersion Reserved ProductId SandboxId ClientCredentials bIsServer EncryptionKey OverrideCountryCode OverrideLocaleCode DeploymentId Flags CacheDirectory TickBudgetInMilliseconds RTCOptions IntegratedPlatformOptionsContainerHandle SystemSpecificOptions TaskNetworkTimeoutSeconds",
	},
	{eos.Log_Message, "EOS_LogMessage", "Category Message Level"},
	{eos.Connect_Credentials, "EOS_Connect_Credentials", "ApiVersion Token Type"},
	{eos.Connect_User_Login_Info, "EOS_Connect_UserLoginInfo", "ApiVersion DisplayName NsaIdToken"},
	{eos.Connect_Login_Options, "EOS_Connect_LoginOptions", "ApiVersion Credentials UserLoginInfo"},
	{
		eos.Connect_Login_Callback_Info,
		"EOS_Connect_LoginCallbackInfo",
		"ResultCode ClientData LocalUserId ContinuanceToken",
	},
	{eos.Connect_Create_User_Options, "EOS_Connect_CreateUserOptions", "ApiVersion ContinuanceToken"},
	{eos.Connect_Create_User_Callback_Info, "EOS_Connect_CreateUserCallbackInfo", "ResultCode ClientData LocalUserId"},
	{eos.Connect_Create_Device_Id_Options, "EOS_Connect_CreateDeviceIdOptions", "ApiVersion DeviceModel"},
	{eos.Connect_Delete_Device_Id_Options, "EOS_Connect_DeleteDeviceIdOptions", "ApiVersion"},
	{eos.Result_Callback_Info, "EOS_Connect_CreateDeviceIdCallbackInfo", "ResultCode ClientData"},
	{eos.Result_Callback_Info, "EOS_Connect_DeleteDeviceIdCallbackInfo", "ResultCode ClientData"},
	{eos.Result_Callback_Info, "EOS_LobbySearch_FindCallbackInfo", "ResultCode ClientData"},
	{eos.Connect_Add_Notify_Auth_Expiration_Options, "EOS_Connect_AddNotifyAuthExpirationOptions", "ApiVersion"},
	{eos.Connect_Auth_Expiration_Callback_Info, "EOS_Connect_AuthExpirationCallbackInfo", "ClientData LocalUserId"},
	{eos.P2P_Socket_Id, "EOS_P2P_SocketId", "ApiVersion SocketName"},
	{
		eos.P2P_Send_Packet_Options,
		"EOS_P2P_SendPacketOptions",
		"ApiVersion LocalUserId RemoteUserId SocketId Channel DataLengthBytes Data bAllowDelayedDelivery Reliability bDisableAutoAcceptConnection",
	},
	{
		eos.P2P_Get_Next_Received_Packet_Size_Options,
		"EOS_P2P_GetNextReceivedPacketSizeOptions",
		"ApiVersion LocalUserId RequestedChannel",
	},
	{
		eos.P2P_Receive_Packet_Options,
		"EOS_P2P_ReceivePacketOptions",
		"ApiVersion LocalUserId MaxDataSizeBytes RequestedChannel",
	},
	{eos.P2P_Socket_Options, "EOS_P2P_AddNotifyPeerConnectionRequestOptions", "ApiVersion LocalUserId SocketId"},
	{eos.P2P_Socket_Options, "EOS_P2P_AddNotifyPeerConnectionEstablishedOptions", "ApiVersion LocalUserId SocketId"},
	{eos.P2P_Socket_Options, "EOS_P2P_AddNotifyPeerConnectionClosedOptions", "ApiVersion LocalUserId SocketId"},
	{eos.P2P_Socket_Options, "EOS_P2P_CloseConnectionsOptions", "ApiVersion LocalUserId SocketId"},
	{
		eos.P2P_On_Incoming_Connection_Request_Info,
		"EOS_P2P_OnIncomingConnectionRequestInfo",
		"ClientData LocalUserId RemoteUserId SocketId",
	},
	{
		eos.P2P_On_Peer_Connection_Established_Info,
		"EOS_P2P_OnPeerConnectionEstablishedInfo",
		"ClientData LocalUserId RemoteUserId SocketId ConnectionType NetworkType",
	},
	{
		eos.P2P_On_Remote_Connection_Closed_Info,
		"EOS_P2P_OnRemoteConnectionClosedInfo",
		"ClientData LocalUserId RemoteUserId SocketId Reason",
	},
	{
		eos.P2P_Accept_Connection_Options,
		"EOS_P2P_AcceptConnectionOptions",
		"ApiVersion LocalUserId RemoteUserId SocketId",
	},
	{
		eos.P2P_Accept_Connection_Options,
		"EOS_P2P_CloseConnectionOptions",
		"ApiVersion LocalUserId RemoteUserId SocketId",
	},
	{eos.P2P_Set_Relay_Control_Options, "EOS_P2P_SetRelayControlOptions", "ApiVersion RelayControl"},
	{
		eos.P2P_Set_Packet_Queue_Size_Options,
		"EOS_P2P_SetPacketQueueSizeOptions",
		"ApiVersion IncomingPacketQueueMaxSizeBytes OutgoingPacketQueueMaxSizeBytes",
	},
	{
		eos.Lobby_Create_Lobby_Options,
		"EOS_Lobby_CreateLobbyOptions",
		"ApiVersion LocalUserId MaxLobbyMembers PermissionLevel bPresenceEnabled bAllowInvites BucketId bDisableHostMigration bEnableRTCRoom LocalRTCOptions LobbyId bEnableJoinById bRejoinAfterKickRequiresInvite AllowedPlatformIds AllowedPlatformIdsCount bCrossplayOptOut RTCRoomJoinActionType",
	},
	{eos.Lobby_Callback_Info, "EOS_Lobby_CreateLobbyCallbackInfo", "ResultCode ClientData LobbyId"},
	{eos.Lobby_Callback_Info, "EOS_Lobby_UpdateLobbyCallbackInfo", "ResultCode ClientData LobbyId"},
	{eos.Lobby_Callback_Info, "EOS_Lobby_JoinLobbyCallbackInfo", "ResultCode ClientData LobbyId"},
	{eos.Lobby_Callback_Info, "EOS_Lobby_LeaveLobbyCallbackInfo", "ResultCode ClientData LobbyId"},
	{eos.Lobby_Callback_Info, "EOS_Lobby_DestroyLobbyCallbackInfo", "ResultCode ClientData LobbyId"},
	{eos.Lobby_User_Lobby_Options, "EOS_Lobby_UpdateLobbyModificationOptions", "ApiVersion LocalUserId LobbyId"},
	{eos.Lobby_User_Lobby_Options, "EOS_Lobby_LeaveLobbyOptions", "ApiVersion LocalUserId LobbyId"},
	{eos.Lobby_User_Lobby_Options, "EOS_Lobby_DestroyLobbyOptions", "ApiVersion LocalUserId LobbyId"},
	{eos.Lobby_Attribute_Data, "EOS_Lobby_AttributeData", "ApiVersion Key Value ValueType"},
	{
		eos.Lobby_Modification_Add_Attribute_Options,
		"EOS_LobbyModification_AddAttributeOptions",
		"ApiVersion Attribute Visibility",
	},
	{eos.Lobby_Update_Lobby_Options, "EOS_Lobby_UpdateLobbyOptions", "ApiVersion LobbyModificationHandle"},
	{eos.Lobby_Create_Lobby_Search_Options, "EOS_Lobby_CreateLobbySearchOptions", "ApiVersion MaxResults"},
	{
		eos.Lobby_Search_Set_Parameter_Options,
		"EOS_LobbySearch_SetParameterOptions",
		"ApiVersion Parameter ComparisonOp",
	},
	{eos.Lobby_Search_Find_Options, "EOS_LobbySearch_FindOptions", "ApiVersion LocalUserId"},
	{eos.Version_Options, "EOS_LobbySearch_GetSearchResultCountOptions", "ApiVersion"},
	{eos.Version_Options, "EOS_LobbyDetails_GetLobbyOwnerOptions", "ApiVersion"},
	{eos.Lobby_Attribute, "EOS_Lobby_Attribute", "ApiVersion Data Visibility"},
	{
		eos.LobbyDetails_Copy_Attribute_By_Key_Options,
		"EOS_LobbyDetails_CopyAttributeByKeyOptions",
		"ApiVersion AttrKey",
	},
	{eos.Version_Options, "EOS_Lobby_AddNotifyLobbyMemberStatusReceivedOptions", "ApiVersion"},
	{
		eos.Lobby_Search_Copy_Search_Result_By_Index_Options,
		"EOS_LobbySearch_CopySearchResultByIndexOptions",
		"ApiVersion LobbyIndex",
	},
	{
		eos.Lobby_Join_Lobby_Options,
		"EOS_Lobby_JoinLobbyOptions",
		"ApiVersion LobbyDetailsHandle LocalUserId bPresenceEnabled LocalRTCOptions bCrossplayOptOut RTCRoomJoinActionType",
	},
	{
		eos.Lobby_Member_Status_Received_Callback_Info,
		"EOS_Lobby_LobbyMemberStatusReceivedCallbackInfo",
		"ClientData LobbyId TargetUserId CurrentStatus",
	},
}

Constant :: struct {
	c:    string,
	odin: i64,
}

CONSTANTS := []Constant {
	{"EOS_INITIALIZE_API_LATEST", eos.INITIALIZE_API_LATEST},
	{"EOS_PLATFORM_OPTIONS_API_LATEST", eos.PLATFORM_OPTIONS_API_LATEST},
	{"EOS_PF_DISABLE_OVERLAY", eos.PF_DISABLE_OVERLAY},
	{"EOS_PF_DISABLE_SOCIAL_OVERLAY", eos.PF_DISABLE_SOCIAL_OVERLAY},
	{"EOS_LC_ALL_CATEGORIES", eos.LC_ALL_CATEGORIES},
	{"EOS_LOG_Warning", i64(eos.Log_Level.Warning)},
	{"EOS_LOG_VeryVerbose", i64(eos.Log_Level.Very_Verbose)},
	{"EOS_ECT_DEVICEID_ACCESS_TOKEN", eos.ECT_DEVICEID_ACCESS_TOKEN},
	{"EOS_CONNECT_CREDENTIALS_API_LATEST", eos.CONNECT_CREDENTIALS_API_LATEST},
	{"EOS_CONNECT_USERLOGININFO_API_LATEST", eos.CONNECT_USERLOGININFO_API_LATEST},
	{"EOS_CONNECT_LOGIN_API_LATEST", eos.CONNECT_LOGIN_API_LATEST},
	{"EOS_CONNECT_CREATEUSER_API_LATEST", eos.CONNECT_CREATEUSER_API_LATEST},
	{"EOS_CONNECT_CREATEDEVICEID_API_LATEST", eos.CONNECT_CREATEDEVICEID_API_LATEST},
	{"EOS_CONNECT_DELETEDEVICEID_API_LATEST", eos.CONNECT_DELETEDEVICEID_API_LATEST},
	{"EOS_CONNECT_ADDNOTIFYAUTHEXPIRATION_API_LATEST", eos.CONNECT_ADDNOTIFYAUTHEXPIRATION_API_LATEST},
	{"EOS_PRODUCTUSERID_MAX_LENGTH", eos.PRODUCTUSERID_MAX_LENGTH},
	{"EOS_P2P_SOCKETID_API_LATEST", eos.P2P_SOCKETID_API_LATEST},
	{"EOS_P2P_SOCKETID_SOCKETNAME_SIZE", eos.P2P_SOCKETID_SOCKETNAME_SIZE},
	{"EOS_P2P_MAX_PACKET_SIZE", eos.P2P_MAX_PACKET},
	{"EOS_P2P_SENDPACKET_API_LATEST", eos.P2P_SENDPACKET_API_LATEST},
	{"EOS_P2P_GETNEXTRECEIVEDPACKETSIZE_API_LATEST", eos.P2P_GETNEXTRECEIVEDPACKETSIZE_API_LATEST},
	{"EOS_P2P_RECEIVEPACKET_API_LATEST", eos.P2P_RECEIVEPACKET_API_LATEST},
	{"EOS_P2P_ADDNOTIFYPEERCONNECTIONREQUEST_API_LATEST", eos.P2P_ADDNOTIFYPEERCONNECTIONREQUEST_API_LATEST},
	{"EOS_P2P_ADDNOTIFYPEERCONNECTIONESTABLISHED_API_LATEST", eos.P2P_ADDNOTIFYPEERCONNECTIONESTABLISHED_API_LATEST},
	{"EOS_P2P_ADDNOTIFYPEERCONNECTIONCLOSED_API_LATEST", eos.P2P_ADDNOTIFYPEERCONNECTIONCLOSED_API_LATEST},
	{"EOS_P2P_CLOSECONNECTIONS_API_LATEST", eos.P2P_CLOSECONNECTIONS_API_LATEST},
	{"EOS_P2P_ACCEPTCONNECTION_API_LATEST", eos.P2P_ACCEPTCONNECTION_API_LATEST},
	{"EOS_P2P_CLOSECONNECTION_API_LATEST", eos.P2P_CLOSECONNECTION_API_LATEST},
	{"EOS_P2P_SETRELAYCONTROL_API_LATEST", eos.P2P_SETRELAYCONTROL_API_LATEST},
	{"EOS_P2P_SETPACKETQUEUESIZE_API_LATEST", eos.P2P_SETPACKETQUEUESIZE_API_LATEST},
	{"EOS_PR_UnreliableUnordered", i64(eos.Packet_Reliability.Unreliable_Unordered)},
	{"EOS_RC_AllowRelays", i64(eos.Relay_Control.Allow_Relays)},
	{"EOS_RC_ForceRelays", i64(eos.Relay_Control.Force_Relays)},
	{"EOS_NCT_RelayedConnection", i64(eos.Network_Connection_Type.Relayed)},
	{"EOS_LOBBY_CREATELOBBY_API_LATEST", eos.LOBBY_CREATELOBBY_API_LATEST},
	{"EOS_LOBBY_UPDATELOBBYMODIFICATION_API_LATEST", eos.LOBBY_UPDATELOBBYMODIFICATION_API_LATEST},
	{"EOS_LOBBY_LEAVELOBBY_API_LATEST", eos.LOBBY_LEAVELOBBY_API_LATEST},
	{"EOS_LOBBY_DESTROYLOBBY_API_LATEST", eos.LOBBY_DESTROYLOBBY_API_LATEST},
	{"EOS_LOBBY_ATTRIBUTEDATA_API_LATEST", eos.LOBBY_ATTRIBUTEDATA_API_LATEST},
	{"EOS_LOBBYMODIFICATION_ADDATTRIBUTE_API_LATEST", eos.LOBBYMODIFICATION_ADDATTRIBUTE_API_LATEST},
	{"EOS_LOBBY_UPDATELOBBY_API_LATEST", eos.LOBBY_UPDATELOBBY_API_LATEST},
	{"EOS_LOBBY_CREATELOBBYSEARCH_API_LATEST", eos.LOBBY_CREATELOBBYSEARCH_API_LATEST},
	{"EOS_LOBBYSEARCH_SETPARAMETER_API_LATEST", eos.LOBBYSEARCH_SETPARAMETER_API_LATEST},
	{"EOS_LOBBYSEARCH_FIND_API_LATEST", eos.LOBBYSEARCH_FIND_API_LATEST},
	{"EOS_LOBBYSEARCH_GETSEARCHRESULTCOUNT_API_LATEST", eos.LOBBYSEARCH_GETSEARCHRESULTCOUNT_API_LATEST},
	{"EOS_LOBBYDETAILS_GETLOBBYOWNER_API_LATEST", eos.LOBBYDETAILS_GETLOBBYOWNER_API_LATEST},
	{"EOS_LOBBY_ATTRIBUTE_API_LATEST", eos.LOBBY_ATTRIBUTE_API_LATEST},
	{"EOS_LOBBYDETAILS_COPYATTRIBUTEBYKEY_API_LATEST", eos.LOBBYDETAILS_COPYATTRIBUTEBYKEY_API_LATEST},
	{"EOS_LOBBYSEARCH_COPYSEARCHRESULTBYINDEX_API_LATEST", eos.LOBBYSEARCH_COPYSEARCHRESULTBYINDEX_API_LATEST},
	{"EOS_LOBBY_JOINLOBBY_API_LATEST", eos.LOBBY_JOINLOBBY_API_LATEST},
	{
		"EOS_LOBBY_ADDNOTIFYLOBBYMEMBERSTATUSRECEIVED_API_LATEST",
		eos.LOBBY_ADDNOTIFYLOBBYMEMBERSTATUSRECEIVED_API_LATEST,
	},
	{"EOS_LPL_PUBLICADVERTISED", i64(eos.Lobby_Permission_Level.Public_Advertised)},
	{"EOS_LAT_PUBLIC", eos.LA_PUBLIC},
	{"EOS_AT_STRING", i64(eos.Attribute_Type.String)},
	{"EOS_CO_EQUAL", eos.CO_EQUAL},
	{"EOS_LMS_JOINED", i64(eos.Lobby_Member_Status.Joined)},
	{"EOS_LMS_LEFT", i64(eos.Lobby_Member_Status.Left)},
	{"EOS_LMS_KICKED", i64(eos.Lobby_Member_Status.Kicked)},
	{"EOS_LMS_DISCONNECTED", i64(eos.Lobby_Member_Status.Disconnected)},
	{"EOS_LMS_CLOSED", i64(eos.Lobby_Member_Status.Closed)},
	{"EOS_Success", i64(eos.Result.Success)},
	{"EOS_InvalidUser", i64(eos.Result.InvalidUser)},
	{"EOS_NotFound", i64(eos.Result.NotFound)},
	{"EOS_AlreadyConfigured", i64(eos.Result.AlreadyConfigured)},
	{"EOS_DuplicateNotAllowed", i64(eos.Result.DuplicateNotAllowed)},
	{"EOS_TimedOut", i64(eos.Result.TimedOut)},
	{"EOS_UnexpectedError", i64(eos.Result.UnexpectedError)},
}

@(test)
bindings_match_the_sdk_headers :: proc(t: ^testing.T) {
	include := fmt.tprintf("%s/Include", sdk_dir())
	if sdk_dir() == "" || !os.exists(fmt.tprintf("%s/eos_sdk.h", include)) {
		log.info("no EOS SDK (UNIFIED_EOS_SDK); layout check skipped")
		return
	}
	cc := ""
	for name in ([]string{"clang", "cc"}) {
		if found, ok := find_on_path(name); ok {
			cc = found
			break
		}
	}
	if cc == "" {
		log.info("no C compiler on PATH; layout check skipped")
		return
	}
	builder := strings.builder_make(context.temp_allocator)
	fmt.sbprintln(&builder, "#include <stdio.h>\n#include <stddef.h>")
	for header in ([]string{"eos_sdk.h", "eos_logging.h", "eos_connect.h", "eos_p2p.h", "eos_lobby.h"}) {
		fmt.sbprintfln(&builder, "#include \"%s\"", header)
	}
	fmt.sbprintln(&builder, "int main(void) {")
	for layout in LAYOUTS {
		fmt.sbprintfln(&builder, "printf(\"size %s %%zu\\n\", sizeof(%s));", layout.c, layout.c)
		for field in strings.fields(layout.fields, context.temp_allocator) {
			fmt.sbprintfln(
				&builder,
				"printf(\"off %s.%s %%zu\\n\", offsetof(%s, %s));",
				layout.c,
				field,
				layout.c,
				field,
			)
		}
	}
	for constant in CONSTANTS {
		fmt.sbprintfln(&builder, "printf(\"const %s %%lld\\n\", (long long)(%s));", constant.c, constant.c)
	}
	fmt.sbprintln(&builder, "return 0; }")

	// The probe's output only depends on its source and the headers (their version): a stamp in the
	// repo's .out/ skips the compile when both are unchanged.
	probe := strings.to_string(builder)
	version, _ := os.read_entire_file(fmt.tprintf("%s/eos_version.h", include), context.temp_allocator)
	stamp := fmt.tprintf(
		"%s/eos-layout-%16x.ok",
		OUT_DIR,
		hash.fnv64a(transmute([]u8)strings.concatenate({probe, string(version)}, context.temp_allocator)),
	)
	if os.exists(stamp) {
		return
	}
	dir := os.temp_directory(context.temp_allocator) or_else "."
	src, _ := filepath.join({dir, "unified-eos-layout.c"}, context.temp_allocator)
	exe, _ := filepath.join(
		{dir, ODIN_OS == .Windows ? "unified-eos-layout.exe" : "unified-eos-layout"},
		context.temp_allocator,
	)
	testing.expect(t, os.write_entire_file(src, transmute([]u8)probe) == nil)
	defer os.remove(src)
	defer os.remove(exe)
	compile_state, _, cerr, err := os.process_exec(
		{command = {cc, "-I", include, "-o", exe, src}},
		context.temp_allocator,
	)
	if !testing.expectf(
		t,
		err == nil && compile_state.exit_code == 0,
		"compiling the layout probe failed: %v\n%s",
		err,
		string(cerr),
	) {
		return
	}
	run_state, out, _, err2 := os.process_exec({command = {exe}}, context.temp_allocator)
	if !testing.expect(t, err2 == nil && run_state.exit_code == 0, "running the layout probe failed") {
		return
	}
	c_vals := make(map[string]i64, context.temp_allocator)
	for line in strings.split_lines(string(out), context.temp_allocator) {
		parts := strings.fields(line, context.temp_allocator)
		if len(parts) == 3 {
			value, _ := strconv.parse_i64(parts[2])
			c_vals[strings.concatenate({parts[0], " ", parts[1]}, context.temp_allocator)] = value
		}
	}
	for layout in LAYOUTS {
		key := fmt.tprintf("size %s", layout.c)
		testing.expectf(
			t,
			c_vals[key] == i64(reflect.size_of_typeid(layout.odin)),
			"%s: C size %d, Odin %d",
			layout.c,
			c_vals[key],
			reflect.size_of_typeid(layout.odin),
		)
		names := strings.fields(layout.fields, context.temp_allocator)
		offsets := reflect.struct_field_offsets(layout.odin)
		if !testing.expectf(
			t,
			len(names) == len(offsets),
			"%v: %d Odin fields, %d C names",
			layout.odin,
			len(offsets),
			len(names),
		) {
			continue
		}
		for field, i in names {
			offset_key := fmt.tprintf("off %s.%s", layout.c, field)
			testing.expectf(
				t,
				c_vals[offset_key] == i64(offsets[i]),
				"%s.%s: C offset %d, Odin %d",
				layout.c,
				field,
				c_vals[offset_key],
				offsets[i],
			)
		}
	}
	failed := false
	for constant in CONSTANTS {
		key := fmt.tprintf("const %s", constant.c)
		failed ||= !testing.expectf(
			t,
			c_vals[key] == constant.odin,
			"%s: header %d, Odin %d",
			constant.c,
			c_vals[key],
			constant.odin,
		)
	}
	if !failed && !testing.failed(t) {
		_ = os.write_entire_file(stamp, "ok\n")
	}
}

find_on_path :: proc(name: string) -> (string, bool) {
	path := os.get_env("PATH", context.temp_allocator)
	for dir in strings.split(path, ODIN_OS == .Windows ? ";" : ":", context.temp_allocator) {
		candidate, _ := filepath.join(
			{dir, ODIN_OS == .Windows ? strings.concatenate({name, ".exe"}, context.temp_allocator) : name},
			context.temp_allocator,
		)
		if os.is_file(candidate) {
			return candidate, true
		}
	}
	return "", false
}

// The SDK's library for this OS loads, every bound function resolves, and EOS initializes (no
// credentials or network needed). Local only: CI has no SDK.
@(test)
sdk_library_loads :: proc(t: ^testing.T) {
	path := fmt.tprintf("%s/Bin/%s", sdk_dir(), eos.LIB_NAME)
	if sdk_dir() == "" || !os.exists(path) {
		log.info("no EOS SDK library (UNIFIED_EOS_SDK); load check skipped")
		return
	}
	api: eos.Api
	if !testing.expectf(t, eos.api_load(&api, path), "%s: load or symbol lookup failed", path) {
		return
	}
	opts := eos.Initialize_Options {
		api_version     = eos.INITIALIZE_API_LATEST,
		product_name    = "unified-test",
		product_version = "1",
	}
	result := api.Initialize(&opts)
	testing.expectf(t, result == .Success, "EOS_Initialize: %v", result)
	testing.expect_value(t, string(api.EResult_ToString(.NotFound)), "EOS_NotFound")
	if result == .Success {
		testing.expect_value(t, api.Shutdown(), eos.Result.Success)
	}
}
