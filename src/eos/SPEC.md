# `unified:eos`: online play through Epic Online Services

Decided autonomously 2026-11-09, pending developer review.

Internet co-op without servers of our own: anonymous device-ID login (no Epic account), a lobby found by a short
code, and EOS P2P (NAT traversal, Epic relays as fallback) carrying the netcode's datagrams. One-time setup:
`docs/EOS.md`. Imports `netcode` (for `Link`); `netcode` never imports `eos`.

## API

```odin
eos.init(Init_Options{lib_dirs, product_name, product_version, cache_dir, relay_control, no_keychain_prompts,
                      sdk /* tests: a fake ^Api instead of the library */}) -> bool
eos.open_host(bucket) -> (netcode.Link, bool)        // login if needed, create the lobby; link usable at once
eos.open_join(bucket, code) -> (netcode.Link, bool)  // login, search by code, join; a malformed code fails here
eos.pump() -> Pump_Result{code, failed}              // tick EOS; the code (host) and a failure are reported once
eos.close()                                          // destroy/leave the lobby (ticks EOS ≤ 0.5 s so it goes out), close P2P
eos.status() -> Status{stage, role, code, detail, local, host, network, peers, lib}   // any thread
eos.shutdown()                                       // at exit; EOS can't be initialized again in the process
eos.forget_device()                                  // test tools: delete this machine's device ID
```

`bucket` names the game and its own compatibility counter (e.g. `survivor/4`): the game bumps it by hand when its
builds stop being compatible, at least with every netcode `PROTOCOL_VERSION` (an `#assert` reminds it). Lobbies
only match inside one bucket, so
incompatible builds never meet. `open_host`/`open_join`/`pump`/`close` are the shape of `godot_host.Transport`;
the game's extension wires them (`init` first, with the game library's directory in `lib_dirs`). Lower level:
`host`, `join`, `poll`, `link`, `leave`.

## How it works

- **SDK loading.** The library (`libEOSSDK-Mac-Shipping.dylib`, `EOSSDK-Win64-Shipping.dll`,
  `libEOSSDK-Linux-Shipping.so`) is loaded at run time from `lib_dirs`, else `$UNIFIED_EOS_LIB_DIR`, the
  executable's directory (macOS: also `../Frameworks`), else `$UNIFIED_EOS_SDK`'s `SDK/Bin`. Missing library or credentials
  → `init` fails with a reason and online play is off; single player and direct UDP still work. Bindings are
  hand-written for the subset we use (`api.odin`); `tests/eos` checks every struct's size and offsets and every
  copied constant against the headers with a C compiler, and that the library loads and initializes (both need
  `UNIFIED_EOS_SDK`: they run on developer machines, not in CI).
- **Credentials.** `UNIFIED_EOS_PRODUCT_ID`, `_SANDBOX_ID`, `_DEPLOYMENT_ID`, `_CLIENT_ID`, `_CLIENT_SECRET`: compiled
  in with `-define:UNIFIED_EOS_PRODUCT_ID=...` (`uni build` and `uni release` pass them from the environment or
  `.env`), else the same names from the environment (`uni` fills it from `.env`). CI has none. Never logged.
- **Login.** `EOS_Connect_Login` with `EOS_ECT_DEVICEID_ACCESS_TOKEN`; no device ID yet → `CreateDeviceId` →
  login again; first login of that device → `CreateUser`. Auth expiry (~1 h) logs in again.
- **Lobby.** Host: public lobby, max 4 members, host migration off, attribute `code` = 6 characters from
  `23456789ABCDEFGHJKMNPQRSTUVWXYZ` (no 0/O/1/I/L; crypto random, unbiased). Joiner: search by bucket + code (a
  new lobby takes ~1–2 s to become searchable: up to 5 searches 1.2 s apart), the lobby owner's Product User ID
  is the host, join. Members leaving become link `Disconnected` events; the host leaving fails the joiner. Async
  lobby results carry the session generation: a result for a session already left (Leave, then Host/Join again
  quickly) is dropped, and its lobby destroyed or left. A failed token refresh (~1 h in) retries every 15 s
  instead of failing the running session. A crashed player rejoins with the same user ID: on one machine it is back
  in ~6 s (`uni coop --crash`: the OS reports the dead socket, the host sees the P2P connection close, the lobby
  keeps the member and the netcode takes the new incarnation on the same peer). Across the internet nothing reports
  the death, so the host may wait out the SDK's 30 s reconnect window first; not measured yet (#32).
