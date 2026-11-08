# `unified:eos`: online play through Epic Online Services

Decided autonomously 2026-11-09, pending developer review.

Internet co-op without servers of our own: anonymous device-ID login (no Epic account), a lobby found by a short
code, and EOS P2P (NAT traversal, Epic relays as fallback) carrying the netcode's datagrams. One-time setup:
`docs/EOS.md`. Imports `netcode` (for `Link`); `netcode` never imports `eos`.

## API

```odin
eos.init(Init_Options{lib_dirs, product_name, product_version, cache_dir, relay_control, no_keychain_prompts}) -> bool
eos.open_host(bucket) -> (netcode.Link, bool)        // login if needed, create the lobby; link usable at once
eos.open_join(bucket, code) -> (netcode.Link, bool)  // login, search by code, join; a malformed code fails here
eos.pump() -> Pump_Result{code, failed}              // tick EOS; the code (host) and a failure are reported once
eos.close()                                          // destroy/leave the lobby, close P2P (login is kept)
eos.status() -> Status{stage, role, code, detail, local, host, network, peers, lib}   // any thread
eos.shutdown()                                       // at exit; EOS can't be initialized again in the process
eos.forget_device()                                  // test tools: delete this machine's device ID
```

`bucket` names the game and its protocol version (e.g. `survivor/1`): lobbies only match inside one bucket, so
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
  is the host, join. Members leaving become link `Disconnected` events; the host leaving fails the joiner.
- **P2P link.** Socket `unified-<code>`, channel 0, unreliable-unordered packets for everything: the netcode's
  channel already provides acks, resends and ordering for its reliable lane, the same as over UDP. Host peers
  1, 2, … are joiners in order of their first packet; a joiner's peer 0 is the host. EOS packets carry 1170 bytes,
  so datagrams carry a 1-byte frame header (larger ones are split and reassembled; netcode's 1152-byte
  datagrams never are). Relays are allowed by default (`relay_control = .Force_Relays` to test them).
- **Threading.** One process-wide session behind a mutex; every EOS call happens under it. The link's `recv`
  ticks EOS when it finds nothing (at most every 0.5 ms), so the session thread drives EOS; callbacks run inside
  the tick. macOS: the SDK finishes HTTP requests on the main thread's run loop: Godot runs one; a ticking main
  thread without one (the headless binary) pumps it.
- **macOS keychain.** The device-ID token lives in the login keychain, owned by the binary that created it. A
  different build (a new ad-hoc signature) needs the user to allow access once; inside Godot.app (editor, dev
  runs) the owner is Godot itself, so no prompt. Headless tools set `no_keychain_prompts` (fail instead of a
  dialog) and `forget_device` at exit, so the next build starts clean.

## Testing

- `tests/eos` (no network): codes (alphabet, unbiased, parsing), framing (every size, loss, reordering,
  garbage), credentials precedence, header layouts, library load.
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
`client.json`. The headless `survivor eos-host --wait-s N --bucket survivor/1` works too where the binary owns
the keychain entry (not on a Mac where Godot.app made the device ID).

Measured 2026-11-09, Mac (home network) ↔ GitHub windows-latest, 64 Hz, every run 0 mismatches:

| Windows client | Path | Common verified checksums | RTT | Delay | Rollbacks (avg depth) | Stall ticks |
|---|---|---:|---:|---:|---:|---:|
| headless, built on the runner | Direct (NAT traversal) | 1137 | 204 ms | 7 | 689 (11.0) | 378 |
| headless, built on the runner | forced relays | 802 | 170 ms | 6 | 491 (10.0) | 97 |
| release export (compiled-in IDs, shipped DLL) | Relayed (EOS's choice) | 770 | 200 ms | 7 | 467 (10.9) | 499 |

