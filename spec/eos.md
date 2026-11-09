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

`bucket` names the game and its own compatibility counter (e.g. `survivor/3`): the game bumps it by hand when its
builds stop being compatible, at least with every netcode `PROTOCOL_VERSION` (an `#assert` reminds it). Lobbies
only match inside one bucket, so
incompatible builds never meet. `open_host`/`open_join`/`pump`/`close` are the shape of `godot_host.Transport`;
the game's extension wires them (`init` first, with the game library's directory in `lib_dirs`). Lower level:
`host`, `join`, `poll`, `link`, `leave`.

## How it works

- **SDK loading.** The library (`libEOSSDK-Mac-Shipping.dylib`, `EOSSDK-Win64-Shipping.dll`,
  `libEOSSDK-Linux-Shipping.so`) is loaded at run time from `lib_dirs`, else `$UNIFIED_EOS_LIB_DIR`, the
  executable's directory (macOS: also `../Frameworks`), else the repo's staged SDK. Missing library or credentials
  → `init` fails with a reason and online play is off; single player and direct UDP still work. Bindings are
  hand-written for the subset we use (`api.odin`); `tests/eos` checks every struct's size and offsets and every
  copied constant against the headers with a C compiler, and that the library loads and initializes.
- **Credentials.** Compiled in with `-define:EOS_PRODUCT_ID=...` (and `EOS_SANDBOX_ID`, `EOS_DEPLOYMENT_ID`,
  `EOS_CLIENT_ID`, `EOS_CLIENT_SECRET`; `python tools/eos.py defines` prints them from the environment, CI has
  them as secrets), else the same names from the environment, else `~/.config/unified/eos.ini` (`[eos]`,
  `$UNIFIED_EOS_INI` overrides the path). Never logged.
- **Login.** `EOS_Connect_Login` with `EOS_ECT_DEVICEID_ACCESS_TOKEN`; no device ID yet → `CreateDeviceId` →
  login again; first login of that device → `CreateUser`. Auth expiry (~1 h) logs in again.
