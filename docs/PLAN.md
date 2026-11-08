# unified: order of work

Agreed 2026-11-08. Phases run **in sequence**. After each phase: report, give a recommendation, and ask the
developer before starting the next one.

## Decided so far

- **Host:** Godot (4.7.x) via **GDExtension**. LibGodot only if GDExtension blocks something concrete. The workflow
  follows Godot's grain: assets imported in the editor and visible there, `.tscn` scenes per entity kind, materials
  set up in the editor, GDScript allowed in the view layer (e.g. UI tweens). The extension runs the sim and maps sim
  entities to scenes.
- **Sim:** a host-independent core (pointer-free state block, fixed tick, input, snapshot ring, checksums, sync-test,
  replay). Headless runner and tests never need Godot.
- **Languages still in the race:** C++, Odin, C#, Rust. All four get the same prototype, so the choice is made on
  the developer's own experience of each.
- **Physics:** one engine used through its C API in all four languages, so the comparison stays about languages.
  Box3D is preferred if it can be made to save and restore; Jolt is the fallback.
- **Deferred:** Windows determinism (no Windows machine yet; come back to it), hosted CI.

## Phases

1. **Physics rollback spike** (`bench/p/`), C/C++ only. A Box3D fork exposing world save/restore, raced against
   Jolt's state recorder (`SaveState`/`RestoreState`). Pass criteria:
   - sync-test (restore 8 ticks back every tick, re-simulate, compare hashes) is bit-identical
   - spawns and despawns inside the rollback window work
   - x86-64 traces under Rosetta match ARM64
   - the cost of save + restore + 8-frame re-simulation at 300 bodies is acceptable (target ≤ 6 ms/tick); 1000
     bodies measured for scaling
   - snapshot size is reported

   Output: one engine choice for all prototypes. **→ report and ask.**
   - **Done 2026-11-08** (`bench/p/RESULTS.md`). Both engines are bit-exact under sync-test with churn and on x86-64
     under Rosetta. Rollback cost: Box3D ≈ 1.0 / 4.2 ms per tick at 300 / 1000 bodies; Jolt ≈ 2.5 / 9.3 ms.
     Quantum 3.1 baseline (stateful PGS, warm-start cache in the frame): also bit-exact, ≈ 4.4 / 21 ms per tick
     single-threaded. Recommended: the Box3D fork. Awaiting the developer's decision.
2. **Core prototype: sim + netcode, headless (re-scoped 2026-11-08).** The language choice is driven by the core, so
   derisk it before any Godot work.
   - **Languages: C++, Odin, Rust**, each with the full core. C# was dropped: ~2.6× slower gameplay code even on .NET 10
     AOT, which rollback multiplies. Zig was dropped earlier.
   - **Sim:**
     - state block, fixed tick, systems
     - snapshot ring: our state plus the Box3D fork's physics snapshot
     - checksums, sync-test
     - the input log as the replay
   - **Netcode:**
     - Quantum-style relay on the host
     - prediction and rollback, adaptive input delay, time sync, timeouts for missing inputs
     - late join from a snapshot plus the input tail
     - transports: loopback with a network simulator, and UDP (Steam later)
   - **Test game:** a headless survivor-lite with 1000+ enemies, projectiles, physics crates and explosions.
   - **Proof:**
     - N clients in one process under a bad simulated network, with no desync
     - UDP between processes
     - official input logs replayed bit-identically on every platform
     - a snapshot saved on one platform and restored on another
   - **CI:** GitHub Actions on Linux x64 and Windows x64 only. macOS is checked locally. Iterate locally first; CI is
     the final check. **→ report and ask.**
3. **Godot integration (was phase 2/3):** extension vs LibGodot, the shared Godot project, and the survivor game with
   a view layer in the remaining languages.

   *(The original phase 2 text follows, kept for the Godot phase.)* The survivor game spec:
   - top-down arena, 1–4 players, auto-attack projectiles
   - enemy waves up to 1000+ (spatial grid, physics queries)
   - crates and barrels as rigid bodies, explosions
   - XP gems, a level-up choice through input
   - HP and XP bars with GDScript tweens

   Also: the core harness design (one document for all languages), the shared Godot project (scenes, materials,
   imported glTF, UI), the extension interface, and the agent CLI. **→ report and ask.**
3. **Four prototypes in parallel:** C++ (godot-cpp), Odin (own bindings generated from Godot's API JSON), C#
   (Godot .NET), Rust (godot-rust, with own generated bindings as the fallback). Same spec, same Godot project.
   **→ report and ask.**
4. **Evaluation:**
   - The developer opens the Godot project, plays each prototype, and judges the dev experience: editor workflow,
     extension reload, debugging.
   - Measured: builds (fresh worktree including Godot's import cache, edits), rollback cost at 1000 enemies,
     runtime, lines of code, and agent cost per feature.
   - Output: the language decision. **→ report and ask.**
5. **Then:** the engine skeleton for real, plus the OctoEscape slice.

## Evidence so far

`docs/research/` (research, `stacks/COMPARISON.md`), `bench/a` (sim core in 5 languages), `bench/x86` (x86-64
determinism), `bench/b` (hosts), `bench/s` (100k-line scale), `bench/c` (agent productivity), `bench/NET10.md`.
