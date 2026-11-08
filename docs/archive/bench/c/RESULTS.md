# Benchmark C: agent productivity (2026-11-08)

Same model, same prompt per task, five languages, two runs each. Each run worked in an isolated copy of its
language's Benchmark A codebase, with every build logged by a wrapper. The final state was re-checked by me with the
final checker. Agent usage (tokens, tool calls, wall time) comes from the task notifications.

## C1: add a feature ("grab and throw", `C1-SPEC.md`)

The feature: players grab the nearest prop within 3 m, carry it kinematically above their head, and throw it on
release. Swarm agents flee carried props. It touches state, the hash, new Box3D calls (so bindings must be extended),
and a scripted-scenario CLI. 18 automated checks.

| Run | Final checker | Tokens | Tool calls | Wall time | Builds | Failed builds | Lines +/− |
|---|---|---|---|---|---|---|---|
| rust-r1 | 18/18 | 167k | 37 | 11.5 min | 13 | 0 | +437 / −46 |
| rust-r2 | 18/18 | 225k | 59 | 18.0 min | 23 | 1 | +385 / −49 |
| odin-r1 | 18/18 | 157k | 37 | 12.4 min | 22 | 0 | +329 / −39 |
| odin-r2 | 18/18 | 149k | 35 | 10.0 min | 17 | 0 | +322 / −46 |
| zig-r1 | 18/18 | 140k | 29 | 10.3 min | 13 | 0 | +312 / −43 |
| zig-r2 ⚠ | 18/18 | 178k | 50 | 16.6 min | 35 | 2 | +327 / −47 |
| cpp-r1 | 18/18 | 188k | 49 | 14.2 min | 22 | 1 | +344 / −60 |
| cpp-r2 | 18/18 | 210k | 60 | 16.8 min | 20 | 0 | +364 / −71 |
| csharp-r1 ⚠ | 18/18 | 202k | 68 | 28.0 min | 17 | 2 | +342 / −63 |
| csharp-r2 ⚠ | 18/18 | 217k | 65 | 31.5 min | 19 | 4 | +341 / −64 |

| Language mean | Tokens | Tool calls | Wall time | Failed builds |
|---|---|---|---|---|
| Odin | 153k | 36 | 11.2 min | 0 |
| Zig | 159k | 40 | 13.5 min | 1 |
| Rust | 196k | 48 | 14.8 min | 0.5 |
| C++ | 199k | 55 | 15.5 min | 0.5 |
| C# | 210k | 67 | 29.8 min | 3 |

Confounds, which matter more than the differences above:
- **A fragile check in my harness.** Two physics-chaotic checks ("throw ≥ 8 m/s for 3 ticks", "lands below 1.2 m")
  were relaxed mid-run. Runs that hit them first spent many attempts on them: Rust r2, C++ r2 and Zig r2 report 9–15
  carry variants tried. Odin r2 and Zig r1 finished early; most of the rest were affected. That alone explains the
  ±30% token spread.
- **A harness bug against C#.** The build-logging wrapper hung with .NET's build servers. C# r1 debugged and patched
  it; C# r2 got the fix by message. Both C# runs' times are inflated by it.
- **A shared scratch folder.** Zig r2 briefly copied another agent's Odin code from a shared temp file, then deleted
  it and rewrote its own (disclosed). C++ r1 read another run's numbers once. C2 used per-run temp folders.
- **Ten agents ran at once**, so wall times include CPU contention. n = 2 per language.

**What C1 shows:** every language reached 18/18 on both runs, with very few failed builds (0–4). The expected
fluency penalty for Odin and Zig didn't appear: with an existing codebase to imitate, agents wrote correct idiomatic
code just as cheaply (Odin and Zig were actually the cheapest). C++ and Zig needed no binding work; Rust, Odin and C#
extended their hand-written bindings without trouble. The variation within a language (e.g. Rust 167k vs 225k) is
as large as the variation between languages.

## C2: find and fix three planted bugs (`C2-SPEC.md`)

Three identical logical bugs were planted in each language:
1. a float-order "simplification" in the swarm blend
2. `blocked` reset on ticks without a ray
3. an edge off-by-one: the grid clamp is 0..50 and agents are clamped to ±50, which reads and writes past the grid
   arrays after tick ~4256

| Run | Final checker | Tokens | Tool calls | Wall time | Builds | Found all bug sites |
|---|---|---|---|---|---|---|
| rust-r1 / r2 | 9/9, 9/9 | 82k / 95k | 9 / 13 | 2.5 / 2.9 min | 5 / 5 | yes / yes |
| odin-r1 / r2 | 9/9, 9/9 | 86k / 93k | 10 / 13 | 3.0 / 3.4 min | 5 / 5 | yes / yes |
| zig-r1 / r2 | 9/9, 9/9 | 88k / 83k | 11 / 11 | 3.2 / 2.9 min | 6 / 6 | yes / yes |
| cpp-r1 / r2 | 9/9, 9/9 | 82k / 81k | 8 / 9 | 2.1 / 2.3 min | 5 / 5 | yes / yes |
| csharp-r1 / r2 | 9/9, 9/9 | 93k / 89k | 11 / 9 | 2.8 / 2.7 min | 6 / 5 | yes / yes |

Every run found all four buggy lines (the off-by-one is two lines) by reading the code against the spec, not by
running it. The bugs were too easy to locate (all in one file, next to the spec's exact formulas), so **C2 doesn't
discriminate between languages.** A harder bug hunt would need bugs that only show up at runtime.

**The safety data point is from planting the bugs, not from the hunts.** When bug 3 fires (tick 4256):

| | Dev | Release |
|---|---|---|
| Rust | panic: "index out of bounds: the len is 2500 but the index is 2538" | same |
| Odin | bounds-check trap | same |
| C# | `IndexOutOfRangeException` | same |
| Zig | index-out-of-bounds panic with stack trace | **SIGBUS, no message** |
| C++ | **silent memory corruption, exit 0, wrong hash** | **same** |

In a deterministic rollback engine, silent corruption shows up as a desync far away from its cause. That's the
memory-safety risk the stack comparison flagged for C++ (and Zig release). Sync-test and checksums would catch the
symptom, but not point at the cause. ASan/UBSan dev builds would, at a runtime cost; that wasn't tested here.
