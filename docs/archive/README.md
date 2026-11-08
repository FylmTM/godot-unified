# Archive

Research, benchmarks and investigations for the stacks and options we **didn't choose** (the project is Odin + Godot +
Box3D), plus the results of finished phases. Kept for reference; nothing here is maintained, and code paths it mentions (`bench/`, `impl/cpp`,
`impl/rust`, `scripts/`, `deps/`) no longer exist (see git history, e.g. the commit before the archive move).
All dates are 2026-11-07/08 and all measurements are on an Apple M4 Pro.

| File | What it is · key conclusion |
|---|---|
| `PHASE2.md` | Phase 2 results for the chosen stack: verdict, numbers, problems found (Box3D fork gaps, Odin's XXH3 bug). The baseline for the core's benchmarks. |
| `PHASE2-comparison.md` | Phase 2: the same deterministic core + rollback netcode in C++, Odin, Rust. All pass T1–T9 on macOS, Linux x64, Windows x64. Odin fastest (0.62 ms rollback at 1000 enemies) and smallest (3.9k lines); builds 0.4 s. |
| `stacks/COMPARISON.md` | Even rubric comparison of Rust, Odin, Zig, C++, C#. Language-neutral; led to the benchmarks below. |
| `stacks/{cpp,csharp,rust,zig,odin}.md`, `TEMPLATE.md` | One research doc per language on the same rubric (ecosystem, determinism, bindings, tooling, agent fit); `TEMPLATE.md` is the rubric. |
| `research/00-synthesis.md` | Original all-Rust stack proposal (Bevy, Rapier, egui). Superseded; language-neutral findings live in `docs/research/`. |
| `research/03-host-renderer.md` | Host and renderer comparison (Bevy, Godot, others). Godot chosen. |
| `research/04-language-iteration.md` | Languages, compile times, hot reload. Odin chosen. |
| `research/06-ui.md` | UI options (assumed Bevy: egui, bevy_ui, ...). Superseded by Godot UI. |
| `research/07-animation-audio-vfx.md` | Animation, audio, VFX options (assumed Bevy). Superseded by Godot's. |
| `bench/a/` | Benchmark A: one sim core (300 Box3D bodies, 1000 agents) in 5 languages. All 11 binaries byte-identical on ARM64; build and tick-speed table. |
| `bench/x86/` | Benchmark A on x86-64 under Rosetta and Linux amd64: all 36 traces byte-identical to ARM64. |
| `bench/b/` | Benchmark B: four hosts (Bevy, Godot + C++/C#/Odin; Rust added later) on the same content. Godot builds in seconds; Bevy fresh dev build 2 min. |
| `bench/c/` | Benchmark C (`C1/C2-SPEC.md`): agent productivity, add a feature and fix a bug, 5 languages × 2 runs. All passed; costs within ~1.5× of each other. |
| `bench/s/` | Scale test: one game description emitted at 10k, 50k and 100k lines in 5 languages (`IR.md`, `PERF.md`): build and edit times at scale. |
| `bench/p/` | Physics rollback spike (`SPEC.md`): Box3D fork vs Jolt, both bit-exact; Box3D ≈ 1.0 / 4.2 ms per tick at 300 / 1000 bodies, Jolt 2.5 / 9.3. Box3D chosen. The fork patch is `third_party/box3d.patch`. |
| `bench/NET10.md` | C# .NET 8 vs .NET 10: determinism unchanged, small build differences. C# was dropped (~2.6× slower gameplay code). |
