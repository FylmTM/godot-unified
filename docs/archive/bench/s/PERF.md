# bench/s runtime performance: language/compiler vs emitter

Question: at 100k the release tick ranged from 596 µs (Rust) to 3622 µs (C#). How much of that is the
language/compiler, and how much is how each emitter happened to write the code?

**Short answer.**
- **Most of the gap came from the per-tick hash path**: serializing the 1.2 MB G_buffer field by field, then
  XXH3 over it. Four of the five emitters wrote the serializer in a way their compiler can't optimise, and Zig's and
  Odin's standard-library XXH3 is slow on arm64.
- **The gameplay systems themselves cost about the same in all four LLVM languages** (~160–210 µs at 100k).
- **C# is the one real language/compiler gap.** RyuJIT (.NET 8) runs the gameplay systems about 4.5× slower. On
  top of that, a cold 1000-tick JIT run carries ~1.9 s of JIT time.
- **With idiomatic fixes, Rust, C++, Zig and Odin end within 10% of each other** (471–523 µs at 100k). C#
  NativeAOT ends at 1294 µs.

Machine: Apple M4 Pro, macOS 26.7. Toolchains as in `bench/a/RESULTS.md` (Rust 1.98.1, Odin dev-2026-11,
Zig 0.17.1, Apple clang 21, .NET SDK 8.0.133). Every number is the median of 3 runs of
`out/release/bench-a --ticks 1000` (`us_per_tick_mean`), measured one at a time with nothing else running.
**Every modified build gives the reference final hash** (10k `13fa2f2fa03c1545`, 50k `101223b3b9da4d0a`,
100k `ffd51a023b4e2041`). The originals and the emitters are untouched. All changes are in
`bench/s/perf/<lang>/p{10k,50k,100k}`.

## Corrected table: best idiomatic µs/tick

| | 10k | 50k | 100k | was (100k) | what changed |
|---|---|---|---|---|---|
| Rust | 239 | 349 | **475** | 596 | local writer copy, ThinLTO, unchecked hash-buffer stores (safe-only: 529) |
| C++ | 236 | 353 | **471** | 780 | local writer copy (char aliasing), ThinLTO |
| Zig | 228 | 336 | **477** | 1728 | C `xxhash.h` instead of `std.hash.XxHash3`, local writer copy |
| Odin | 242 | 363 | **523** | 1174 | single-store `put_u32` + local writer copy, C `xxhash.h` instead of `core:hash/xxhash` |
| C# NativeAOT | 316 | 631 | **1294** | 3622 (JIT, cold) | per-row span serialization, NativeAOT |
| C# JIT, 1000 ticks (cold) | 525 | 1595 | 3221 | 3622 | per-row span serialization only |
| C# JIT, steady state | – | – | ~1210–1300 | ~1325–1430 | (warm second run / ticks 2000–10000) |

Benchmark A alone (physics + swarm, no gameplay) is ~300 µs in every language. So the gameplay part at 100k is
now roughly 170–225 µs for the four native languages and ~1000 µs for C#.

## Where the 100k tick goes (µs/tick, before → after)

Sources:
- **Native languages:** `sample` profiles of the release binaries over 3–4 whole 1000-tick runs, with each
  phase's share multiplied by the measured mean.
- **C#:** Stopwatch phase timers added to the perf copy (`BENCH_PHASES=1`). `BENCH_WARMUP=1` first runs one
  full untimed simulation, which gives the steady-state JIT numbers.

| Phase | Rust | C++ | Zig | Odin | C# (JIT warm) |
|---|---|---|---|---|---|
| gameplay systems (step 7b) | 209 → 171 | 211 → ~160 | ~185 → 171 | 195 → 172 | 774 → 766–790 |
| G_buffer serialization | 93 → 43 | 290 → 46 | 352 → 54 | ~665 → 81 | 253 → 124 |
| XXH3 over 1.2 MB | 28 → 26 | 30 → 21 | **922** → 21 | 83 → 31 | 36 → 35 |
| ring copy (memcpy 1.2 MB) | 14 → 16 | 17 → 18 | 14 → 16 | 12 → 13 | 23 → 23 |
| swarm + physics (Benchmark A) | ~250 | ~250 | ~210 | ~230 | ~240 |

(Zig and Odin inline the whole sim into `main`, so their swarm figure is `main`'s self time.)

The hash path (serialization + XXH3 + ring copy) went from 135 / 337 / 1288 / 760 / 312 µs to
85 / 85 / 91 / 125 / 188 µs (Rust / C++ / Zig / Odin / C#). Hashing a 1.2 MB state every tick costs about
85 µs even when done well. That cost is set by the benchmark's design, not by any language.

---

## Rust (596 → 475)

**1. `&mut HashWriter` reloads `buf`/`at` around every field (emitter choice / LLVM aliasing limit): 596 → 551.**
`write_hash(&self, w: &mut HashWriter)` writes through `w.buf: &mut [u8]`. Rust only marks function
*arguments* `noalias`, not a `&mut [u8]` loaded out of a struct. So LLVM must assume a byte store can overwrite
`*w` itself. Every field pays for it (`throwing::State::write_hash`, original):
```
ldr  x12, [x1]          ; reload w.buf.ptr
str  w11, [x12, x9]     ; the field
str  x10, [x1, #0x10]   ; store w.at
ldr  x2,  [x1, #0x8]    ; reload w.buf.len
cmn  x10, #0x5 ; b.hi   ; overflow check of at+4
cmp  x9, x2   ; b.hi    ; end <= len
```
Fix: each `write_hash` takes a local reborrow, `let mut lw = out.local(); let w = &mut lw; …;
out.set_position(lw.position())`. Script: `perf/scripts/rust_writer.py`.

**2. Cross-crate helpers aren't inlined (build-config choice): 551 → 529.** The README notes that
`actor::smooth01`, `lerp`, `approach`, `falloff` and `carry::remap_heat` aren't `#[inline]`. In the profile
they are separate functions taking ~4% (`score_slot` alone makes 24 `bl` calls to them). Fix:
`lto = "thin"` in `[profile.release]`. That builds in 14 s at 100k (vs 11 s without).
`lto = "fat"` with `codegen-units = 1` was killed after **25+ CPU-minutes**, so it isn't practical at this size.

**3. Two bounds checks per serialized field: 529 → 475.** Even with registers, every `put` is ~9 instructions
(two compare-and-branch checks plus address arithmetic) against ~4 for C++. Fix: one `get_unchecked_mut` in
`HashWriter::put`, behind a `debug_assert!` (the buffer is exactly `HASH_BYTES`, asserted after
serialization). This is `unsafe` in one core helper. A safe alternative is per-row fixed-size chunks
(`&mut [u8; ROW_BYTES]` with constant offsets), which would need an emitter change. It wasn't tried here.

**Language/compiler share:** none that matters. The gameplay systems cost 171 µs, the same as C++/Zig/Odin.
Bounds checks on table indexing in the systems stay on (safe Rust) and don't show up as a measurable cost.

## C++ (780 → 471)

**1. `ByteWriter&` + `unsigned char` stores = aliasing (emitter choice): 780 → 516.** `put_u32` does
`memcpy(p, &v, 4); p += 4;` on the member `p`, and `serialize(const State&, ByteWriter& out)` takes the
writer by reference. A `u8` store may alias *anything* (char aliasing), including `out.p`. So clang reloads
and stores `p` around every field, a serial store-to-load chain through memory:
```
ldr  x12, [x1]          ; out.p
add  x13, x12, #0x4
str  x13, [x1]          ; out.p += 4
ldr  w13, [x0, #0x8]
str  w13, [x12, #0x4]
ldr  x12, [x1]          ; reload out.p again ...
```
Fix: `LocalByteWriter out(out_);` at the top of each `serialize` (a local copy that writes `p` back in its
destructor). After the fix it's `ldr / fcmp / csel / str` per field with `p` in a register. Serialization drops
from 290 to 48 µs. Script: `perf/scripts/cpp_writer.py`.

**2. No LTO (build-config choice, documented in the README as the usual C++ trade-off): 516 → 480.**
`-flto=thin` (compile + link) inlines the cross-TU helpers (re-measured after a clean rebuild: 471). `-O3` instead of `-O2` makes no difference
(484 vs 480).

**Language/compiler share:** none.

## Zig (1728 → 477)

**1. `std.hash.XxHash3` is very slow on aarch64 (standard library / compiler codegen): 1342 → 477.** It took
**54% of the tick (~920 µs)**. `Accumulator.accumulate` reads the secret as an align-1 `[]u64`
(`bytesAsSlice(u64, secret[consumed*8..])`), and LLVM assembles each u64 from single bytes. The function is
2.6 KB of `ldrb / orr / lsl`:
```
ldrb w8, [x9, #0x1b] ; lsl x8, x8, #8 ; ldr w10, [x9, #0x1c] ; orr x8, x8, x10, lsl #16
ldrb w10, [x9, #0x1a] ; orr x8, x8, x10 ; lsl x8, x8, #16 ; ldrb w10, [x9, #0x19] ...
```
In Benchmark A the buffer was 18 KB, so this never showed. Fix: compile the reference `xxhash.h`
(the one C++ uses, NEON path) with `zig cc` as part of the build. That's three lines in `build.zig`
(`addCSourceFile`, `addIncludePath`, `link_libc`) plus a 5-line `extern fn` wrapper. This is idiomatic Zig:
C is a first-class build input.

**2. `*HashWriter` aliasing (emitter choice; Zig has no type-based alias analysis at all): 1728 → 1342.**
This is the same pattern as C++, but in Zig even `u32` stores alias the writer's `pos`. Fix: `var lw = w_out.*;
const w = &lw; defer w_out.* = lw;` in each `serialize`. Script: `perf/scripts/zig_writer.py`.

ReleaseFast was already in use, so safety checks were not a factor. The gameplay systems (171 µs) are on par
with Rust/C++. Splitting the code into separate Zig modules doesn't stop inlining (Zig compiles one LLVM module).

**Language/compiler share:** only through the standard library's XXH3.

## Odin (1174 → 523)

**1. The writer: four bounds-checked byte stores per u32, through `^Writer` (emitter choice): 1174 → 574.**
Serialization was **~57% of the tick (~665 µs)**:
```odin
put_u32 :: #force_inline proc(w: ^Writer, v: u32) {
	w.buf[w.n + 0] = u8(v)        // bounds check + store, and w.buf/w.n reloaded after each store
	w.buf[w.n + 1] = u8(v >> 8)
	...
```
Fix:
- One checked `intrinsics.unaligned_store((^u32le)(&w.buf[w.n]), u32le(v))` (`_ = w.buf[w.n+3]` keeps one
  bounds check).
- `lw := w_out^; w := &lw; defer w_out^ = lw` in each `*_serialize`.

Script: `perf/scripts/odin_writer.py`. Each change alone gives less (10k: 289 and 256 µs vs 242 for both;
100k with only the local copy: 631 µs).

**2. `core:hash/xxhash` (standard library): 574 → 523.** The XXH3 is NEON-vectorised, but the accumulators
make a round trip through the stack every stripe (`stp q1, q3, [sp]` … `ldp q0, q3, [sp]`). That's 83 µs vs
21–30 µs for the C version. Odin has no C compiler, so the fix is `xxh3.c` built once with the system clang into
`src/sim/xxh3c/libxxh3.a`, plus a `foreign import`. Practical, but it adds a C step to an otherwise C-free build.

**`-o:speed` single module vs separate modules.** The single LLVM module is what makes Odin fast here: it inlines
the whole schedule into `game::step` and the sim into `main`. `-use-separate-modules` on the fixed code builds
in **2 s** but ticks **1577 µs**. The catch is build time:
- **Original:** the single-module release took 108 s at 100k.
- **Fixed writer:** it takes **894 s at 100k** (56 s at 10k, 218 s at 50k).
- **Neither half alone blows up at 10k (6–8 s)**, but at 100k the local copy alone already took 1485 s.

This looks like an LLVM optimiser scaling problem on the huge, fully inlined serializer.

**Language/compiler share:** the standard-library XXH3, and the release build-time cliff. The systems (172 µs)
match the other LLVM languages.

## C# (3622 → 1294 AOT; steady-state JIT ~1210–1300)

**Warm-up vs steady state** (best code, JIT, 10 000 ticks, mean per 1000-tick window):
`3098 1318 1297 1285 1289 1312 1302 1300 1283 1293`. The original code shows the same pattern:
`3621 1433 1426 1430 1427 1464 1454 1419 1417 1423`. So about **1.9 s of the first 1000 ticks is JIT**
(151k lines of huge methods compiled at Tier0, then again at Tier1 with PGO).

| Setting | 100k, 1000 ticks (µs/tick) |
|---|---|
| JIT, default (TieredPGO on) | 3221 |
| JIT, `DOTNET_TieredPGO=0` | 2510 |
| JIT, `DOTNET_TC_QuickJitForLoops=0` | 2742 |
| JIT, `DOTNET_TieredCompilation=0` | 2725 |
| JIT, warm (second run in the same process) | 1210 |
| **NativeAOT** (`./build.sh aot`, unchanged code: 1379) | **1294** |

ReadyToRun wasn't measured: the crossgen2 runtime pack isn't in the offline NuGet cache, so it would need a
download. NativeAOT is the practical fix for short runs. Its steady state matches the warm JIT (AOT over
10 000 ticks: 1312 mean).

**1. Serialization (emitter pattern): 253 → 124 µs (warm).** `GBufferWriter.U32` does
`BinaryPrimitives.WriteUInt32LittleEndian(_buf.Slice(_pos), v); _pos += 4` on a `ref GBufferWriter`. That's two
bounds checks plus a memory round trip of `_pos` per field. In the large `Write` methods the JIT also stops
inlining `U32`/`F32` (13 `bl GBufferWriter.U32` in `ThrowingData.Write` alone).

Three attempts:
- **Local copy of the writer (C++/Rust/Zig style): worse (serialize 553 µs).** The JIT doesn't promote a
  ref struct holding a `Span`. Rejected; the script is kept as `perf/scripts/csharp_writer_localcopy_REJECTED.py`.
- **A `ref byte` + length + `Unsafe.WriteUnaligned` writer: also worse (440–478 µs).**
- **What works: one span per row with constant-offset intrinsic stores.**
  `Span<byte> d = w.Take(45); Unsafe.WriteUnaligned(ref d[0], …); d[4] = …`. One bounds check per row, nothing
  left to inline in the loop. Script: `perf/scripts/csharp_rows.py`.

**2. The gameplay systems are ~4.4× slower than C++ (compiler limit: RyuJIT .NET 8).** Per-system timers in
both languages (same 324 systems, warm C# vs C++) show the ratio grows with method size:

| IR statements per system | n | C# µs | C++ µs | ratio |
|---|---|---|---|---|
| < 40 | 49 | 4.8 | 2.1 | 2.3× |
| 40–100 | 61 | 69.5 | 20.6 | 3.4× |
| 100–160 | 78 | 144.4 | 36.2 | 4.0× |
| 160–220 | 63 | 196.3 | 49.3 | 4.0× |
| ≥ 220 | 73 | 380.4 | 73.0 | 5.2× |

Generated code for one representative system, `ghost_platforms.score_slot` (263 IR statements; C# from the
NativeAOT binary, which uses the same RyuJIT backend):

| | instructions | `fcsel` | conditional branches | calls | stack ld/st |
|---|---|---|---|---|---|
| Rust (LLVM) | 2053 | 245 | 40 | 24 | 234 |
| C++ (clang) | 2265 | 266 | 39 | 28 | 205 |
| C# (RyuJIT) | 3547 | **0** | **291** | **~190** | 647 |

Three causes, all in the compiler:
- **No if-conversion in loops.** Every IR `min`/`max`/`select`/clamp becomes a compare-and-branch on
  data-dependent floats instead of `fcsel`. LLVM emits 245 `fcsel`; RyuJIT emits 0. This affects every system,
  small ones included, and is the likely main cause of the base 2.3–4× gap.
- **The inliner gives up in big methods.** `Num.Min`/`Num.Max` are `[AggressiveInlining]` one-liners, yet
  `score_slot` makes 74 calls to `Num.Max` and ~72 to `Num.Min`. Across all 324 systems, methods under 1500
  instructions have 0 such calls, and the 26 biggest have 109 each (4480 in total). That's RyuJIT's per-method
  inline limits (local-variable / budget). Another 5586 calls are helpers and `InlineArrayAsReadOnlySpan`
  accessors for `in Hooks` arrays.
- **Spills.** Many locals cause 647 stack loads and stores, against ~220 in LLVM.

Fixes tried, none of which helped:
- `DOTNET_JitInlineBudget=200`, `DOTNET_JitMaxLocalsToTrack=8192`, `DOTNET_TieredPGO=0`,
  `DOTNET_TieredCompilation=0`: all within noise (gameplay 773–817 µs).
- Emitting f32 `min`/`max` as `MathF.Min`/`MathF.Max` (a perf copy of the emitter, `perf/csharp/emit_perf.py`,
  `PERF_FMINMAX=1`): hash unchanged, but **worse (gameplay 1080–1120 µs)**. On .NET 8/arm64 these are managed
  NaN/±0-aware methods, not single `fmin`/`fmax` instructions.

What would help is splitting systems into smaller methods, or a newer .NET. Splitting is not idiomatic, and the
IR's large `Update` bodies are the point of the test. Newer .NET was not tested: only .NET 8 is installed.

**Language/compiler share:** large.
- **Steady state:** the ~600 µs of extra gameplay time at 100k is RyuJIT codegen. The swarm (~220 µs, the same
  as Rust) shows ordinary C# loops are fine. It's the huge, branchy generated methods.
- **Cold:** another ~1.9 s of JIT per run, which NativeAOT removes.

---

## Summary: language/compiler limits vs emitter choices

| | Emitter / build choices (fixed here) | Language / compiler / stdlib limits (remain) |
|---|---|---|
| Rust | writer through `&mut` struct (reloads); no `#[inline]`/LTO; per-field slice checks | none measurable; fat LTO impractical at this size |
| C++ | writer through `ByteWriter&` with char-type stores (aliasing); no LTO | none |
| Zig | writer through `*HashWriter` (no TBAA) | `std.hash.XxHash3` codegen on aarch64 (~900 µs at 1.2 MB) |
| Odin | byte-wise, 4× bounds-checked `put_u32` through `^Writer` | `core:hash/xxhash` 3× slower than C; single-module release build time explodes (108 → 894 s) once the serializer is optimisable |
| C# | `Span.Slice` + `ref` writer per field; JIT instead of AOT for short runs | RyuJIT .NET 8: no `fcsel` in loops, inliner gives up in large methods, spills (~4.4× on gameplay); ~1.9 s JIT warm-up |

The common thread: **every emitter wrote "pass the writer by pointer/reference and append one field at a time"**.
That's idiomatic in all five languages, but only Rust's borrow rules partly protect it. One local copy (or, in C#,
a span per row) fixes it. In this benchmark it was worth more than every language difference except C#'s JIT.

## Files

- `bench/s/perf/tick.sh <binary> <scale>`: 3 × `--ticks 1000`, median plus hash check.
- `bench/s/perf/scripts/{rust,cpp,zig,odin}_writer.py`, `csharp_rows.py`: the serializer edits (re-runnable on a
  fresh copy).
- `bench/s/perf/<lang>/p{10k,50k,100k}`: the modified copies. Other edits:
  - Rust `Cargo.toml` (`lto = "thin"`) and `game-core/src/hash.rs` (unchecked `put`).
  - C++ `CMakeLists.txt` (`-flto=thin`).
  - Zig `build.zig` + `src/sim/xxh3.{c,zig}`.
  - Odin `src/sim/xxh3.odin` + `src/sim/xxh3c/`.
  - C# p100k only: `Sim.cs`/`Program.cs` phase timers (`BENCH_PHASES=1`) and warm-up mode (`BENCH_WARMUP=1`).
- `bench/s/perf/csharp/emit_perf.py`: emitter copy with the (rejected) `PERF_FMINMAX` option.
- Profiles, disassembly and per-system timings are in the session scratchpad (`prof/`), not in the repo.
