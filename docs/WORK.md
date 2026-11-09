# Work

Updated 2026-11-09. Language: **Odin**. Host: **Godot via GDExtension**.

## Phases

1. **Physics rollback spike:** done. The Box3D fork is bit-exact under rollback and across ARM64/x64.
2. **Core prototype** (sim + netcode, headless): done (`archive/PHASE2.md`). Odin chosen, signed off 2026-11-09.
3. **Architecture and Godot integration:** done for a first pass (spikes, module specs pending review, the library
   reshaped into the module map).
4. **The library for real:** in progress. `games/survivor/` is the first playable game on it (`survivor-v0.1.1`);
   a second game, a co-op physics sandbox, is being built.
5. **A larger 3D co-op game** migrated from Unity.

## Decided

- **Module map** (2026-11-09), the base for the module specs. Packages split only where determinism rules differ, a
  consumer needs one piece without another, or third-party code lives; everything else merges. Imports point one
  way, and the CLI never links the sim.
  - Deterministic: `sim` (state tables, handles, RTTI tooling, plain-data check, and the generic harness: tick,
    snapshot ring, checksum, sync-test, replay, events), `physics` (thin Box3D layer: body refs, save/restore/hash,
    determinism settings), `dmath` (deterministic f32 math).
  - Leaves: `wire` (byte reader/writer), `box3d` and `gdext` (third-party bindings).
  - Real-time: `netcode`, `view` (interpolation, smoothing, pools, event confirm/cancel; no Godot).
  - Tools: `headless` (a game's headless binary modes plus test helpers: scenarios, virtual clock, fuzzing),
    `control` (protocol types), `dev` (control server, debug commands, F3 capture, inspector model), `godot_host`
    (everything that touches Godot), `cli`.
  - `imgui` (vendored odin-imgui, pinned, with two local fixes) and `devui` (the ImGui Godot backend, RTTI
    inspector, overlay). **In every build for now** (developer, 2026-11-09); `-define:UNIFIED_DEVUI=false` drops
    it (survivor library 2.95 → 1.53 MB) and `vet` checks that build.
  - **Physics is a plug-in:** `sim` knows nothing about Box3D; physics registers save/restore/hash/serialize procs
    as extra state. The game owns a `World` struct (everything outside the block) and its tick takes it.
  - The test game moves out of `src/` to `games/survivor/`, laid out like a real game repo.
- **Tick rate: a per-game power of two (32, 64, 128 Hz), default 64 Hz.** `dt` is exact (`1/64`), so every `x * dt`
  rounds once less and tick ↔ second conversions are exact. Every time constant is written in seconds and converted
  with `dt`; no raw tick counts in specs or game code. Costs 6.7% more ticks than 60 Hz; the view interpolates to
  any display rate. The survivor timers and `testdata/` get regenerated when the core moves.
- **Defaults for the specs:** an unbiased bounded RNG in `sim` (`rng_below(n)`, Lemire's method; no `% n` for
  ranges); the relay's hard tolerance and the input-delay formula derive from milliseconds and the tick length;
  `view` interpolates from a per-view transform history with exponential-decay smoothing, not whole-frame copies;
  local mode caps clock catch-up after a breakpoint or pause.
- **Generics:** libraries are generic over each game's types with compile-time parametric polymorphism
  (`net.Client(My_State, My_Input)`).
- **v1 covers all four areas** (core + physics + netcode, replays and dev tools, Godot view layer, CLI and skills),
  at least minimally. Until every piece is proven end to end, demo and test games live **inside this repo**;
  real games migrate only after that.
- **State model: (c) hybrid.** Games own typed fixed tables; `unified` discovers them by Odin RTTI over the game's
  `State`, so the inspector, desync diff, set-by-path, serialization and dumps need no per-component code. No code
  generation. Evidence (three prototypes of one mini-game, local branch `claude/state-models-proto-840d93`): (c)
  matched bring-your-own-state at ~8 µs/tick and 46 KiB, an engine-owned ECS was ~2× slower and 1.8× larger.
  Open details go into the core module spec: how tables are detected, whether `using` means "component", optional
  components, cross-table helpers.
- **Consumption:** each game pins `unified` as a git submodule. A committed launcher (`./unified`) builds the CLI
  from that same submodule (cached by source hash), so library and CLI always match. The CLI checks the pinned Odin
  and Godot versions.
- **Config:** `unified.cfg` in Godot's ConfigFile syntax (the same as `project.godot`), read with Odin's
  `core:encoding/ini`. No TOML. It holds only what the CLI needs before building or running (name, tests,
  benchmarks and budgets, CI platforms, extra collections). Runtime settings live in game code and data.
- **Game repo layout** (conventions, not config):
  ```
  /             Godot project root (res://) and Odin workspace root
  project.godot, unified.cfg
  unified/      submodule; ships its own .gdignore
  simulation/   game sim code (Odin); .gdignore created by `unified init`
  game/         everything Godot: scenes, scripts, assets
  .uni/         all artifacts (CLI cache, Box3D builds, game library, F3 feedback, test output), hidden, git-ignored
  .godot/       Godot import cache
  ```
  `unified check` fails if Godot imported anything outside `game/`. To verify in the GDExtension spike: the library
  loads and exports from hidden `res://.uni/bin/`.

- **Godot route: GDExtension.** LibGodot stays a later option (our init runs unchanged under a LibGodot host).
- **View binding: (C) hybrid.**
  - A `.tscn` scene per rich entity kind, with a `SimView` root.
  - MultiMesh bulk views (`SimBulkView`) for 1000+ entities.
  - Rollback-aware view logic in a host-independent Odin package, `unified:view`: interpolation, error smoothing,
    pooling, event confirm/cancel.
  - Views keyed by deterministic spawn keys; events routed to their entity's view.
- **Bindings register Godot classes from the start**, so `SimView` and `SimBulkView` are visible in the editor and
  GDScript view scripts can talk to the sim. Budget: ~1–2 weeks of binding work (the spike left ~7–10 days).
- **Godot bindings:** commit `extension_api.json` for the baseline Godot (**4.7**, marked generated in
  `.gitattributes`; `src/gdext/api/README.md` says how to refresh it) plus `bindings.txt` (the subset we bind; a test
  fails on unused entries); the Odin bindings are generated into git-ignored `*.gen.odin`, cached by input hash;
  `compatibility_minimum` = the baseline. CI runs the binding tests on every supported Godot version.
- **Standard (non-.NET) Godot** for development and CI (locally `~/tools/godot/Godot_v4.7.2.app`).
- **Godot integration rules from the GDExtension spike:**
  - `netcode` gets a step API: `client_step`/`relay_step` with host-owned loops, hooks (input, frame published, ticks
    verified), stop calls, and sleeping until the next deadline instead of a 1 ms poll.
  - Sim and netcode threads use the real-time thread class on macOS by default; Linux uses plain sleeps, measured in
    CI.
  - Hot reload v1 is editor reload only (0.46 s, registered properties kept, the sim restarts). Reload in a running
    game is designed into the netcode step API and built later.
  - GDScript gets one `_sim_event(e)` virtual on `SimView` (it carries cancel), plus a signal for UI.
  - Scene views up to a few hundred per kind, MultiMesh bulk views above that.
- **View logic:** GDScript by default; Odin for anything performance-critical or shared across games (e.g. the
  character rig).

- **CLI in Odin**, replacing every `tools/*.py` script (migrated into subcommands, then deleted). `--json` output
  and a time budget on every command.
- **Skills ship as a Claude Code plugin inside the `unified` repo** (`.claude-plugin/marketplace.json`,
  `skills/<name>/SKILL.md`). `unified init` commits `.claude/settings.json` in the game repo
  (`extraKnownMarketplaces` with a `directory` source at `./unified`, plus `enabledPlugins`). Skills load in place,
  so they always match the library. The `unified` repo uses the same mechanism with path `./`. To verify: the relative
  path works.
- **Live-game tooling split:**
  - Anything that affects the sim goes through typed control-socket commands, recorded as tick-stamped debug commands
    (replayable; generic set-by-path via reflection).
  - View-side inspection uses a dev-only GDScript eval that can't touch sim state.
- **No editor bridge, no daemon.** Agents run cold headless Godot processes (import ~2 s, scene edit 0.25 s,
  validation 0.5 s). A thin optional editor plugin (~150 lines) lets an open editor and agents coexist (reload
  before focus, no dialogs, no lost edits). New worktrees seed `.godot/` by cloning the main checkout's. Texture
  import defaults are pinned so editor and headless imports match. Screenshots of a running game go through the
  control server; one-off scene shots run windowed and restore focus.

- **Testing layers**, each run with `unified test <layer>` and a time budget:
  - **L0 module:** `odin test` per package, plus a Box3D suite (every call we use, exact save/restore,
    cross-platform golden traces, old replays still play after an upgrade). Under 3 s.
  - **L1 sim:** scenarios asserting by reflection path, sync-test always on, fuzzing with shrinking. Under 10 s.
  - **L2 netcode:** in-process sessions on a **virtual clock** with the seeded network simulator. Under 10 s.
  - **L3 multi-instance:** real UDP processes, plus headless Godot game smoke tests.
  - **L4 cross-platform:** committed reference traces and snapshots, replayed in CI.
  - **View logic** (`unified:view`) is tested in Odin at L1 speed.
- **Golden screenshots in CI from the start**, tolerance-based, using whatever the headless-Godot investigation
  proves renders in CI.
- **F3 captures everything cheap:** screenshot, snapshot, input log, frame dump, view state (scene tree and
  view-side values), net stats, note, build info. A recording is snapshot plus input log, replayed deterministically.
- **Release:** the git tag is the only source of a build's version (`tools/release.py` stamps it into the export;
  the repo itself says dev/0.0.0). Protocol changes bump `PROTOCOL_VERSION` and the game's lobby bucket together
  (`survivor/3` at protocol 5); `sim.compat_of` refuses a peer with another build.