- **P2P link.** Socket `unified-<code>`, channel 0, unreliable-unordered packets for everything: the netcode's
  channel already provides acks, resends and ordering for its reliable lane, the same as over UDP. Host peers
  1, 2, … are joiners in order of their first packet; a joiner's peer 0 is the host. EOS packets carry 1170 bytes,
  so datagrams carry a 1-byte frame header (larger ones are split and reassembled; netcode's 1152-byte
  datagrams never are). Relays are allowed by default (`relay_control = .Force_Relays` to test them).
- **Threading.** One process-wide session behind a mutex; every EOS call happens under it. The link's `recv`
  ticks EOS when it finds nothing (at most every 0.5 ms), so the session thread drives EOS; callbacks run inside
  the tick, each with a fresh context on the ticking thread (the thread that ran `init` may be a finished
  session's). A game passes its version (`godot_host.app_version`, the project's stamped version) as
  `product_version`. macOS: the SDK finishes HTTP requests on the main thread's run loop: Godot runs one; a ticking main
  thread without one (the headless binary) pumps it.
- **macOS keychain.** The device-ID token lives in the login keychain, owned by the binary that created it. A
  different build (a new ad-hoc signature) needs the user to allow access once; inside Godot.app (editor, dev
  runs) the owner is Godot itself, so no prompt. Headless tools set `no_keychain_prompts` (fail instead of a
  dialog) and `forget_device` at exit, so the next build starts clean.
- **Keychain dialogs in dev runs.** A "wants to use your confidential information stored in
  com.epicgames.sdk.connect.access_token" dialog means a binary that doesn't own the entry asked for it. To avoid it:
  play online from Godot (editor, `uni run`, `godot --headless --path games/survivor`), which owns the
  entry; the headless `survivor` binary never shows the dialog (it fails with "the device ID in the keychain
  belongs to another build" instead), so don't mix it with Godot runs on one Mac; an exported build asks once per
  build (Always Allow is fine: it is the game's own anonymous ID). A dialog whose process has exited (killed or
  crashed while waiting) stays on screen: click **Deny**, which grants nothing. Never script around it.

## Testing

- `tests/eos` (no network): codes (alphabet, unbiased, parsing), framing (every size, loss, reordering,
  garbage, a datagram over MAX_PARTS refused at the sender), credentials precedence, header layouts, library
  load, and the lobby state machine on a fake SDK: host, leave, host again on threads that exit in between, a
  lobby that arrives after leave is destroyed, a failed request reports its reason once, join, shutdown.
- Two processes on one machine through EOS (the `.env`'s `UNIFIED_EOS_*` IDs and SDK), the game's headless binary:
  `survivor eos-host --ticks 1920 --code-file F` and `UNIFIED_EOS_FRESH_DEVICE=1 survivor eos-client --code C
  --ticks 1920` (`--relays force` to go through Epic's relays). The fresh device gives the second process its own
  Product User ID. A pass: both processes play to the end with 0 desyncs, direct and relayed.

## Crossplay (macOS ↔ Windows over the internet)

By hand, on two machines (no CI job): a Mac hosts, a Windows machine joins by code and plays the scripted session;
both sides print their verified checksums. Mac side, the game itself:
`godot --headless --path games/survivor -- --host-online --scripted --ticks 15360 --quit-at-end`
(`UNIFIED_EOS_RELAYS=force` to force Epic's relays). Windows side, the release headless binary:
`.out/release/survivor.exe eos-client --code XXXXXX --ticks 15360 --bucket <the game's bucket>` (`SURVIVOR_BUCKET` in
`games/survivor/simulation/extension/extension.odin`; `--relays force` to force the relays), or the exported game
from a release zip. Joining after the host started is a late join with a snapshot. Compare the `checksums` of the two
sides' result lines. The headless `survivor eos-host --wait-s N --bucket <the game's bucket>` hosts too where the
binary owns the keychain entry (not on a Mac where Godot.app made the device ID).

A run passes when every common verified checksum matches (0 mismatches). The measured runs so far (RTT, input
delay, rollbacks, stalls, the survivor-v0.1.1 release gate) are on the EOS review issue, #11.

- **Path labels.** Each side labels the path from its own P2P "connection established" notification, so host and
  client can disagree (Direct on the host, Relayed on the client) when EOS switches routes after connecting. Treat
  the label as a hint; RTT is the better signal.
- **Drop and rejoin.** A client killed without a clean leave shows up on the host as a lobby member Disconnected
  within ~20 s; the host closes P2P when the SDK's 30 s reconnect window runs out. A new machine can then join
  the same code as a new peer. `uni coop survivor --rejoin` covers a clean leave and rejoin by the same
  player on one machine, `uni coop survivor --crash` a crash (the joiner kills its own process) and rejoin by the
  same player, timed on both sides.

