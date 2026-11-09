# 08 · Agent tooling and in-game dev tools

How agents and the developer drive, test, inspect and look at a running unified game without an editor. Researched
2026-11-07, adapted 2026-11-08 for Odin and Godot (the `uni` CLI name is a placeholder: the `unified` CLI design is
pending sign-off). Claims I could not check against a primary source are marked *(unverified)*.

## TL;DR and recommendation

- **The game is the tool: one API, three front ends.** Tests call the core's `Session` API in-process. A dev-only
  **control server** in the game binary serves the same API as **JSON-RPC 2.0**, fronted by a `uni` CLI (what agents
  use from bash) and a `uni mcp` stdio adapter. Reflection-based remote protocols in other engines prove the shape;
  we add determinism, peers and replays.
- **Transport: a local socket per instance** at `<worktree>/.out/run/<instance>/control.sock`, so there are **no
  ports to allocate**. Large results (PNG, snapshots) go to an artifacts directory, and responses return paths.
- **A type registry is the prerequisite.** The inspector, diff viewer, protocol schemas, tuning sliders and F3
  summaries are all generated from it.
- **Every mutation goes through the simulation's input path** (debug commands stamped on a tick, like a debug
  teleport command). Edits and tuning changes are therefore recorded in the replay, and
  "agent poked it" never breaks determinism.
- **Tests:** a per-test setup that costs milliseconds, by cloning a cached "level loaded" snapshot; sync-test on by
  default; replays with build/content hashes (exact checksums within one build, outcome assertions across builds);
  seeded, shrinkable fuzzing; a checksum-trace diff across macOS ARM, Windows x64 and Linux in CI. Golden
  screenshots only on software rasterizers (WARP or lavapipe) with tolerances. Hosted macOS GPUs are not trustworthy.

## Lessons from the current Unity game's tooling

**Keep (these worked and should carry over almost verbatim):**

- **Harness verbs.** `Step`, `StepTo`, `StepUntil(cond, maxSeconds)`, `InputOf(slot)`, `SendCommand`,
  `FromSnapshot` and `FromReplay` are the right vocabulary. The protocol mirrors them one-to-one.
- **The F3 bundle.** A summary `feedback.md` (with ready-to-paste `teleport` and `view` lines), screenshot, log,
  frame dump, snapshot and replay, read cheapest first (`show`, then `entity`, then `grep`, then a headless repro).
  "Never read `frame.txt` whole" generalizes to: queries project fields and paginate.
- **Fuzz runner.** A fixed worker count with runs dealt round-robin, so a failure reproduces on every machine.
  A quick mode keeps every fourth run.
- **Test runner mechanics.** Shards balanced by last-run times; builds under a lock with runs from a private copy,
  so agents can test concurrently; fuzzes skipped when nothing they guard changed.
- **The smoke test.** `-smoke-test` exits 0 or 1, and a desync counts as a failure. Timings are a written budget.
- **Small probes.** A value traced every frame, a camera trace, and screenshots with and without the UI overlay.

**What Unity forced (design these away):**

- **One Editor, one stream.** Only one agent can touch the game at a time. In unified, every
  worktree runs its own binary.
- **The control channel is C# strings sent to `unity eval`** (no `using`, `f` suffixes, timeouts), and Unity's
  modal dialogs need an Accessibility-API dialog presser. Unified's API is typed, discoverable, and
  has no UI that can block it.
- **Input injection hacks.** `QueueStateEvent`, a `RunInBackground` settings swap, typed text that can't reach UI
  Toolkit. Unified injects input at the sim input layer, per player.
- **An asset DB export** (`db.json.gz` plus a stamp) just so tests can run without the Editor. Unified tests load
  the same sources the game does.
- **Global mutable state.** Harnesses on different maps corrupt each other's static collider indices, so tests need
  8 processes, and a pool of parsed asset copies. That costs ~3 s per harness and ~55 s for 307 tests. Unified
  worlds must be isolated values over immutable shared assets.
- **Replays drift silently** after code or DB changes. The camera isn't in the frame. Unified replays carry build,
  content and schema hashes, and F3 records the view state.
- **Polluted measurements.** Perf readings include the Editor's own windows (~18 ms of a 56 ms frame), and `ui`
  captures need a visible Game view.

## Prior art

What existing engine control protocols, test drivers and netcode tools teach, in our terms:

- **Reflection + schema export + discovery is the right core** (query, get, insert, mutate, remove, spawn, despawn,
  resources, trigger an event, `registry.schema`, `rpc.discover`, `+watch` streaming variants). What such protocols
  lack is ticks, pause, input, snapshots and peers: they inspect a live world rather than drive a deterministic sim.
- **A type guide is essential.** Agents fall back to trial and error without type info. App-defined curated tools
  ("presets": curated properties and functions) beat raw reflection for common tasks; offer both.
- **Godot's remote debugger** routes `prefix:`-tagged messages to registered "captures"; its scene tree and inspector
  are built on it (`request_scene_tree`, `inspect_object`, `set_object_property`)
  ([remote_debugger.h](https://cocalc.com/github/godotengine/godot/blob/master/core/debugger/remote_debugger.h)).
  Extensible namespaced routing is the idea to keep. Community bolt-on bridges (an autoload on a UDP or WebSocket
  port) show demand, and fragility.
- **Official editor-bound MCP integrations still mean one Editor at a time**, with client approval and cloud
  sign-up on top.
- **Browser-test-style game drivers** (an in-game SDK on a WebSocket, drivers in several languages, XPath-like hierarchy
  queries, a REPL and a recorder): a query language over the world is valuable. Ours is component filters, not a
  scene path.
- **Deterministic netcode tooling:** a checksum every N ticks (off in release) and a costly cross-platform checksum
  mode for debugging; on a desync, every client's frame is collected and a differ compares them, with a GUI that
  works in builds, not only in the editor. That's exactly what we want built in. Sync-test (advance one frame, roll
  back ≥ 2, re-simulate, compare) only catches drift in state that is checksummed; our whole-block hash removes the
  "forgot to checksum it" hole. A cheap CRC every tick, desync reports carrying both states, and a debug mode with
  human-readable tags to localize where divergence starts mean we need per-system checksums in debug mode. Replays
  are per-build.
- **Net sim tooling:** thin clients with fake input; RTT delay, jitter, loss, presets (4G, broadband), packet fuzz,
  command-line init, dev builds only. That's the blueprint for the net sim panel and bots.
- **Profilers:** Tracy (headless `tracy-capture -o f -s secs`, `tracy-csvexport`, `ondemand` mode; turn off LAN
  broadcast; pin versions together): `perf.capture` wraps it and returns CSV. RenderDoc (in-app capture triggers; the
  Python replay module must be built from source): `gpu.capture` when loaded, analysis stays manual.

MCP itself ([2025-11-25 transports](https://modelcontextprotocol.info/specification/2025-11-25/basic/transports/))
has two standard transports. **stdio** means the client spawns the server. **Streamable HTTP** must validate `Origin`
against DNS rebinding. A 2026-07-28 revision reportedly drops the session header
([glossary](https://zuplo.com/learn/mcp/glossary/transport), *unverified*). That churn is a reason to keep MCP in a thin
adapter, not in the game.

## Control protocol design

**Layering.** The core's `Session` API is the one tests use. The control server
(feature `dev-tools`) is JSON-RPC 2.0 framed as newline-delimited JSON. Two clients sit on top: `uni` (CLI: `uni
query`, `uni step`, `uni shot`, …) and `uni mcp` (a stdio MCP server that discovers or launches instances and maps
~15 coarse tools onto RPC methods). The CLI is the primary agent interface. It costs no tool-schema context, it
composes with `jq`, and bash-driven agents already do well with that shape in the current Unity game.

**Transport.** The default is a Unix socket (mode 0600); Windows has supported AF_UNIX since Windows 10 1803 *(well
known; untested here)*. `--control tcp` binds `127.0.0.1:0` and writes the port and a token to `control.json`;
`--control stdio` serves a parent harness. WebSocket comes only for a browser dashboard, with an Origin check.
`control.json` holds `{pid, protocol, build, content_hash, peers}`, and `uni ls` globs the run dirs.

**Addressing.** An instance runs one session with N **peers** (host plus clients, each with its own world copy and
an optional view), connected by a transport (loopback with netsim by default). Calls take `peer` (default `0`) and
`frame`: `"verified"`, `"predicted"` or a tick number within the snapshot ring.

**Core methods** (with `rpc.discover` and `registry.schema` for discovery):

| Area | Methods |
|---|---|
| Session | `session.start {level, peers, transport, netsim, seed, headless}`, `session.info`, `session.quit` |
| Clock | `clock.pause`, `clock.resume`, `clock.step {ticks}`, `clock.step_until {query, timeout_ticks}`, `clock.speed {scale}` |
| World | `world.query {with, without, fields, where, limit, cursor}`, `world.get {entity, components}`, `world.find {name}`, `world.raycast` (read-only) |
| Edit | `world.edit {entity, component, path, value}`, `world.spawn {prototype, at}`, `world.despawn`. Each becomes a debug command on the next tick, recorded in the replay |
| Input | `input.set {peer, player, input}` (held), `input.press {…, ticks}`, `input.script {peer, frames:[…]}` |
| Peers/bots | `peer.add {kind: "bot", policy}`, `peer.drop`, `peer.reconnect` (later) |
| State | `snapshot.save {path?}`, `snapshot.load`, `snapshot.diff {a, b}`, `timeline.seek {tick}`, `timeline.branch` |
| Replay | `replay.save`, `replay.run {path, until, verify}` → first divergent tick |
| Look | `view.camera {peer, pose \| follow}`, `view.shot {peer, ui: bool, size, camera?}`, `gpu.capture` |
| Observe | `log.read {since, level}`, `events.subscribe {kinds}` (notifications), `world.watch {query}`, `perf.stats`, `perf.capture {secs}` |
| Net | `net.sim {peer, latency_ms, jitter_ms, loss, dup, reorder}`, `net.stats` |
| Config | `config.get`, `config.set {asset, path, value}` (deterministic, via input), `config.save` (format-preserving write-back) |
| Scenario | `scenario.run {path}`: a JSONL file of the same calls plus `expect` lines |

**Example messages.**

```jsonc
→ {"jsonrpc":"2.0","id":1,"method":"session.start","params":{"level":"lab/hub_brain","peers":2,"transport":"loopback","netsim":{"latency_ms":60,"jitter_ms":10,"loss":0.01},"headless":false}}
← {"jsonrpc":"2.0","id":1,"result":{"session":"s1","tick":0,"peers":[{"id":0,"role":"host"},{"id":1,"role":"client"}]}}

→ {"jsonrpc":"2.0","id":2,"method":"world.query","params":{"peer":1,"frame":"predicted","with":["Player","Transform"],"fields":["Transform.pos","Player.mode"],"limit":20}}
← {"jsonrpc":"2.0","id":2,"result":{"tick":431,"rows":[{"e":"E.206.1","Transform.pos":[3.2,0.0,-1.5],"Player.mode":"Crawl"}],"cursor":null}}

→ {"jsonrpc":"2.0","id":3,"method":"world.edit","params":{"entity":"E.206.1","component":"Transform","path":"pos","value":[0,2,0]}}
← {"jsonrpc":"2.0","id":3,"result":{"applied_at_tick":432,"recorded":true}}

→ {"jsonrpc":"2.0","id":4,"method":"input.press","params":{"peer":1,"player":1,"input":{"buttons":["Jump"]},"ticks":6}}
→ {"jsonrpc":"2.0","id":5,"method":"clock.step_until","params":{"query":{"entity":"E.206.1","where":"Player.grounded == false"},"timeout_ticks":30}}
← {"jsonrpc":"2.0","id":5,"result":{"met":true,"tick":437}}

→ {"jsonrpc":"2.0","id":6,"method":"view.shot","params":{"peer":1,"ui":false,"size":[1280,720]}}
← {"jsonrpc":"2.0","id":6,"result":{"path":".out/run/a1f3/artifacts/shot-0006.png","tick":437,"camera":{"pos":[1,4,-6],"yaw":12,"pitch":20}}}

← {"jsonrpc":"2.0","method":"events","params":{"tick":438,"peer":0,"kind":"Landed","data":{"e":"E.206.1"}}}
```

Errors carry suggestions (`{"kind":"unknown_field","did_you_mean":["Transform.position"]}`).

**Context economy.** Responses are field projections, paginated and capped (default `limit` 50, with a truncation
note). `world.summary {near, radius}` renders F3-style text: 40 lines instead of a dump.

**Security.** The server exists only with the `dev-tools` feature, and release CI asserts its symbols are absent.
The socket is user-only, and TCP is loopback-only with a token. Scenarios are data, not code.

**N clients in one process.** The session owns its peers, each with a world, input queue, rollback buffer and
optional view. The renderer shows one peer or tiles 2–4. `view.shot` renders any peer offscreen, with no visible
window needed. A separate-process client (real UDP or Steam) has its own socket, addressed by instance id.

## Test harness design

- **Cheap worlds.** Assets are parsed once per process into immutable shared data, and each level is cached as a
  **"level loaded" snapshot**, so a test starts with a memcpy: well under 10 ms of setup, against ~3 s in
  the current Unity game. With no globals, tests run on threads in one process.
- **Sync-test by default.** Each test tick also rolls back `k` frames (k ≈ rollback window, e.g. 8) and re-simulates,
  comparing whole-block hashes. CI runs it on everything; a local `--fast` turns it off. A mismatch dumps both
  blocks, gives a registry-aware diff, and reruns with per-system hashing to name the first system that diverged.
  Also a serialize→deserialize→hash round-trip, which catches state living outside the block. **Requirement:** padding bytes in the block are zeroed, or hashes are noise.
- **Replays as regression tests.** Header: format version, git sha plus dirty flag, sim schema hash, content hash of
  sim-relevant assets, seed, peers, configs. Body: per-tick inputs, a checksum every tick (cheap: one hash), and
  keyframe snapshots every N seconds. **Same hashes → exact:** every checksum must match. **Different build →
  scenario:** the replay runs with attached outcome assertions (`expect` lines: "reaches door D by tick 1800", "never
  below floor"). When outcomes still hold, `uni replay bless` re-records the checksums. `uni feedback promote <id>`
  turns an F3 entry into such a test (the manual "copy the numbers into a test" step, automated).
- **Fuzzing.** Seeded input generators (random walk, action-biased, macro grammar) and invariants as functions over
  the world (bounds, no NaN, entity caps). Runs are dealt deterministically, as above. A failure is just an
  input sequence, so **delta-debug shrinking** is cheap. Coverage-guided fuzzing over input bytes can come later.
- **Cross-platform checksum CI.** A matrix of `macos-15` (arm64), `windows-latest` (x64) and `ubuntu-latest` (x64,
  the Steam Deck proxy). Each runs the replay corpus headless and uploads `trace.tsv` (`replay, tick, hash`) as an
  artifact. An aggregator job diffs the traces. On divergence, it reruns that replay on both OSes with a
  per-component hash dump at the first bad tick and posts the diff. No GPU is needed.
- **Golden screenshots.** Hosted macOS runners have an "Apple Paravirtual" GPU, with MPS officially unsupported
  ([runner docs](https://docs.github.com/ru/actions/reference/github-hosted-runners-reference)). Reported problems
  include wrong WebGPU results ([report](https://github.com/cloudflare/workerd/pull/1569)) and GPU hangs on
  macos-14, with macos-15 reportedly fine ([report](https://github.com/bernardladenthin/java-llama.cpp/pull/14)).
  Software rasterizers do work in other projects' CI: WARP (D3D12) and llvmpipe/lavapipe (GL/Vulkan)
  ([example](https://github.com/gfx-rs/wgpu), *seen via forks; check upstream*). Plan: goldens on Linux lavapipe or
  Windows WARP, rendered from a snapshot with fixed time and temporal effects off, compared with a threshold diff
  plus a bless page. Mac visuals are checked locally or on a self-hosted nightly. They cover UI layout, "not black",
  and material regressions. Art judgement stays with agents looking at `view.shot`.

## Dev tools and what they need from the core

**The type registry (core requirement).** A derive or codegen gives every component, resource, event, input and
config type a descriptor: stable name and id, fields (name, type, offset, size), `#[entity_ref]` markers,
range/step/unit/`tunable` attributes, docs, an ownership flag (sim, derived, view-only), enum variant names, and a
schema hash per type and for the whole sim.

Entity handles print stably (`E.206.1`, index plus generation). A `Name` or tag component is optional. The registry
exports JSON Schema for `registry.schema` and for MCP tool input schemas.

| Tool | Requirements on the core |
|---|---|
| Inspector / picker | Registry; an entity→render-instance map in the view; read-only sim raycast; generic drawers with overrides |
| Timeline scrub and branching | A snapshot ring (every tick for ~2 s of rollback, plus keyframes every 1 s for the session) and an input log. Seek = load the keyframe and re-simulate (needs headless sim ≥10× realtime). Branch = load, truncate the input log, continue live under a new replay branch id. **Physics engine state must live in, or round-trip through, the block** |
| Desync diff viewer | Two blocks → per-entity, per-field diff via the registry. Per-system hashes in debug mode. Peers' dumps collected over the transport |
| Net sim panel | Per-peer latency, jitter, loss, duplication, reorder and bandwidth in the transport layer. Graphs of input delay, rollback count and depth, and resim cost |
| Tuning sliders | Config assets in text with range metadata. Slider → `config.set` stamped on a tick (replays stay valid). `config.save` writes back format-preserving. A file watcher applies disk edits through the same path |
| F3 feedback | Screenshots with and without UI, snapshot, replay (from start, or the last keyframe plus inputs), **view state** (camera, selected peer, UI screen), log ring, perf stats, build/content hashes, note, registry-generated `feedback.md`. `uni feedback list/show/entity/grep/check/promote/done` |
| Free cam | View-only camera detached from the sim. Its pose is exposed so `view.shot {camera}` reproduces a frame |
| Perf overlay | Per-system timing in the scheduler (plus Tracy zones), rollback/resim counters, entities, memory, net stats; same data via `perf.stats` |
| Logs / events | Structured logs into a ring buffer. Sim events tagged with tick and peer, streamable as notifications |

## Parallel agent workflow

- **Self-contained worktrees.** Each builds and runs its own binary; only caches are shared.
- **No port allocation.** Control sockets live under `<worktree>/.out/run/<id>/`. Network tests bind port 0 and
  publish the port in `control.json`. No fixed ports.
- **Build caches.** Use per-worktree build outputs (Odin builds are sub-second), and "build under lock, run from a
  private copy" for test runners.
- **Content caches.** Processed glTF, shaders and level snapshots go in a content-addressed `~/.cache/unified/`.
  Worktrees already share LFS objects through the common git dir.
- **Machine-wide slots.** A lock-file semaphore caps heavy jobs (GPU windows, fuzzes, Blender), like the Blender
  slots in the current Unity game. Instances are headless by default.
- **Artifacts.** `.out/run/<id>/artifacts/`, gitignored, with paths printed in every result and old runs pruned.

## Risks and unknowns

1. **Reflection in Odin.** The type registry can come from Odin's runtime type info or generated layout
   descriptors; settle in the module spec.
2. **Physics state inside snapshots.** Scrub, sync-test and replays assume the physics engine's internal state is
   in the block, or round-trips deterministically. This was the riskiest dependency; the Box3D fork's world
   save/restore has since proved bit-exact under rollback and across ARM64/x64 (phase 1).
3. **Snapshot memory.** The block size of a 1000-entity physics world is unknown. The keyframe interval trades
   memory against seek time.
4. **Goldens on CI.** Hosted macOS GPU behaviour is anecdotal. Software rasterizers may diverge from real GPUs
   enough to make goldens low-value.
5. **MCP churn and context.** Agents over-query. Use a thin adapter, a CLI first, and projections, limits and
   summaries as defaults.
6. **View timing.** Screenshots of predicted frames depend on timing, so test mode renders a given verified tick.

## Spike proposal

Build a toy: a POD block with 3 component types and 1000 entities, a layout-descriptor registry, a loopback session with 2
peers and netsim, the control server on a UDS, the `uni` CLI, `uni mcp`, and an offscreen screenshot via the chosen
renderer.

**Pass if all hold:**

1. A fresh agent with only `uni --help` completes, in ≤15 tool calls and with no docs: start a 2-peer session, find
   entities by component filter, edit a field, step until a condition holds, take a screenshot with and without UI,
   and read an event.
2. `world.query` over 1000 entities with 2 fields returns in under 20 ms round trip. `clock.step 600` headless runs
   in under 100 ms.
3. Per-test setup from the cached level snapshot is under 5 ms. 1000 tiny tests finish in under 10 s on an M-series
   Mac.
4. 10 instances in 10 worktrees run concurrently with zero configuration and no collisions.
5. A replay recorded through the protocol, including edits and a `config.set`, reproduces identical per-tick
   checksums locally, and the trace is identical on GitHub `macos-15` and `windows-latest`.
6. Sync-test (k=8) catches a planted non-determinism (unordered iteration) and names the system.
7. The release binary contains no control-server symbols and opens no socket.
8. A headless screenshot works locally on macOS without a window and in CI on Ubuntu with lavapipe. Record (not
   gate) whether `macos-15` hosted produces a correct image.

**Fail signals:** a typed edit needs more than 2 attempts on average (the schema is too weak); setup costs more than
50 ms (state isn't truly a value); cross-OS traces differ on the toy (the determinism plan is broken before physics
is even added).
