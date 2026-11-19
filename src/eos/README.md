# `unified:eos`: online play through Epic Online Services

Internet co-op without servers of our own: anonymous device-ID login (no Epic account), a lobby found by a short
code, and EOS P2P (NAT traversal, Epic relays as fallback) carrying the netcode's datagrams. It is a
`netcode.Lobby`: a game reaches it through `eos.lobby`, handed to `godot.init` or to `modes.run`'s `lobbies`, and EOS
starts on the first host or join. Imports `netcode`; `netcode` never imports `eos`. One-time setup, manual tests and
crossplay runs: `docs/EOS.md`.

## Builds and accounts

Lobbies are searched per game, and a joiner on another build is told so before it joins (`Build`). The `build`
attribute is the game's compat with `netcode.PROTOCOL_VERSION` (`build_id`), and the `version` attribute the
project's stamped version, so nothing is bumped by hand: a joiner reads "that game runs survivor 0.1.4; you have
0.1.3", or "that game runs a different build of survivor 0.1.4" when the versions match.

The link vouches for every peer's account (`netcode.Link.account`: "eos" and the remote's product user id, which EOS
authenticated): the relay knows a returning player by it (`src/netcode/README.md`, Members).

## How it works

- **SDK loading.** The library is loaded at run time (`LIB_NAME`, from `default_lib_dirs` unless `lib_dirs` says
  otherwise), so nothing links against it. A missing library or missing credentials (`config.odin`) make `init` fail
  with a reason and online play is off; single player and direct UDP still work. The bindings are hand-written for
  the subset we use (`api.odin`) and checked against the SDK's headers by tests that need the SDK: they run on
  developer machines, not in CI, which has no SDK and no credentials.
- **Login.** `EOS_Connect_Login` with a device-ID access token; no device ID yet: create one and log in again; the
  first login of that device creates the product user. The token lasts about an hour and is renewed by logging in
  again; a failed refresh retries every `RELOGIN_RETRY_US` instead of failing the running session.
- **Lobby.** The host opens a public lobby in the game's bucket, the game's player count at most, host migration
  off, with public attributes `code` (`code_new`), `build` and `version`. A joiner searches by bucket and code (a new
  lobby takes a moment to become searchable: up to `SEARCH_TRIES` searches `SEARCH_RETRY_US` apart), takes the lobby
  owner as its host, checks the build and joins. Any client of the product can list a game's open lobbies with their
  codes: the code is a convenience for friends, not a secret. Members leaving become link `Disconnected` events; the
  host leaving fails the joiner. Async lobby results carry the session generation: a result for a session already
  left is dropped, and its lobby destroyed or left.
- **P2P link.** Socket `unified-<code>`, channel 0, unreliable-unordered packets for everything: the netcode's channel
  provides acks, resends and ordering, as over UDP, and a netcode datagram always fits one EOS packet
  (`P2P_MAX_PACKET`). The host's peers 1, 2, … are joiners in order of their first packet; a joiner's peer 0 is the
  host. A peer number stays its user's while the user is a lobby member; once the user left the lobby and the netcode
  forgot the peer, it goes to the next new user, so any number of people may pass through a lobby,
  `netcode.MAX_PEERS` - 1 at a time. The host accepts P2P only from its lobby's members: a request that comes before
  the lobby says its user joined is held (`HELD_REQUESTS`) and accepted when it does, a stranger's never is, and a
  member who left must join again. The lobby is the only way in. The joiner's first packet makes the connection
  request; if the connection isn't up `CONNECT_WAIT_US` after joining, the joiner closes it, so its next packet asks
  again and the host makes a fresh offer (EOS's signalling sometimes delivers an offer late); after `CONNECT_TRIES` it
  fails. A try that never connected is not a lost host to the netcode, which waits `netcode.FIRST_ANSWER_US` for the
  host's first answer. Relays are allowed by default (`relay_control`, or `$UNIFIED_EOS_RELAYS=force|none`).
- **A crashed player.** The netcode frees the seat first (`netcode.DISCONNECT_US` of silence), the lobby reports the
  member gone later, and the SDK closes P2P after its 30 s reconnect window. One who restarts and joins again comes
  back as the same user ID, but the host's SDK can hold the old connection (lost, or half-open). Two rules get them
  back: when the netcode is done with a peer (`netcode.Link.forget`), the host closes that P2P connection, so the
  user's next request opens a fresh one on the same peer number; and a joiner's connection that closes before
  anything came through it is another try, not a lost host. The netcode's new epoch and "newest wins" then seat the
  same member again.
- **Threading.** One process-wide session behind a mutex, driven by the thread that runs the netcode: the link's
  `recv` ticks EOS when it finds nothing (`online.odin`'s header has the rules). On macOS the SDK finishes HTTP
  requests on the main thread's run loop: Godot runs one (`netcode.Lobby.main_frame` pumps it), and a headless binary's
  ticking main thread pumps it.
- **macOS keychain.** The device-ID token lives in the login keychain, owned by the binary that created it. A
  different build (a new ad-hoc signature) needs the user to allow access once; inside Godot.app (editor, dev runs)
  the owner is Godot itself, so no prompt. Headless tools set `no_keychain_prompts` (fail instead of showing a
  dialog) and `forget_device` (at shutdown), so the next build starts clean. A dialog whose process has exited stays
  on screen: click **Deny**, which grants nothing. Never script around it.