- **Lobby.** Host: public lobby, max 4 members, host migration off, attribute `code` = 6 characters from
  `23456789ABCDEFGHJKMNPQRSTUVWXYZ` (no 0/O/1/I/L; crypto random, unbiased). Joiner: search by bucket + code (a
  new lobby takes ~1–2 s to become searchable: up to 5 searches 1.2 s apart), the lobby owner's Product User ID
  is the host, join. Members leaving become link `Disconnected` events; the host leaving fails the joiner. Async
  lobby results carry the session generation: a result for a session already left (Leave, then Host/Join again
  quickly) is dropped, and its lobby destroyed or left. A failed token refresh (~1 h in) retries every 15 s
  instead of failing the running session. Known limit: after a player's program crashes, EOS keeps the old P2P
  connection for ~30 s, and a rejoin with the same user ID may not connect until it times out (retry).
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
  play online from Godot (editor, `dev.py game run`, `godot --headless --path games/survivor`), which owns the
  entry; the headless `survivor` binary never shows the dialog (it fails with "the device ID in the keychain
  belongs to another build" instead), so don't mix it with Godot runs on one Mac; an exported build asks once per
  build (Always Allow is fine: it is the game's own anonymous ID). A dialog whose process has exited (killed or
  crashed while waiting) stays on screen: click **Deny**, which grants nothing. Never script around it.

## Testing

- `tests/eos` (no network): codes (alphabet, unbiased, parsing), framing (every size, loss, reordering,
  garbage, a datagram over MAX_PARTS refused at the sender), credentials precedence, header layouts, library
  load, and the lobby state machine on a fake SDK: host, leave, host again on threads that exit in between, a
  lobby that arrives after leave is destroyed, a failed request reports its reason once, join, shutdown.
- Two processes on one machine through EOS (the developer's ini + staged SDK), the game's headless binary:
  `survivor eos-host --ticks 1920 --code-file F` and `UNIFIED_EOS_FRESH_DEVICE=1 survivor eos-client --code C
  --ticks 1920` (`--relays force` to go through Epic's relays). The fresh device gives the second process its own
  Product User ID. Measured 2026-11-09 on one Mac: lobby ready 3.2–3.6 s, join 4.0–4.7 s; direct RTT 1.8–2.1 ms;
  relayed RTT 149–152 ms (input delay 6, ~54 rollbacks of depth ~9 in 30 s); late join with a 161 KB snapshot over
  P2P; 0 desyncs.

## Crossplay (macOS ↔ Windows over the internet)

`.github/workflows/eos-crossplay.yml` (manual, Windows runner only): a Mac hosts, the runner joins by code and plays
the scripted session; both sides print their verified checksums. Mac side, the game itself:
`godot --headless --path games/survivor -- --host-online --scripted --ticks 15360 --quit-at-end`
(`UNIFIED_EOS_RELAYS=force` to force Epic's relays); then `gh workflow run eos-crossplay.yml -f code=XXXXXX -f
ticks=15360 -f client=source|export [-f relays=force] [-f release_run=ID]`. The runner joins ~1–1.5 min later
(a late join with a snapshot). Compare the `checksums` of the host's `unified: result` line with the artifact's
`client.json`. The headless `survivor eos-host --wait-s N --bucket survivor/3` works too where the binary owns
the keychain entry (not on a Mac where Godot.app made the device ID).

Measured 2026-11-09, Mac (home network) ↔ GitHub windows-latest, 64 Hz, every run 0 mismatches:

| Windows client | Path | Common verified checksums | RTT | Delay | Rollbacks (avg depth) | Stall ticks |
|---|---|---:|---:|---:|---:|---:|
| headless, built on the runner | Direct (NAT traversal) | 1137 | 204 ms | 7 | 689 (11.0) | 378 |
| headless, built on the runner | forced relays | 802 | 170 ms | 6 | 491 (10.0) | 97 |
| release export (compiled-in IDs, shipped DLL) | Relayed (EOS's choice) | 770 | 200 ms | 7 | 467 (10.9) | 499 |
| headless, `workflow_dispatch` from main (477cf5a) | Relayed | 773 | 229 ms | 7 | 471 (11.0) | 254 |
| release export of main (run 42535534651) | Relayed | 847 | 189 ms | 7 | 509 (11.0) | 282 |

Release gate for survivor-v0.1.1 (main 6da8839: protocol 4, 218 ms prediction cap, faster catch-up), same setup,
every run 0 mismatches. Stalls fell from hundreds of ticks to 0–11; rollback depth tops out at 14 ticks (the cap):

| Windows client | Path (host / client) | Common verified checksums | RTT | Delay | Rollbacks (avg / max depth) | Stall ticks |
|---|---|---:|---:|---:|---:|---:|
| headless, built on the runner | forced relays (Relayed / Relayed) | 771 | 233 ms | 7 | 481 (13.1 / 14) | 3 |
| headless, built on the runner | relays allowed (Direct / Relayed) | 806 | 152 ms | 6 | 498 (9.6 / 11) | 11 |
| release export of main (run 42541894705) | relays allowed (Direct / Relayed) | 696 | 237 ms | 7 | 433 (13.0 / 14) | 3 |
| headless, after another client dropped (6 min session) | Direct / Relayed | 818 | 235 ms | 7 | 523 (14.0 / 14) | 0 |

- **Path labels.** Each side labels the path from its own P2P "connection established" notification, so host and
  client can disagree (Direct on the host, Relayed on the client) when EOS switches routes after connecting. Treat
  the label as a hint; RTT is the better signal.
- **Drop and rejoin.** The first client's run was cancelled ~60 s into the session (the process is killed, no clean
  leave). The host saw the lobby member Disconnected within ~20 s and closed P2P when the SDK's 30 s reconnect
  window ran out. A second runner then joined with the same code at tick 9968 as a new peer and played to the end.
  Each runner is a new machine, so this is a different Product User ID, not the same player coming back.
  `dev.py game coop survivor --rejoin` covers a clean leave and rejoin by the same player on one Mac (passed on
  6da8839).

