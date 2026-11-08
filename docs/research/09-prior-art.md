# 09: Prior art

Projects, talks and write-ups that docs 01–08 didn't cover, and what they teach us (2026-11-07). Topics
those docs already handle (GGRS, Quantum's defaults, Box3D/Jolt determinism, Bevy Remote Protocol, Godot MCP
bridges, Factorio's CRC, AoE/StarCraft lockstep, Overwatch/For Honor) are only cross-referenced here. Claims I
couldn't check against a primary source are marked *(unverified)*. Where I read source code, I say so.

## TL;DR: the 10 most actionable insights

1. **Every shipped 3D rigid-body game with rollback heals with authoritative state rather than trusting
   determinism alone.** Rocket League, Roblox Server Authority (2026), Unreal Chaos resimulation, SnapNet (Rivals 2),
   PurrNet and Teardown all correct clients from server state. Quantum is the exception, and it pays with
   fixed-point physics written in-house. → **For unified:** keep input-only determinism as the model, but give the
   relay a *heal* path: on a checksum mismatch, the host sends the zstd state block (the late-join payload we already
   plan) and the client re-bases. A cross-architecture float bug then costs a hitch, not a dead session. PurrNet ships
   exactly this as `DesyncPolicy.Resync`.
2. **PurrNet gets C# determinism by not using hardware floats at all.** Its `sfloat` is a soft float that keeps the
   IEEE binary32 bit layout but does every operation in integer code. Its `FP` is Q32.32 fixed point. Both are
   vendored MIT code (§1). → The C# family's open question (RyuJIT x64 vs ARM64) has a known fallback, at a CPU cost.
   (C# was dropped; see `../archive/`.)
3. **Passing sync-test doesn't prove determinism.** Fish Folk's bones docs warn about bugs that "only exhibit
   themselves when restarting the game". Riot found map orders that depended on allocator addresses, which differed
   between Windows versions. → Add a **cold-vs-warm replay test** to CI: replay the same input log in a fresh process
   and in a long-lived process (after rollbacks, hot reloads and level reloads), and compare per-tick hashes.
4. **Several clients in one process only works if it's designed in from day one.** Teardown built "multiple game
   instances in one process" for debugging and dropped it because of "historical design choices". Photon Fusion's
   Multi-Peer Mode warns that "statics and singletons will run into conflicts". → Lint-ban mutable statics/globals in
   sim and net code. Everything hangs off a `Session` value. Test with 4 sessions in one process (phase 2 does).
5. **Split determinism domains when one piece is too big to sync.** Teardown's destruction is a deterministic stream
   of fixed-point commands ("cut hole at voxel x,y,z"), while transforms are prioritized state sync within about
   1 Mbit per client. → If a future system (voxels, huge swarms) won't fit our rollback budget, it can run as a
   deterministic command stream outside the rollback window instead of forcing the whole sim into it.
6. **Classify mismatches, don't just detect them.** snopek's Godot rollback addon writes per-peer match logs and
   replays them in a Log Inspector. It labels mismatches MISSING / EXTRA / REORDER / DIFFERENT, and REORDER points
   straight at iteration-order bugs. → Our desync differ (08) should report *what kind* of difference it found per
   table, not only "hash differs at tick T".
7. **Stale handles are a classic desync source.** Forrest Smith's Demigod desync took almost a week: a freed object's
   memory was reused and a dangling pointer kept "working". → Generational handles (02) close this class of bug. Debug
   builds should also poison freed slots so a stale read changes the hash at once.
8. **Agents need pause/step and structured state, and they lie about passing.** VideoGameBench: pixel-only VLM agents
   finished 0.48% of real-time games, and pausing while the model thinks helped only modestly. Roblox's 2026 playtest
   agent "may return Pass even if… it failed". The Factorio Learning Environment's code-as-action REPL with runtime
   assertions works. → `uni` tests should pass only on **sim-state assertions**, never on the agent's own verdict.
   Actions are scripts against typed queries, and time is stepped, not real-time.
9. **The input/state boundary is where to record.** Riot recorded network messages "above our low-level network
   system", unified six clocks into one, merged all PRNGs into one seeded XOR-shift, and built tooling that flags
   values that "end a frame with a nondeterministic value". → We already have one input channel. Also zero the state
   block on allocation and diff two runs' blocks byte by byte in debug, which catches uninitialized fields.
10. **A recorded input loop plus a snapshot is the best tuning tool.** Handmade Hero's "looped live code editing"
    replays the last N seconds over a memory snapshot while you edit, and Tomorrow Corporation's in-house engine
    scrubs and reverse-debugs whole play sessions. → Give the timeline a **loop mode**: snapshot at A, replay inputs
    A→B forever while configs and shaders hot-reload. It's nearly free with our block, and it's the best way to tune
    feel.

## 1. C#/.NET determinism, and PurrNet in depth

### PurrNet / PurrDiction (read from source)

PurrNet is an MIT Unity networking library. Its prediction layer is a separate repo,
[PurrNet/PurrDiction](https://github.com/PurrNet/PurrDiction) (MIT, © 2025 Pebbles Games / Riten SARL). I cloned it
(commit `5d4f931`, 2026-11-06). Docs:
[deterministic identity](https://purrnet.dev/docs/client-side-prediction/deterministic-identity),
[overview](https://purrnet.dev/docs/client-side-prediction/overview).

**Number types.** Two, both vendored into `Runtime/`:
- **`sfloat`** (`SoftFloat/sfloat.cs`). The header says "mostly from
  [CodesInChaos/SoftFloat](https://github.com/CodesInChaos/SoftFloat)". The folder LICENSE is Kimbatt's (2021), the
  same soft float used by [Kimbatt/unity-deterministic-physics](https://github.com/Kimbatt/unity-deterministic-physics),
  a Unity DOTS Physics 0.6 fork converted to soft floats. The internal representation is "identical to IEEE binary32"
  (a `uint rawValue`), but `+ − × ÷` are integer routines. Transcendentals (`MathS`: `Sqrt`, `Exp`, `Log`, `Pow`,
  `Atan2`, `Acos`, …) are ported from Rust's `libm` (Jorge Aparicio's MIT notice). `Sin` is **Bhaskara I's
  approximation**, with a max absolute error I computed at 0.0016, and `Cos(x) = Sin(x + π/2)`. There are vector and
  quaternion types too (`SVec2/3/4`, `SQuat`).
- **`FP`** (`FixedPoint/FP.cs`): a `long` in **Q32.32** (`MathFP.Shift = 32`). The licence is FixPointCS (Jere
  Sanisalo, Petri Kero). As in Quantum, the implicit `float → FP` conversion deliberately throws.

**How determinism is achieved.** By construction: sim math is integer-only, so neither RyuJIT, IL2CPP nor the CPU
can change results. The rules come from the docs: `float` only in `UpdateView`, `PredictedTime`/`PredictedRandom`
instead of Unity's, and state mutated only in `SimulationStart`/`Simulate` (never in `Awake`). The "executed" flag of
`SimulationStart` is itself rollback state. CodesInChaos's README says basic ops are "within one ulp", **not
correctly rounded**, so `sfloat` results won't match hardware `float` bit for bit. You can't mix the two, and you
can't use it as a reference oracle for hardware floats. (Whether Kimbatt fixed the rounding is *unverified*.) PurrNet
publishes no performance numbers. Every op is a branchy software routine, so expect an order of magnitude or more
over hardware (estimate).

**Prediction/rollback design.** It's a server-authoritative tick loop. `PredictedIdentity<STATE>` holds float logic
reconciled from server state. `DeterministicIdentity<STATE>` and `<INPUT, STATE>` are the input-only, bit-stable
variant inside the same loop. Inputs travel on a "guaranteed transcript": every frame re-sends all input ticks since
the last ack, up to 32. Past that cliff, the server sends a full frame that re-anchors the client. Desync detection
uses tick-salted hashes of *settled* state, every 0.25 s by default. Policies: `Ignore` (default), `Report`,
`Resync` (full re-baseline) and `Correct` (resend one identity's authoritative state). The hash is FNV-1a folded to
**16 bits** (`DesyncPolicy.cs`), so roughly 1 in 65k desyncs goes unnoticed per check. `SanitizeInput` lets the
server clamp inputs. Unity PhysX bodies are rolled back by saving and restoring rigidbody state, then re-stepping.
They're *not* deterministic and are corrected by state; a physics-event history dedupes collision callbacks across
resims.

**Testing.** `Assets/PredictionTests/README.md` describes a 32-scenario, multi-process suite (`-batchmode
-nographics -role host|client -count 3 -results x.json`) with simulated 40–80 ms latency in CI and world-digest
convergence checks. `CliffRecoveryScenario` forces 100% packet loss for 2.5 s and requires the heal to arrive.

**Take for unified:** the policy ladder (report → resync → per-entity correct), the input-redundancy window with a
full-state cliff, tick-salted hashes of settled ticks only, and a scenario suite with named regression scenarios. Our
hash should be 64-bit.

### Other .NET approaches

- **Unity Burst `FloatMode.Deterministic`**. It shipped after all, but nobody has shown it working across
  architectures. The Unity 6000.6/6000.7 manual documents it as "consistent across all supported platforms", 64-bit
  only. It uses deterministic math implementations, **flushes subnormals to zero everywhere**, and doesn't guarantee
  NaN bit patterns ([docs](https://docs.unity.com/en-us/engine/6000.7/manual/programming-environment/script-compilation/burst/compilation/float-precision-determinism)).
  Burst 1.8.26 (2025-11) added a warning that intrinsics in Deterministic methods need bit-equivalent behaviour on
  other architectures ([changelog](https://docs.unity3d.com/Packages/com.unity.burst@1.8/changelog/CHANGELOG.html)).
  Unity Physics itself is "deterministic per architecture", and cross-arch is "a question of Burst"
  ([2020 thread](https://forum.unity.com/threads/what-is-the-current-state-of-the-cross-platform-determinism-of-unity-physics.922055/)).
  I found no x64 ↔ ARM64 Unity Physics result. **Take:** a vendor that controls its compiler still made
  cross-arch float determinism a compiler mode, not a default. That supports our "one math module + CI" stance.
- **RyuJIT x64 vs ARM64:** no new evidence beyond `../archive/stacks/csharp.md`. Searches turned up only anecdotes: FAF players
  on ARM Windows report `_controlfp` behaving differently
  ([forum](https://forum.faforever.com/topic/2796/desync-on-all-replays-and-games-with-windows-11-arm-on-m1-max-apple/21)),
  and flycast's arm64 dynarec desyncs from x86_64 ([issue](https://github.com/inada-s/flycast/issues/370)). Both are
  native or emulator cases, not .NET. It stays a measure-it item.
- **Fixed-point libraries:** [FixedMath.Net](https://github.com/asik/FixedMath.Net) (Q31.32, old), [FixedMathSharp](https://www.nuget.org/packages/FixedMathSharp/7.0.0)
  (Q32.32, active on NuGet), FixPointCS (inside PurrDiction), and Quantum `FP` (Q48.16, 01). Q32.32 is the common
  choice when you need range.
- **Netick** (free, server-authoritative state sync) runs several "sandboxes", servers and clients, in one Unity
  process ([docs](https://netick.gitbook.io/v1/core-concepts)). **Fusion** has the same in Multi-Peer Mode
  ([docs](https://doc.photonengine.com/fusion/v2/manual/testing-and-tooling/multipeer)). Neither requires
  determinism.
- **SnapNet** "Strict determinism not required": server-authoritative prediction plus rollback for gameplay and rigid
  bodies, as plugins for Unreal and Unity ([site](https://www.snapnet.dev/)). Its default budget is up to 50 ms
  covered by input delay (3 frames), then up to 100 ms by prediction (6 frames)
  ([rollback post](https://www.snapnet.dev/blog/netcode-architectures-part-2-rollback/)). That's close to our
  proposal of 1+ ticks of delay and a 10-frame cap.
- **BEPUphysics v2**: fixed-point only via the v1 fork (01); nothing new found.

## 2. Rollback and prediction frameworks

- **Lightyear 0.31** (Bevy 0.20, [repo](https://github.com/cBournhonesque/lightyear)). Server-authoritative
  prediction, interpolation and lag compensation. It also offers **deterministic input-only replication**,
  "compatible with both lockstep and prediction/rollback", plus host-client mode and Steam/WebTransport via `aeronet`.
  Whether its deterministic mode has the *server* stamp inputs the way Quantum does is *unverified*. Worth reading its input
  buffer and transport code.
- **bones / Fish Folk Jumpy** ([networking doc](https://docs.rs/crate/bones_framework/latest/source/src/networking.md)).
  A "Game" of "Sessions", each with its own ECS world, built so it can be snapshotted. P2P GGRS over pluggable
  matchmaker sockets (online, LAN), and `--sync-test-check-distance 7` for local rollback testing. The lesson is the
  restart-only nondeterminism quoted in the TL;DR.
- **netfox** (Godot, [RollbackSynchronizer](https://foxssake.github.io/netfox/latest/netfox/nodes/rollback-synchronizer/)).
  Server-authoritative rollback configured by *property lists*: state properties (server-owned) and input
  properties (player-owned), kept on separate nodes because they have different owners. Diff states are optional. It
  shows how small a rollback layer gets when the engine can enumerate state.
- **snopek godot-rollback-netcode** ([repo](https://github.com/SnoringCatGames/godot-rollback-netcode)). GGPO-style
  P2P with `_save_state`/`_load_state` per node. `SyncManager.start_logging()` writes detailed match logs, and
  `SyncReplay` plus the editor's Log Inspector replay them and show typed mismatches
  ([REORDER issue](https://gitlab.com/snopek-games/godot-rollback-netcode/-/issues/30)).
- **Unreal Mover + Network Prediction / Chaos networked physics.** Mover is still experimental in 5.7, with Beta
  expected around 5.8 per an Epic forum post *(informal)*
  ([docs](https://dev.epicgames.com/documentation/en-us/unreal-engine/mover-in-unreal-engine)). Chaos has three
  replication modes. **Predictive Interpolation** "compares [server state] with the cached physics state in its
  history… If the state information differs enough, it triggers a physics resimulation". **Resimulation** is fully
  forward-predicted and more expensive
  ([overview](https://dev.epicgames.com/documentation/en-us/unreal-engine/networked-physics-overview)). Take:
  threshold-gated resim is how a state-sync engine keeps physics rollback affordable.
- **Roblox Server Authority** (Studio beta, then announced 2026-07,
  [newsroom](https://about.roblox.com/newsroom/2026/07/creating-responsive-cheat-resistant-games-roblox-server-authority),
  [beta post](https://devforum.roblox.com/t/studio-beta-build-fair-responsive-games-with-server-authority/4139157)).
  Clients predict, roll back predicted instances to the last agreed frame and resimulate, physics included. Mismatched
  instance attributes trigger the rollback ([PredictionMode](https://create.roblox.com/docs/reference/engine/enums/PredictionMode)).
  The largest UGC platform has moved to predict/rollback with state correction, not determinism.
- **Rune** (JS multiplayer SDK, [philosophy](https://developers.rune.ai/docs/how-it-works/philosophy),
  [deterministic JS](https://developers.rune.ai/blog/making-js-deterministic-for-fun-and-glory/)). Logic runs on
  clients and server, and the server resolves conflicts. A seeded RNG that rolls back, plus an **eslint plugin**
  banning globals and locale functions. That's the same idea as our clippy/BannedApi lints.
- **Easel** (language plus hosted engine, [rollback doc](https://easel.games/docs/learn/multiplayer/rollback-netcode)).
  Determinism and automatic incremental snapshotting are guaranteed by the language, coroutines included. Its author
  evaluated Lua and Rhai and found no reliable way to get determinism and snapshots
  ([r/rust thread](https://redlib.hackliberty.org/r/rust/comments/1kmuvzx/easel_code_multiplayer_games_without_having_to/msepb8a/?context=3),
  *secondary*). That supports doc 04's "no scripting layer".
- **Riot, "Determinism in League of Legends"** ([intro](https://technology.riotgames.com/node/67),
  [implementation](https://www.riotgames.com/en/news/determinism-league-legends-implementation),
  [unified clock](https://technology.riotgames.com/node/73)). Retrofitted onto a server with 8 clock instances from 6
  implementations. Variable frame dt was kept but recorded, and pointer-keyed map order varied across Windows
  versions. They chose not to make addresses deterministic (that would have meant disabling ASLR) and fixed the
  orderings instead. The payoff was **Chronobreak**: officials rewind a live esports game. VALORANT replays only work
  on the patch they were recorded on ([guide](https://www.esports.net/wiki/guides/valorant-replay-system-explained/)).
  Replays tied to one build are an accepted industry norm.
- **Already covered elsewhere:** GGPO/GGRS, backroll, NetplayJS, GekkoNet and Backdash (05); Overwatch, Rocket
  League, For Honor, AoE and StarCraft (05); Factorio desync tooling (08).

## 3. Engines built around determinism, rollback or data-oriented memory

- **Handmade Hero, day 23, "looped live code editing"** ([guide](https://guide.handmadehero.org/code/day023/)).
  All game memory is one block at a fixed base address, so recording means copying the block and logging input.
  Playback loops while the game DLL hot-reloads. It's our state-block idea, used as a *tuning* tool.
- **Karl Zylinski's Odin hot-reload template**
  ([repo](https://github.com/karl-zylinski/odin-raylib-hot-reload-game-template)). The host keeps one game-memory
  pointer across DLL reloads. If the memory struct's size changes, it does a full reset *(from memory, unverified)*.
  Take: a layout hash in the snapshot header decides between "hot reload keeps state" and "restart + replay".
- **Ryan Fleury, arenas** ([post](https://www.rfleury.com/p/untangling-lifetimes-the-arena-allocator)). Group
  allocations by lifetime. For us that means three lifetimes: the persistent state block, a per-tick scratch arena
  that is reset every tick and never snapshotted, and per-session view memory.
- **Bitsquid/Stingray blog**: the ID lookup table with generations
  ([2011](https://bitsquid.blogspot.com/2011/09/managing-decoupling-part-4-id-lookup.html)) and data-oriented
  component managers ([2014](https://bitsquid.blogspot.com/2014/08/building-data-oriented-entity-system.html)), the
  ancestors of doc 02's handles.
- **Our Machinery's "The Truth"** ([post](https://gamedeveloper.com/programming/the-story-behind-the-truth-designing-a-data-model),
  [archive](https://ruby0x1.github.io/machinery_blog_archive/post/the-document-model-and-the-machinery)). The editor
  data model is typed objects referenced by IDs. Every change is recorded as (object, property, old, new), which
  gives undo, copy/paste and real-time collaboration "for free". Large blobs live in opaque buffers. Open issues the
  author listed: partial loading, and git-friendly files. Take: our in-game level editor (and agent edits) should be
  an op log of this shape, separate from sim state. The same log is undo, the agent audit trail, and later
  collaboration. (The Machinery shut down abruptly in 2022, a reminder about building on small proprietary engines.)
- **Tomorrow Corporation tech demo** (YouTube "Tomorrow Corporation Tech Demo", circulated 2023-02,
  [secondary](https://handmade.network/p/675/blindspot/blog)). An in-house language, compiler, editor and engine. Every
  play session is recorded deterministically, so you can scrub it like video and **run the debugger backwards** from
  a crash to where the bad value appeared. With snapshots plus an input log, "step back" is "restore the nearest
  snapshot, resim to T−1". We can offer that from the agent API.
- **Planetary Annihilation ChronoCam** ([post](https://www.forrestthewoods.com/blog/tech_of_planetary_annihilation_chrono_cam/)).
  The server stores history as per-property curves, so the whole match can be scrubbed and "if no curves change then
  zero bandwidth is consumed". It's an alternative to snapshot+resim for replay *viewers*, not for rollback.
- **Supreme Commander / Demigod desyncs** ([post](https://www.forrestthewoods.com/blog/synchronous_rts_engines_and_a_tale_of_desyncs/)).
  A full-state hash once a second, then binary search with hash prints while walking the state. Root causes were
  uninitialized variables and a dangling pointer to reused memory.
- **Roblox/Luau**: client and server disagree by 1 ulp (04). Its new prediction is state-corrected (§2).
- **s&box** ([hotload wiki](https://wiki.facepunch.com/sbox/Hotload)). C# hotload "within a few milliseconds" swaps
  types and migrates object state. Faster when only method bodies change. `[SkipHotload]`/`IHotloadManaged` for state
  that can be rebuilt.
- **Defold, Wicked Engine, sokol-based engines.** Small-team engines that stay alive by keeping scope tight. Nothing
  new for determinism.
- **Mach (Zig)** spent years on its own GPU layer (`mach-gpu` was deprecated, `sysgpu` folded into the main repo,
  [archive](https://github.com/hexops/mach-sysgpu)). Still no "simple 2D game" milestone as of v0.3. That's the
  cautionary tale behind "never write the renderer".
- **Ambient** (Rust, WASM, multiplayer-first) is "paused indefinitely", and the company pivoted to AI
  ([repo](https://github.com/AmbientRun/Ambient)). No postmortem. Visible gaps: client-side WASM was never finished,
  and Rust was the only guest language. Building a platform before a game stalls.
- **Hytale.** A C++ engine rewrite began in 2022 for console and cross-platform reach. After Riot cancelled the game
  (June 2025), the founders bought it back and reverted to the legacy engine, judging the rewrite at least 2 more
  years away ([Wikipedia](https://en.wikipedia.org/wiki/Hytale), *secondary on the reasons*).
- **Jai / Order of the Sinking Star** (Blow): undo by full world-state snapshots per move *(unverified)*. Same pattern
  as ours.

## 4. Deterministic physics in rollback games

| Game / system | Physics | Netcode | What to learn |
|---|---|---|---|
| **Rocket League** ([GDC 2018](https://www.gdcvault.com/play/1024972/)) | Modified Bullet at 120 Hz, a tiny world (cars + ball) | Server-authoritative. Clients predict everything and resimulate on correction *(talk, from memory)* | Owning the physics source mattered most. A small world makes full-world resim cheap |
| **Teardown MP** ([devblog 2026-03](https://blog.voxagon.se/2026/03/13/teardown-multiplayer.html)) | In-house voxels; destruction rewritten in fixed point | Hybrid: deterministic command stream for destruction, prioritized unreliable state sync for bodies; player-hosted | Late join = replaying the command buffer, capped (scene dumps are 30–50 MB). The multiplayer merge took months plus a year of weekly merges |
| **Rivals of Aether II** | Unreal | SnapNet server-authoritative rollback, no strict determinism ([news](https://finalweapon.net/2023/08/04/rivals-2-uses-snapnet-rollback-netcode-reveals-maypul/)) | Even a platform fighter shipped rollback without bitwise determinism |
| **Brawlhalla** | ? | Rollback, crossplay on every platform | No technical source found |
| **Roblox Server Authority** | In-house | Rollback + resim of predicted instances | Mispredictions cost client CPU and cause visible artefacts; Roblox says so |
| **Unreal Chaos** | Chaos | Resim / predictive interpolation | Resimulate only past a divergence threshold |
| **PurrNet** | PhysX | Save/restore rigidbody state, re-step, correct | Dedupe physics events across resims; only verified-tick events go to gameplay |
| **Box2D v3** ([determinism post](https://box2d.org/posts/2024/08/determinism/)) | Box2D | n/a | "There is no mechanism for rolling back this internal state". Its suggestion: don't predict what players won't notice (a falling building). Cross-platform CI canary: the step at which all bodies sleep, plus a transform hash |
| **Jolt** ([docs](https://jrouwe.github.io/JoltPhysics/)) | Jolt | n/a | `CROSS_PLATFORM_DETERMINISTIC` costs about 8%. The Samples app's "Check Determinism" rewinds and re-runs every step (a built-in sync-test). `SaveState` breaks if bodies were added or removed in the window, so reuse IDs (`CreateBodyWithID`) |
| **Kimbatt deterministic Unity Physics** | DOTS Physics on soft floats | n/a | A whole float physics engine *can* be mechanically ported to soft float. No perf numbers, 4 commits |

**The pattern:** nobody we found ships input-only, cross-architecture-deterministic, float rigid-body physics inside
rollback. Quantum does it with fixed point; Box3D and Jolt claim it in CI. That keeps physics determinism the project's biggest
risk, and it's why TL;DR #1 (heal by state) is the insurance.

## 5. AI-agent-first game development

- **Roblox Studio MCP playtest agent** (beta, 2026-04-09,
  [post](https://devforum.roblox.com/t/studio-beta-studio-assistant-mcp-playtest-agent/4566767)). A subagent on its
  own model and context, with Pass/Fail/Inconclusive/Error plus a report, and batched regression tests from a file.
  Known limits: false Passes, "limited observability", aborts after 50 turns *or several identical tool calls in a
  row*, and no real-time precision. Users report trouble with UI, navigation and the camera. Multiplayer tests are
  planned, not shipped. Take: put **loop detection** and **turn caps** in our harness, and make verdicts evidence-based.
- **Factorio Learning Environment** (NeurIPS 2025, [paper](https://arxiv.org/abs/2503.09617),
  [site](https://jackhopkins.github.io/factorio-learning-environment)). Agents write Python against 19 primitives in a
  persistent REPL namespace, with assertions to check results. v0.3 runs headless without the client for scale.
  Models were weak at spatial layout and error correction. Take: offer a **script endpoint** (a sequence of typed
  queries/inputs plus asserts in one call), not only one-shot RPCs.
- **VideoGameBench** ([paper](https://arxiv.org/abs/2505.18134)): best results 0.48% (real-time) and 1.6% (Lite,
  paused). Pausing helped only modestly, so pixel-driven play is hopeless today. Agents should drive through the
  control protocol with structured state and use screenshots only to verify visuals.
- **GBQA** ([paper](https://arxiv.org/abs/2604.02648)): 30 games, 124 seeded bugs. The best model (Claude 4.6 Opus,
  thinking) found 48%. **playtest-agent** ([repo](https://github.com/kevinnie2003/playtest-agent)) scores bug hunting
  by precision/recall against switchable seeded bugs. Take: seed bugs into the OctoEscape slice to measure our agent
  harness the same way.
- **forge** ([repo mirror](https://gh.r-mj.com/Ijtihed/forge); Rust/Bevy, 2 stars). "An engine where the LLM is the
  user." GUI/MCP parity (every editor click is the same JSON command), errors shaped as `{category, message, expected,
  got, fix}` ("errors are instructions"), and replayable JSONL session transcripts. Small, but the error shape is
  worth copying.
- **Other MCP engines and bridges** (renderoni, Mengine MCP, ai-game.dev, Summer Engine). A crowded 2025–26 field of
  bolt-ons ([glama listing](https://glama.ai/mcp/servers/elemarin/renderoni/related-servers)). None combines a
  deterministic sim with stepping and snapshots, which is our edge (08).
- **PurrDiction's scenario suite** (§1): multi-process headless runs with JSON results and simulated latency in CI.
  That's the non-AI half of agent-first testing, and it's what an agent's "run the co-op tests" should call.

## Things we should copy

1. **A desync policy ladder in the relay:** report → full-state resync (zstd block) → maybe per-table correct.
   Release builds default to resync, dev builds to report + dump (PurrNet).
2. **An input-redundancy window with a full-state cliff** (PurrNet: 32 ticks). It merges our planned redundant
   inputs and late join into one mechanism.
3. **Tick-salted, 64-bit hashes of verified ticks only**, so latency never causes false positives (PurrNet, Quantum).
4. **Typed mismatch reports** (MISSING / EXTRA / REORDER / DIFFERENT) per table, plus offline replay of the two
   peers' logs (snopek).
5. **A cold-vs-warm replay CI job** (bones, Riot).
6. **No mutable statics** in sim/net, enforced by lint, and N sessions per process from day one (Teardown, Fusion).
7. **Loop mode** on the timeline: snapshot at A plus an A→B input loop while tuning hot-reloads (Handmade Hero).
8. **Reverse step** in the agent API: restore the nearest snapshot and resim to T−1 (Tomorrow Corp).
9. **An op log** (object, field, old, new) for editor and agent edits, separate from sim state (The Machinery).
10. **A physics CI canary** à la Box2D (the step at which everything sleeps, plus a transform hash) next to the
    per-tick trace. **Jolt-style "check determinism"** (save, step, restore, step, compare) inside the physics seam.
11. **Physics events deduped by (tick, contact key)**, with gameplay consequences only from verified ticks (PurrNet,
    Quantum's synced events).
12. **Agent harness rules:** turn caps, identical-call loop detection, a script endpoint with asserts, pass only on
    sim-state evidence, and instructive errors (Roblox, FLE, forge).
13. **A layout hash in snapshot headers** to choose between state-keeping hot reload and restart + replay (Zylinski).
14. **Seeded-bug evaluation** of the agent harness on the slice (GBQA, playtest-agent).

## Pitfalls others hit

- **Trusting sync-test as proof** (bones). It only exercises rollback within one process.
- **Unsalted or narrow hashes**: PurrNet's 16-bit hash misses about 1 in 65k desyncs per check, and GGRS only catches
  what it checksums (08).
- **Pointer- or address-keyed ordering** that changes with the OS allocator (Riot), and **dangling pointers into
  reused memory** (Demigod).
- **Globals and singletons** blocking multi-instance testing (Teardown abandoned it; Fusion warns).
- **Soft float that isn't correctly rounded**: deterministic but incompatible with hardware floats, so one stray
  `float` desyncs. Fast trig approximations like Bhaskara (about 0.0016 error) leak into gameplay feel.
- **Physics restore that ignores structural changes** (Jolt `RestoreState`, Box2D internal state). Bodies created or
  destroyed inside the window need ID reuse or a world rebuild.
- **Firing gameplay effects from predicted physics callbacks** (PurrNet's multi-fire bug).
- **Late join that replays history.** It grows without bound, so Teardown caps it and disables JIP. A state transfer
  is the scalable answer, as in our plan.
- **Long-lived multiplayer branches**: Teardown's merge took about 3 months plus a year of weekly merges. Build
  netcode into the core from day one, which is unified's premise.
- **Engine rewrites mid-production** (Hytale) and **platform before game** (Ambient, Mach's GPU layer, The
  Machinery's shutdown).
- **Agent playtests that self-report Pass** (Roblox), and **pixel-only agents** (VideoGameBench).
- **Replays across builds** don't work (Factorio, VALORANT). Store the build hash in the replay and refuse a mismatch.

## Gaps and unverified items

- No source on Brawlhalla's or Rivals 2's physics internals, and no primary write-up of Rocket League beyond the GDC
  talk (the summary above is from memory of the talk).
- RyuJIT x64 ↔ ARM64 float equality: still no published result. Burst `FloatMode.Deterministic` cross-arch: still
  unproven.
- PurrNet `sfloat` performance and its rounding behaviour (as modified by Kimbatt): not measured here.
- Lightyear's deterministic mode topology (server-stamped vs P2P inputs): not checked in code.