- **Tooling:** `dev.py all` is exactly what CI runs; `dev.py game <sub> <game>` takes the game positionally
  everywhere; x86_64 builds go to `out/<mode>-x64/`. CI: only `eos-sdk.yml` has a write token (it runs no repo code);
  runners, actions (by SHA) and downloads (SHA-256) are pinned.
- **Dev UI: Dear ImGui** through vendored odin-imgui and our own ~300-line Godot backend (the spike: same effort and
  frame cost as microui, which lacks tables, plots, combos, multiline text, images and docking).

## In flight

| work | session | branch |
|---|---|---|
| Second game: co-op third-person physics sandbox (platforms, jump pads, carry, throw, two-player heavy carry, a short route); also wraps Box3D step and queries in `src/physics` | physics-coop | `claude/physics-coop-game-91cee0` |

## Done

- Odin-only cleanup: `src/` collection, `tests/` packages, `tools/dev.py`, Odin-only CI on Linux and Windows.
- `survivor-v0.1.1` released (GitHub prerelease, macOS arm64 + Windows x64); crossplay gate passed (`spec/eos.md`).
- Project audit (64 findings) fixed and merged 2026-11-09, plus the survivor first-use hitch fix (`docs/LOG.md`).
  Protocol 5 since: v0.1.1 players can't join a build from main.
