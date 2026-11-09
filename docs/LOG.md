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
- c6f33d2 **core-lib M2 merged:** survivor phases (lobby with a 3.5 m start circle, match, over → 5 s → world reset),
  every time constant in seconds (non-whole tick counts don't compile), `rng_below`, `survivor.hud`, the ten view
  events, a scenario test forcing explosions/deaths/respawns/resets inside rollback windows (sync-test windows 8 and
  13, plus host + 3 clients under the `bad` profile on a virtual clock). Decisions: player display names travel in
  the netcode hello and a relay roster (protocol v3); enemies and gems keep spawn/hit ticks for view effects; leaving
  resets a player's progress; barrel entity keys are 1-based; `level_up` fires when the level is reached.
- 4c9b99d **godot-layer merged:** `src/gdext` (generator, committed 4.7 `extension_api.json` + `bindings.txt`,
  generated code cached), `src/godot_host` (UnifiedSession, SimView, SimBulkView), `src/view`, `src/imgui` +
  `src/devui` (in all builds), the survivor extension with EOS wired in, `dev.py gen|godot-test|game ...`.
- 642121a **release-ci merged:** `.github/workflows/release.yml` (tags `<game>-v*` → macOS arm64 + Windows x64 zips
  in a GitHub prerelease, with smoke tests; `workflow_dispatch` = Windows only), `tools/release.py` (the same
  locally), `docs/RELEASE.md`. Decision: macOS arm64 only (exported universal, thinned to arm64), since the
  developer's Mac is Apple Silicon and the friend is on Windows.
- Verified on main after the merges: fmt, vet (4 targets), test, check T1–T9 (rollback 0.61 ms at 1000 enemies),
  `game build survivor release`, `game headless` (hash = offline), validate, walk, godot-test, editor-check.
- Next round, in parallel: release-ci runs the Windows dispatch + a local macOS release build; online-eos tests real
  macOS ↔ Windows play through EOS with a Windows CI runner as the remote player; godot-layer adapts `hud()`, names
  and bulk effects to M2 and does a windowed real-play check; game-client polishes the feel with the real extension.
- 0e89bff **Merged release-ci fixes, godot-m2, game-feel, eos-crossplay:**
  - Release builds pass on main for both platforms: Windows on CI (EOS IDs compiled in, EOS DLL shipped) and macOS
    locally (38.5 MB zip after thinning the EOS dylib to arm64). Every CI build of an EOS game checks the IDs are
    compiled in. Tester notes cover the keychain and firewall prompts.
  - The extension uses M2: `hud()` from the sim, roster names, hit-flash/age effects. `dev.py game play`: a bot
    plays single player in a window (also `--bench N`, `--coop`); the dev UI works in release builds.
  - Game feel: steeper leading camera, a start ring that warns as you near its edge and bursts at match start, hit
    and low-HP feedback, gamepad rumble and menu navigation, a match-over summary with best time, lobby code
    auto-copied for the host and auto-pasted for the joiner. `dev.py game tour` (real session, headless) and
    `game coop` (two processes through EOS via the menus) added.
  - **macOS ↔ Windows over the internet through EOS: 3 of 3 runs, 0 checksum mismatches** (a Mac host and a Windows
    CI runner as the remote player; `crossplay` workflow, dispatch only, Windows runner).
  - Verified on main: fmt, vet, test, check T1–T9, release build, headless hash = offline, validate (0.5 s), walk
    (15 steps, 3.2 s), tour (2.6 s), godot-test, editor-check.
- **Found:** the game was unbalanced (a solo bot died at 0:17 before any level-up), two crates sat inside the start
  circle, and levels started at 0. Decided: keep the stress spawner for tests/bench as `stress`, add a default
  `play` tuning (first level-up ~20–30 s, solo survival ~3–5 min, ramp by wave, scaled by player count), measured
  with a headless bot; move the crates out; levels start at 1. core-lib is on it.
- **Needs your attention:** a macOS keychain (SecurityAgent) dialog appeared around 02:10, most likely from an EOS
  test binary. Agents won't type a password into it; online-eos is checking whether it can be withdrawn safely.
- 31e257a **Merged survivor tuning and the crossplay follow-up:**
  - Two tunings stored in the state: `play` (the game) and `stress` (the old dense spawner, kept for T1–T9, the
    scenario test and the bench). `play`: a spawn burst every 2 s of 2 + 1 per wave (max 20), +50% per extra player,
    30 s waves, +10% enemy HP per wave, XP for the next level 8 at level 1 then +4 per level. Tuned with a
    deterministic headless bot over 16 seeds: 1 player reaches the first level-up at 28 s and survives 273 s
    (median); 2 players 25 s / 240 s; 3–4 players run a little past 5 minutes (respawns while others live). A test
    guards the targets. Crates moved out of the start circle; levels start at 1. `--game NAME` picks a game variant
    in the headless binary.
  - Crossplay from main through `workflow_dispatch`: 0 mismatches, also with the Windows side running the exported
    release zip (the build a friend runs).
  - The keychain dialog came from an EOS CLI test run at 02:10 whose process is gone; it's harmless, and **Deny**
    dismisses it. `spec/eos.md` and the tester notes explain keychain prompts in dev runs.
  - Verified on main: all local checks green; local macOS release build + smoke test OK (19 s).
- **Tagged `survivor-v0.1.0` on 31e257a** after CI on main passed (run 42536768520: format + vet, Linux, Windows,
  headless Godot). Release run 42536959936 passed (Windows build, macOS build, prerelease). The prerelease
  "survivor 0.1.0" has `survivor-0.1.0-macos-arm64.zip` (38.5 MB), `survivor-0.1.0-windows-x64.zip` (47.8 MB) and
  `SHA256SUMS.txt`. Re-checked the published macOS zip here: checksum OK, ad-hoc signed, ships `libsurvivor.dylib`
  and the EOS dylib in Frameworks, headless smoke test exit 0 with no errors.
- **Pre-playtest review of the online path** (netcode, eos, godot_host, sim; branch
  `worktree-agent-a897e9e067002558a`, not merged). Fixed, each with a test (`tests/netcode/resilience_test.odin`)
  or a real EOS run:
  - A one-way outage over 10 s left the client in a frozen "Connected" session forever (the relay had dropped it,
    its keepalives kept the client from timing out), and a player rejoining on the same transport peer (EOS: same
    user ID) before the relay's timeout hung in "Connecting" (its Hello read as a duplicate). Datagrams now carry
    epochs (protocol 4, bucket `survivor/2`).
  - At ~280 ms RTT the client stalled 92% of ticks: the 166 ms prediction cap was below one round trip plus the
    input delay. Now 218 ms (14 ticks, the most the 16-tick ring allows): smooth to ~300 ms.
  - After an 8 s outage at ~200 ms RTT a client took 5.2 s to catch up (one 32-tick window per round trip); the
    relay now rotates through the backlog: 0.4 s.
  - Godot exited with SIGSEGV in EOS's threads ~2 times in 3 after an online session (EOS never shut down); the
    transport now has a `shutdown` the host calls at deinitialize. 6/6 clean exits after, 2/6 before.
  - EOS: lobby leave/destroy now goes out at once (it waited for the next session's tick); async lobby results of
    an abandoned session no longer touch the next one (search handle double-release, wrong lobby joined/kept); a
    failed token refresh retries instead of failing a running session.
  - `dev.py game coop --rejoin`: the joiner leaves mid-match and rejoins with the same code (passes over EOS).
  - Found, not fixed: a crashed player's immediate rejoin may not connect for ~30 s (EOS holds the old P2P
    connection); a level-up choice can apply twice (inputs repeated by catch-up or the relay's tolerance; needs an
    edge-triggered choice in the sim and new testdata); see the review report.
