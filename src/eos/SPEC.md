# `unified:eos`: online play through Epic Online Services

Status: signed off 2026-11-18 (#333)

Internet co-op without servers of our own: anonymous device-ID login (no Epic account), a lobby found by a short
code, and EOS P2P (NAT traversal, Epic relays as fallback) carrying the netcode's datagrams. One-time setup and
manual tests: `docs/EOS.md`. Imports `netcode`; `netcode` never imports `eos`.

## API

```odin
eos.lobby(Lobby_Config{lib_dirs, relay_control, no_keychain_prompts, forget_device}) -> ^netcode.Lobby
// The way in for a game: godot.init(..., eos.lobby({})) and modes.run(..., lobbies = {eos.lobby({...})}).
// EOS starts on the first open_host / open_join, named after Lobby_Build.game with its version.

// What the lobby calls (public for tests, which run them against a fake SDK):
eos.init(Init_Options{lib_dirs, product_name, product_version, cache_dir, relay_control, no_keychain_prompts,
                      sdk /* tests: a fake ^Api */, connect_wait_us /* tests: a shorter CONNECT_WAIT_US */}) -> bool
eos.open_host(Build) -> (netcode.Link, bool)   // login if needed, create the lobby; the link is usable at once
eos.open_join(Build, code) -> (netcode.Link, bool) // login, search by code, check the build, join
eos.pump() -> netcode.Lobby_Status            // tick EOS; where the session stands
eos.close()                                   // destroy/leave the lobby (ticks EOS until it went out), close P2P
eos.status() -> Status{stage, role, code, detail, local, host, network, peers, lib} // any thread
eos.local_account() -> (netcode.Account, bool) // logged in: {"eos", our product user id}
eos.shutdown()                                // at exit; EOS can't be initialized again in the process
eos.forget_device()                           // test tools: delete this machine's device ID
```

`Build` is `netcode.Lobby_Build{game, compat, version, players}`. `game` is the lobby bucket (lobbies are searched per
game); `players` the lobby's member limit. `compat` with `netcode.PROTOCOL_VERSION` becomes the lobby's `build`
attribute (`build_id`); `version` (the project's stamped version) its `version` attribute. A joiner whose build
differs from the lobby's fails before joining, with a message: "that game runs survivor 0.1.4; you have 0.1.3", or
"that game runs a different build of survivor 0.1.4" when the versions match. Nothing is bumped by hand. The link
vouches for every peer's account (`netcode.Link.account`: "eos" and the remote's product user id, which EOS
authenticated): the relay knows a returning player by it (`src/netcode/SPEC.md`, Members).

## How it works

- **SDK loading.** The library (`libEOSSDK-Mac-Shipping.dylib`, `EOSSDK-Win64-Shipping.dll`,
  `libEOSSDK-Linux-Shipping.so`) is loaded at run time from `lib_dirs`, else `$UNIFIED_EOS_LIB_DIR`, the
  executable's directory (macOS: also `../Frameworks`), else `$UNIFIED_EOS_SDK`'s `SDK/Bin`. Missing library or
  credentials → `init` fails with a reason and online play is off; single player and direct UDP still work. Bindings
  are hand-written for the subset we use (`api.odin`), checked against the SDK's headers by tests that need the SDK:
  they run on developer machines, not in CI.
- **Credentials.** `UNIFIED_EOS_PRODUCT_ID`, `_SANDBOX_ID`, `_DEPLOYMENT_ID`, `_CLIENT_ID`, `_CLIENT_SECRET`: compiled
  in as defines (`uni build` and `uni release` pass them from the environment or `.env`), else the same names from the
  environment. CI has none. Never logged.
- **Login.** `EOS_Connect_Login` with `EOS_ECT_DEVICEID_ACCESS_TOKEN`; no device ID yet → `CreateDeviceId` →
  login again; first login of that device → `CreateUser`. Auth expiry (~1 h) logs in again; a failed refresh retries
  every 15 s instead of failing the running session.
- **Lobby.** Host: public lobby in the game's bucket, `players` members at most, host migration off, public
  attributes `code` = 6 characters from `23456789ABCDEFGHJKMNPQRSTUVWXYZ` (no 0/O/1/I/L; crypto random, unbiased),
  `build` and `version`. Joiner: search by bucket + code (a new lobby takes a moment to become searchable: up to 5
  searches 1.2 s apart), the lobby owner's Product User ID is the host, the lobby's `build` must be ours, join. Any
  client of the product can list a game's open lobbies with their codes: the code is a convenience for friends, not a
  secret. Members leaving become link `Disconnected` events; the host leaving fails the joiner. Async lobby results
  carry the session generation: a result for a session already left is dropped, and its lobby destroyed or left.
- **P2P link.** Socket `unified-<code>`, channel 0, unreliable-unordered packets for everything: the netcode's channel
  provides acks, resends and ordering, the same as over UDP. A netcode datagram always fits one EOS packet
  (`#assert(netcode.MAX_DATAGRAM <= P2P_MAX_PACKET)`), so datagrams go as they are. Host peers 1, 2, … are joiners in
  order of their first packet; a joiner's peer 0 is the host. A peer number stays its user's while the user is a
  lobby member; once the user left the lobby and the netcode forgot the peer it goes to the next new user (any number
  of people may pass through a lobby, `netcode.MAX_PEERS` - 1 at a time). The host accepts P2P only from its lobby's members: a
  request that comes before the lobby says its user joined is held and accepted when it does (the last 8 such
  requests are held), a stranger's never is, and a member who left must join again. The lobby is the only way in.
  The joiner's first packet makes the connection request; if the connection isn't up `CONNECT_WAIT_US` after joining,
  the joiner closes it (so its next packet asks again and the host makes a fresh offer: EOS's signalling sometimes
  delivers an offer late); after `CONNECT_TRIES` it fails ("no connection to the host"). A try that never connected
  is not a lost host to the netcode, which waits `FIRST_ANSWER_US` for the host's first answer. Relays are allowed by
  default (`relay_control`, or `$UNIFIED_EOS_RELAYS=force|none`).
- **A crashed player.** The netcode frees the seat first (`DISCONNECT_US` of silence), the lobby reports the member
  gone later, and the SDK closes P2P after its 30 s reconnect window. One who restarts and joins again comes back as
  the same user ID, but the host's SDK can hold the old connection (lost, or half-open). Two rules get them back: when
  the netcode is done with a peer (`Link.forget`), the host closes that P2P connection, so the user's next request
  opens a fresh one on the same peer number; and a joiner's connection that closes before anything came through it
  is another try, not a lost host. The netcode's new epoch and "newest wins" then seat the same member again.
- **Threading.** One process-wide session behind a mutex; every EOS call happens under it. The link's `recv` ticks
  EOS when it finds nothing (at most every 0.5 ms), so the session thread drives EOS; callbacks run inside the tick,
  each with a fresh context on the ticking thread (the thread that ran `init` may be a finished session's). macOS: the
  SDK finishes HTTP requests on the main thread's run loop: Godot runs one (`Lobby.main_frame` pumps it); a ticking
  main thread without one (the headless binary) pumps it.
- **macOS keychain.** The device-ID token lives in the login keychain, owned by the binary that created it. A
  different build (a new ad-hoc signature) needs the user to allow access once; inside Godot.app (editor, dev runs)
  the owner is Godot itself, so no prompt. Headless tools set `no_keychain_prompts` (fail instead of a dialog:
  "the device ID in the keychain belongs to another build") and `forget_device` at shutdown, so the next build starts
  clean. A dialog whose process has exited stays on screen: click **Deny**, which grants nothing. Never script around
  it.