- Upstream Odin XXH3 streaming fix: odin-lang/Odin#8257, from `FylmTM/Odin:fix-xxh3-streaming-tail`; its CI waits
  for a maintainer to approve workflows.

## Awaiting the developer's review

1. **Sign off the specs**, all marked "pending developer review": `spec/sim.md`, `netcode.md`, `view.md`,
   `godot_host.md`, `devui.md`, `eos.md`, `survivor-client.md`, `headless.md` (the CLI modes and T1–T9, formerly
   CORE.md), and the short ones written after the code: `wire.md`, `box3d.md`, `imgui.md`. `GAME.md` has M2 changes
   pending too.
2. Everything decided and built autonomously on 2026-11-09: `docs/LOG.md` (start there).
3. The physics sandbox's spec and choices, once its session reports (made without waiting for sign-off).
4. EOS: confirm the portal client policy allows only Connect, P2P and Lobbies (the client secret ships in every
   build). Publishing the EOS SDK release instead of keeping it a draft would remove `eos-sdk.yml`'s write token,
   but it creates a tag: your call.

## Next

- Play the next survivor build with a friend; collect feedback (balance, feel, connection issues). A `v0.1.2` tag
  needs the Mac ↔ Windows crossplay check on protocol 5 first.
- Fold the spec review into the code.
- First-launch shader cost: try Godot's shader baker in the CI export (needs a windowed export on runners and, for
  macOS, the full Metal compiler); a `godot_host` warm-up helper for every game; keep the loop ticking while the
  window is hidden (macOS stalls it up to 1 s).
- How entity kinds and levels are authored (code/data-first recommended, `docs/research/11-view-binding.md`).
- The `unified` CLI in Odin (replaces `tools/*.py`).
- Box3D fork: public load-from-bytes API and clearing stale bytes.
- Golden screenshots in CI (Linux Xvfb/Mesa proved good enough by the headless-Godot spike).
- Backlog without a spec yet (`git show 6994822:docs/research/09-prior-art.md`): desync recovery ladder, typed desync
  reports, build hash in the input log, physics canary, timeline and reverse step in the dev tools, among others.

## Deferred

- Windows ARM64, Linux ARM64; real Windows hardware beyond CI.
- Box3D's AVX2 path (compiled out today) as a separate CI job.
