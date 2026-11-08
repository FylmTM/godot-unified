# Log

Decisions and work done while the developer was away, newest last. Each decision says what was picked and why; the
developer reviews them here. Settled ones also land in `WORK.md`.

## 2026-11-09 night: goal

A playable survivor prototype: main menu, settings, the game. Players spawn inside a circle; the match starts when
any player walks out of it. Single player, and online with a friend (macOS ↔ Windows). Builds for macOS and Windows
come from CI, only when a tag is pushed. Dev UI is in every build for now.

Developer's answers before leaving: commit and push to main allowed; online via EOS (account exists; SDK and IDs being
set up, steps in `docs/EOS.md`); macOS builds ad-hoc signed; the friend plays on Windows.

## Decisions

- **Online: EOS** (anonymous device-ID login, lobbies joined by a 6-character code, P2P with Epic relays). It needs
  no server of ours and handles NAT. Direct UDP join by `host:port` stays for LAN and dev. UPnP only if EOS fails.
- **Single player = a host with no remote peers** (in-process relay over loopback), so one code path serves both modes.
- **Game flow:** lobby phase (players spawn in a start circle; the match starts when any player's centre leaves it),
  match (waves), over (every present player dead at once → ~5 s → reset to lobby). Late join stays on.
- **Work split into five parallel sessions**, each on its own branch, merged into main by the orchestrator:
  core-lib (generic sim + netcode step API + survivor sim), godot-layer (gdext, godot_host, view, ImGui devui),
  online-eos (EOS bindings, P2P link, lobby codes, SDK for CI), release-ci (tag-triggered macOS + Windows builds),
  game-client (Godot content: menus, settings, arena, views, HUD, with a GDScript mock until the extension lands).
  A GDScript-facing contract (UnifiedSession / SimView / SimBulkView, InputMap actions) was fixed up front so they
  can work in parallel.
- **Python tooling stays for now** (`tools/dev.py` grows game commands); the Odin CLI replacing it comes later.
- **Docs:** references to the developer's other game removed; physics-engine comparisons removed from research and archive; AGENTS.md
  rule: don't name products we take ideas from (the one "inspired by" line aside) or the developer's other games.

## Work done

- f313149 mentions of the product we take ideas from scrubbed from all repo files except one AGENTS.md line; spike decisions recorded.
- 5f71f4d AGENTS.md naming rule, `docs/EOS.md` (setup steps), this log.
- Docs: the developer's other game and its character names removed everywhere; physics-engine comparisons removed (research/01 now
  states only our decision and rules; `archive/bench/p/` deleted).
- EOS setup done by the developer: C SDK v1.19.2.1 at `~/tools/EOS-SDK-58105819-Release-v1.19.2.1/SDK`, IDs in
  `~/.config/unified/eos.ini`, five `EOS_*` GitHub secrets set. Passed to the online-eos and release-ci sessions.
- Headless-Godot spike follow-up (branch `claude/nifty-panini-064f1c`, 08a178b): standard-build numbers added; Linux
  Xvfb/Mesa screenshots are good enough for tolerance-based golden screenshots.
- GDExtension spike follow-up (`claude/competent-hawking-a92edb`, dadfe88): standard build; the macOS `.app` export
  works with the library in Frameworks and the same sim hash.
- a5c9bc5 **core-lib M1 merged:** generic `sim` (`sim.Game(S, I, W, P)`, tables/handles, `rng_below`, events),
  `physics` plug-in, `dmath`, `netcode` step API + hooks + host (`host_add_link` for extra transports), `headless`;
  the survivor runs at 64 Hz as `out/<mode>/survivor`; T1–T9 + Rosetta pass, CI green. Its decisions (accepted):
  presence bitmask from the relay instead of an "absent" button; tick number kept by the harness and checksummed;
  max players `P` is compile-time (≤ 32); one fixed 24-byte event record (kind, slot, entity, position, value);
  physics bodies hashed in state memory order via RTTI; tolerance 100 ms (7 ticks at 64 Hz), delay ceiling 100 ms,
  prediction cap 166 ms; max datagram 1152 bytes (fits EOS P2P); queued snapshot requests; a joiner replays from
  tick 0 if no snapshot source; hello carries a build-compat id; stateless scripted test inputs; xorshift32 RNG kept.
- 8fd4f79 **online-eos merged:** `src/eos` (runtime-loaded EOS 1.19.2.1 bindings: device-ID login, lobby by 6-char
  code without ambiguous characters, P2P `netcode.Link`), `tools/eos.py` (stages the SDK, packs it as the draft
  release `eos-sdk-1.19.2.1`), headless `survivor eos-host/eos-client`. Verified between two processes on this Mac:
  direct 2 ms RTT, forced Epic relay ~150 ms RTT, 0 desyncs, late join over P2P. Decisions: unreliable P2P for all
  traffic (our channel does reliability); search by lobby attribute with retries (new lobbies take 1–2 s to index);
  SDK in a draft release (no git tag), so CI jobs that fetch it need `contents: write`; macOS keychain prompts stay
  on in games, off for headless runs; `tools/eos.py` writes SDK copies without the browser's quarantine flag (the
  quarantined dylib hung on load).
- 604f775 **game-client merged:** `games/survivor/` Godot content (main menu, settings, connect/lobby overlay with
  the code and LAN host address, arena, start circle, views, HUD, level-up panel, match-over, Esc menu, procedural
  music), a GDScript `MockSession` with the same contract, `tools/game.py` (`dev.py game validate|walk|shots|import`).
  Verified on main: validate 22 scripts + 16 resources OK in 2.3 s; the headless UI walk (14 steps) OK in 3 s.
