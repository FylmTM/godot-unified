# Gameplay IR for the bench/s scale test

The five emitters (Rust, Odin, Zig, C++, C#) each turn the same `features-<scale>.json` into an idiomatic gameplay
codebase on top of their Benchmark A implementation (`bench/a/SPEC.md`). All five must produce **bit-identical
hashes every tick**, as Benchmark A does. This file defines the IR exactly: what every node means, the evaluation
order, the per-tick integration with Benchmark A, the hash extension and the three edit points for incremental-build
measurement.

| File | What |
|---|---|
| `ir.py` | the generator: `python3 ir.py --scale {10k,50k,100k} --seed 1 > features-50k.json` (`--stats` prints a summary to stderr, `--pretty` indents) |
| `features-{10k,50k,100k}.json` | generated with seed 1 (the inputs the emitters use) |
| `interp.py` | reference interpreter + IR validator: `python3 interp.py features-10k.json --ticks 50` |

Python 3 stdlib only. The generator is deterministic: its own splitmix64 PRNG (never `random` or `hash()`), no set
iteration. The output is byte-identical across runs and `PYTHONHASHSEED` values.

## 1. Integration with Benchmark A

The gameplay runs as **step 7b** of the Benchmark A tick: after `b3World_Step` (step 7) and before step 8 (the
`tick = t + 1` increment, the hash and the ring copy).

1. Compute the **hooks** (section 11): read-only values taken from the Benchmark A state.
2. Set `count = 0` on every event channel (in IR order). `head` keeps its value.
3. Run every system in `schedule` order, skipping a system unless `t % period == phase` (`t` = the `tick` hook).

The gameplay **never writes Benchmark A state** (the tick, hits, rng, inputs, agents, physics). So Benchmark A's
part of the hash buffer is unchanged.

All generated state lives **inside the one contiguous, pointer-free state block**: tables, resources, event channels
and alive counts. It is copied into the 16-slot ring with the rest. Configs and helper functions are code or
constants, not state.

**Hash per tick (step 8):** `XXH3-64(seed 0)` of `A_buffer ‖ G_buffer`. `A_buffer` is Benchmark A's canonical buffer,
unchanged. `G_buffer` is the gameplay buffer (section 10). You can hash the concatenation in one shot or stream the
two parts: the result is the same. Recommended outputs (they make mismatches easy to localise):
- `--trace` lines: `"%06d %016x\n"` of the combined hash, as in Benchmark A.
- final JSON: `final_hash` (combined), `core_hash` (A_buffer alone: must still be `d106cbf36b441bbd` at 3600 ticks)
  and `gameplay_hash` (G_buffer alone).
- a `--synthetic` mode that skips Benchmark A entirely, feeds the synthetic hooks (section 11) and prints exactly
  what `interp.py` prints (an `init` line, then `"%06d %016x"` of G_buffer per tick). It is directly diffable.

## 2. Top level

```jsonc
{
  "ir_version": 1,
  "generator": {"tool", "scale", "seed", "target_rust_lines", "body_knob", "estimated_rust_lines"},
  "hooks":    [ {"name", "ty", "count", "def"} ],          // section 11
  "groups":   [ {"name", "doc", "features": [names]} ],    // map to crates / packages / modules
  "features": [ Feature ],                                  // IR order = topological order of deps
  "schedule": [ "feature.system", ... ],                    // global per-tick system order
  "edit_points": {"leaf", "mid", "core"}                    // section 13
}
```

**Groups.** These are `common` (always just the `actor` feature), then `player`, `items`, `level`, `enemies`, `puzzles`,
`hub` and `meta` (10k uses 5 groups, 50k uses 7, 100k uses 8). Features depend only on earlier features, and groups
are listed in layering order, so a group only depends on itself and earlier groups. Mapping groups to crates or
packages therefore never creates a cycle.

## 3. Feature

```jsonc
{
  "name": "grapple", "group": "player", "doc": "...",
  "deps": ["actor", "locomotion"],      // features this one reads (always includes "actor"), all earlier in IR order
  "dependents": [...],                  // informational: features listing this one in deps
  "resource": Resource | null,          // a singleton struct (hashed state)
  "components": [Component],            // 2–6 tables (hashed state)
  "configs": [Config],                  // 1–3 constant structs (not state)
  "channels": [Channel],                // 0–1 event rings (hashed state)
  "helpers": [Helper],                  // 1–4 pure functions (actor: 5)
  "systems": [System]                   // 2–6 per-tick functions
}
```

**Access rules** (the validator enforces them):
- A feature **reads** its own and its `deps`' tables, resources, configs, alive counts and channels. It **calls** its
  own helpers and its deps' helpers that have `"export": true`.
- It **writes** only its own tables, resource, alive counts and channel.
- Cross-feature reads are the coupling: almost every feature reads `actor.Transform`, and a few hub features are
  read by many others.

**Identifiers.** Feature, field, local, parameter, helper and system names are lowercase `snake_case`. Type names
(components, resources, configs, channels) are `PascalCase`. Every type name is **globally unique** (they're
prefixed with the feature), every helper name is globally unique, and system names are unique within their feature.
IDs are `"<feature>.<Name>"`. No identifier is a keyword in any of the five languages, or `min`, `max`, `abs`,
`sqrt`, `clamp`, `select`, `alive`, `state`, `world`, `ctx`, `core`, `std`, `len`, `value`, `result`.
**Inside one function every name (parameter, local, loop variable) is unique**, so no language's shadowing rule
applies. Emitters may freely use names starting with `ir_` or `__` for their own temporaries (the IR never does).

## 4. Types and storage

Field types: `f32`, `i32`, `u32`, `u8`, `bool`. Expression types: `f32`, `i32`, `u32`, `bool`.
- Loading a `u8` field yields a `u32` (zero-extended). Loading a `bool` field yields `bool`.
- Storing to a `u8` field takes a `u32` expression whose value the generator guarantees is `< 256`, so any
  truncating or checked cast works. Storing to a `bool` field takes a `bool`.
- In-memory layout (`bool` vs `u8`, AoS vs SoA, padding) is the emitter's choice. Only the hash serialization is
  fixed (section 10).

### Component (table)

```jsonc
{ "name": "GrappleHook", "id": "grapple.GrappleHook", "capacity": 128, "alive": 23,
  "fields": [ {"name": "charge", "ty": "f32", "range": ["0.0", "256.0"], "init": Expr},
              {"name": "mode",   "ty": "u8",  "init": Expr}, ... ] }
```
- `capacity` ∈ {64, 128, 256} (a power of two). All components of one feature have the same capacity, so a slot
  index valid in one is valid in the others ("the same entity").
- `alive`: the initial alive count (`0 ≤ alive ≤ capacity`), stored in the state as a `u32` and changed only by
  `set_alive`. `each` systems iterate slots `0..alive`. All `capacity` slots are state and are hashed, including
  dead ones.
- `init`: an expression over the local **`i` (u32, the slot index)** and constants only, evaluated for every slot
  `0..capacity-1`. `range` (f32 only) is informative: every f32 store to the field is already clamped to it in the
  IR.

### Resource (singleton)
`{"name","id","fields":[{"name","ty","range"?, "init": const Expr}]}`. Field types are `f32`, `u32` and `i32`; inits are
constants.

### Config (constants, not state)
`{"name","id","fields":[{"name","ty","v"}]}`. Field types are `f32` (`v` is a decimal string), `u32` and `i32` (`v` is a
JSON number). Emit these as compile-time constants or immutable statics, whichever is idiomatic. They are read
through `{"op":"cfg"}`.

### Channel (event ring)
`{"name","id","capacity":16|32,"fields":[{"name":"slot","ty":"u32"}, ...]}`. Record fields are `f32` or `u32`, and
the first is always `slot`. State: `head: u32`, `count: u32` and `records[capacity]`, all initially zero.
- **emit**: evaluate all field expressions, then `r = head & (capacity-1)`, write the record to `records[r]`,
  `head = head + 1`, `count = count + 1` (u32 wrapping). If more than `capacity` events are emitted in a tick, the
  oldest are overwritten.
- **for_events** (in a consumer feature that depends on the producer): `n = min(count, capacity)`; for
  `k = 0..n-1`: `r = (head - n + k) & (capacity-1)` (u32 wrapping); run the body with `ev` = `records[r]`. This
  visits the events emitted this tick, oldest first.
- `count` is reset at the start of every tick's gameplay step (section 1). The producer always runs before the
  consumer in the schedule.

## 5. Helper (pure function)

```jsonc
{ "name": "bias_heat", "id": "grapple.bias_heat", "export": true,
  "params": [{"name": "dist", "ty": "f32"}, ...], "ret": "f32" | "u32",
  "body": [Stmt],    // only let / set / if
  "result": Expr }   // the return value, evaluated after the body
```
Helpers see only their parameters and constants. They have no state, hooks or config reads. They may call earlier
helpers of the same feature and exported helpers of deps. Emit them as free functions; inlining is the emitter's
choice. Every parameter and local is read at least once.

## 6. System

```jsonc
{ "name": "update_hook", "id": "grapple.update_hook",
  "kind": "each" | "single",
  "table": "grapple.GrappleHook", "var": "i",     // each only
  "period": 1|2|4, "phase": 0..period-1,
  "body": [Stmt] }
```
- `each`: `n = alive(table)`, read **once** before the loop; then `for i in 0..n` (ascending, `i: u32`) run `body`.
- `single`: run `body` once.
- It runs on tick `t` iff `t % period == phase`.

Loops are **sequential, in ascending order**. Writes are immediately visible to later reads, including reads of
other slots of the same table in later iterations, so emitters must not parallelise, vectorise across iterations or
reorder loops in any way that changes that.

## 7. Statements

All statements execute in list order.

| `s` | Fields | Meaning |
|---|---|---|
| `let` | `name, ty, expr, mut` | declare a local of type `ty`, initialised to `expr`. `mut: true` iff some later `set` assigns it (so Rust `let mut` / Zig `var` vs `const` are exact). Visible from the next statement to the end of the enclosing block, including nested blocks. |
| `set` | `name, expr` | assign to a local in scope (same type) |
| `store` | `table, field, index, expr` | `table[index].field = expr`. `index` is u32 and **always `< capacity`** by construction. |
| `store_res` | `res, field, expr` | `resource.field = expr` |
| `set_alive` | `table, expr` | `alive(table) = expr` (u32, guaranteed `≤ capacity`; only in `single` systems) |
| `if` | `cond, then, else` | `else` may be `[]`. An `else` holding exactly one `if` may be printed as `else if`. |
| `for` | `var, count, body` | `c = count` (u32, evaluated once); `for var in 0..c` ascending, `var: u32`. `count` is a constant ≤ 6, or `alive(T)`. |
| `emit` | `channel, fields{name: Expr}` | push one record (section 4). `fields` lists every record field in record order. |
| `for_events` | `channel, body` | iterate this tick's events (section 4). `ev` expressions in the body read the current record. Never nested. |

Every `let`, parameter and loop variable is read at least once (Zig rejects unused locals). No `then`, `for` or
`for_events` block and no system body is empty. An `else` may be empty, and so may a helper body (then the helper
is just its `result`).

## 8. Expressions

Every node is `{"op", "ty", ...}`. Operators have `"args": [Expr, ...]`. **Expressions are pure** (no side
effects), so the evaluation order of operands and arguments doesn't affect results. What matters is the **tree
shape**: emit exactly the given tree, one IR node per operation, and every intermediate is rounded to its type
(f32 for f32 nodes). Never reassociate, distribute, constant-fold differently from IEEE, or fuse. Parenthesise every
binary operation when printing, and use typed literals.

### Leaves
| `op` | Fields | Type | Meaning |
|---|---|---|---|
| `const` | `v` | any | f32: decimal **string**, exactly representable (a dyadic rational), so every parser yields the same bits; print it verbatim with the f32 suffix/cast. i32/u32: JSON number (u32 up to 4294967295: use an unsigned literal). bool: `true`/`false`. |
| `local` | `name` | any | a local, parameter or loop variable (`i`, `j`, `p`, …) |
| `load` | `table, field, index` | field load type | `table[index].field`; index u32 `< capacity` by construction |
| `res` | `res, field` | field type | resource field |
| `cfg` | `cfg, field` | field type | config constant |
| `hook` | `hook, index?` | hook type | section 11. Indexed hooks have `index < count` by construction. |
| `alive` | `table` | u32 | current alive count |
| `ev` | `field` | record field type | field of the current event (only inside `for_events`) |
| `call` | `fn, args` | helper `ret` | call a helper; args match param types |

### Operators
| `op` | Operand → result types | Semantics |
|---|---|---|
| `add` `sub` `mul` | f32,f32→f32; i32,i32→i32; u32,u32→u32 | f32: IEEE round-to-nearest-even. **Integers wrap** (two's complement): Rust `wrapping_*`, Zig `+% -% *%`, C++ via `uint32_t` arithmetic (signed overflow is UB), C# `unchecked` (the default), Odin native. |
| `div` | f32,f32→f32 | IEEE division. The denominator is always `abs(x) + c` or `x + c` with `c ≥ 1` and `x ≥ 0`, so it is never zero. |
| `min` `max` | f32/i32/u32 (both the same) | **`min(a,b) = (b < a) ? b : a`, `max(a,b) = (b > a) ? b : a`.** With no NaNs anywhere, these differ from `fminf`/`f32::min` only in the sign of a zero result, which can never become observable (no division by an unguarded value, -0.0 is canonicalised in the hash). Still, use this definition. |
| `abs` | f32→f32 | clear the sign bit |
| `neg` | f32→f32 | flip the sign bit (`-x`) |
| `sqrt` | f32→f32 | IEEE sqrt. The operand is `abs(x)`, or a sum of squares, or a local holding one, so never negative. |
| `and` `or` `xor` | i32/i32 or u32/u32 | bitwise |
| `shl` `shr` | u32,u32→u32 | the second operand is a **constant 0..31**; `shl` drops overflowing bits, `shr` is logical. (Zig: cast the amount to `u5`.) |
| `lt` `le` `gt` `ge` `eq` `ne` | f32/i32/u32 pairs → bool | IEEE / integer comparison |
| `land` `lor` | bool,bool→bool | logical and/or (operands are pure, so short-circuiting is fine) |
| `lnot` | bool→bool | logical not |
| `select` | bool, T, T → T | `cond ? a : b` (pure, so a ternary is fine) |
| `f2i` | f32→i32 | truncate toward zero. The operand is always clamped to `|x| ≤ 65536` first, so it is in range in every language (C++'s UB and Rust's saturation never come into play). |
| `i2f` `u2f` | i32/u32→f32 | round to nearest even (every language's default int→float) |
| `i2u` `u2i` | i32↔u32 | reinterpret the 32 bits |

**f32 rules (as in Benchmark A):** no FMA contraction (C/C++/Zig C sources: `-ffp-contract=off`; Zig's own code is
strict by default; C#/.NET and Rust don't contract), no fast-math, no flush-to-zero (subnormals can occur and must
be kept: the default on ARM64 and x64 for all five), no f64 anywhere, no transcendental functions.

## 9. Initial state

- Tables: every field of every slot `0..capacity-1` = its `init` evaluated with `i` = slot. `alive` = the given
  value.
- Resources: field = its constant `init`.
- Channels: `head = count = 0`, all records zero.

The `init` line of `interp.py` is the gameplay-buffer hash right after initialisation, before tick 1.

## 10. Hash extension (the gameplay buffer `G_buffer`)

Little-endian, **no padding anywhere**. For each feature in `features` order:
1. the resource, if any: its fields in order;
2. each component in order: `alive` (u32), then for slot `0..capacity-1`: that slot's fields in order;
3. each channel in order: `head` (u32), `count` (u32), then records `0..capacity-1`, fields in order.

Encodings: `f32` is its 4 bits after canonicalising `-0.0 → +0.0` (other values unchanged; there are no NaNs).
`i32` is 4 bytes two's complement. `u32` is 4 bytes. `u8` is 1 byte. `bool` is 1 byte, 0 or 1.

The per-tick hash is `XXH3-64(seed 0)` over `A_buffer ‖ G_buffer`. `G_buffer` is about 115 KB at 10k, 580 KB at 50k
and 1.2 MB at 100k.

## 11. Hooks (the read-only coupling to Benchmark A)

The emitter computes these once per tick at step 7b, from the state as it is after step 7:

| Hook | Type | Count | Definition (real build) | Synthetic (`interp.py`, `--synthetic`) |
|---|---|---|---|---|
| `tick` | u32 | – | `t` (state.tick before step 8) | `t` |
| `hits` | u32 | – | state.hits | `t*3` (u32) |
| `player_x/y/z` | f32 | 4 | `min(max(pp[p].x, -64.0), 64.0)` (pp from step 3, same for y and z; min/max as in section 8) | x: `u2f((t*7 + p*61) & 255) * 0.5 - 64.0`; y: `u2f((t + p*13) & 15) * 0.25`; z: `u2f((t*5 + p*101 + 37) & 255) * 0.5 - 64.0` |
| `input_dx`, `input_dz` | i32 | 4 | `(i32)state.input[p].dx` / `.dz` | `((t/30 + p) % 3) - 1` / `((t/30 + 2p) % 3) - 1` |
| `input_jump` | u32 | 4 | `(u32)state.input[p].jump` | `(t + 7p) % 45 == 0 ? 1 : 0` |
| `agents_near` | u32 | 4 | number of agents `i` with `target[i] == p` | `(t*13 + p*97) % 251` |
| `agents_blocked` | u32 | – | number of agents with `blocked[i] == 1` | `(t*7) % 300` |
| `agent_x`, `agent_z` | f32 | 1000 | `state.px[k]`, `state.pz[k]` (after step 6) | `u2f((k*7 + t) & 127) * 0.75 - 48.0`, `u2f((k*13 + t*3) & 127) * 0.75 - 48.0` |

Synthetic formulas use integer arithmetic (non-negative, so `/` and `%` are unambiguous), then f32 operations in
the order written. Every step is exact. In the IR, `player_*`, `input_*` and `agents_near` indices are `< 4` and
`agent_*` indices are `≤ 511`. A handful of features read `agents_near`, `agents_blocked` and `agent_*`, and many read
the player hooks.

## 12. Value bounds (why 3600+ ticks stay finite)

The generator gives every f32 node a static bound on |value|:
- Every f32 store (table, resource, channel record) is clamped to the field's range, so all persistent f32 state is
  bounded (|x| ≤ 256).
- Any node whose bound exceeds 1e9 is wrapped in a clamp. Helper arguments are clamped to ±8192.
- A single operation on operands ≤ 1e9 stays ≤ 1e18, far below the f32 maximum (3.4e38).

There are no divisions by zero, no sqrt of negatives and no inf - inf, so **no NaN or inf can arise**. Integers wrap
by definition. Emitters need no guards, though debug asserts are welcome. `interp.py` asserts all of these at run
time. It also checks that indices are below capacity and that `u8` stores are `< 256`.

## 13. Edit points (incremental-build measurement)

The measuring script makes exactly one of these edits, rebuilds and times it. Its JSON is under `edit_points`.

**`leaf`**: `{"feature", "system", "local": "edit_leaf", "marker": "BENCH_EDIT_LEAF"}`. A feature that no other feature
depends on. Its system's prologue contains `{"s":"let","name":"edit_leaf","ty":"f32","expr":<const 1.0>,"mut":false,"edit":"leaf"}`,
and the body multiplies a written-back f32 field by it near the end. Emit it as **one line inside the system function body**, holding the literal and the marker,
e.g. `let edit_leaf: f32 = 1.0; // BENCH_EDIT_LEAF`. Don't hoist it to a module or global constant. The script rewrites
the number on that line (1.0 ↔ 1.0625). The hash changes, as expected.

**`mid`**: `{"feature", "helper", "local": "edit_mid", "marker": "BENCH_EDIT_MID", "dependents", "calling_features"}`. An
exported helper of a feature with 3–5 dependents, called by them. The first statement of its body is
`let edit_mid: f32 = 1.0` (marked `"edit":"mid"`), and the result is multiplied by it. Emit it the same way: one line
in the helper's body with the marker. Where the helper lives (header/inline vs. separate compilation unit, crate
boundary) is the emitter's idiomatic choice, and that choice is part of what gets measured.

**`core`**: `{"table": "actor.Transform", "add_field": {"name": "edit_pad", "ty": "f32"}, "marker": "BENCH_EDIT_CORE",
"hashed": false, "readers": [...]}`. This adds a field to the shared `Transform` that every feature reads. Emitter
obligations:
- Put a line containing `BENCH_EDIT_CORE` inside the `Transform` definition, after its last field. Document in your
  README the exact single line the script inserts after it (e.g. Rust `pub edit_pad: f32,`).
- With only that one-line insertion, the project must build. So `Transform` must be zero- or default-initialised
  (never constructed field by field), and pointer-freedom or no-padding checks must still pass. All Transform fields
  are 4 bytes, so adding an f32 adds no padding.
- `edit_pad` is never read or written and **not hashed**, so the trace must be identical with and without the edit
  (a good sanity check). Don't serialize by reflection over struct fields.
- It must be a **real layout change**: `sizeof(Transform)` goes from 36 to 40 bytes, and every feature that reads
  Transform sees the new definition. No opaque handles or out-of-line accessors that hide the layout.

## 14. Size calibration

`ir.py` estimates the non-blank lines of a *straightforward Rust emission* (rustfmt, 100 columns), with
these rules:
- Each `let`/`set`/`store`/`store_res`/`set_alive` takes `1 + ceil((len - 100)/70)` lines, where `len` is the length
  of a rendered Rust-like statement (`s.feat.table[i as usize].field`, `a.wrapping_add(b)`, `fmin(a, b)`, typed
  locals) plus its indent.
- An `if` takes its condition line, the body, `} else {` and `}`. A `for` adds 2 lines. An `emit` takes 3 + the field
  count. A `for_events` adds 5 lines.
- Each system adds 8 lines (signature, table borrows, the `each` loop, closing braces), plus 3 for a period check.
  Each helper adds 3 plus its result line.
- Data definitions, per component with `n` fields: struct `n+3`, init `n+5`, hash `n+4`, plus 2 lines of
  state-block glue. A resource takes about `3n+8` lines, a config `2n+5`, and a channel `2n+17` (record, hash,
  push/iterate).
- Each feature adds 12 module/`use` lines plus one per dep, and each system one schedule line. 40 lines are global.

A bisection over the system-body size (`body_knob`, recorded in `generator`) lands the estimate within 0.1% of the
target. Other languages will differ (C++ headers, C# boilerplate, Zig/Odin verbosity). That difference is part of
what we measure.

| Scale | Features | Groups | Components (fields) | Systems | Helpers | Channels | Est. Rust lines | JSON |
|---|---|---|---|---|---|---|---|---|
| 10k | 8 | 5 | 31 (240) | 34 | 24 | 3 | 10,008 | 1.8 MB |
| 50k | 40 | 7 | 157 (1178) | 155 | 96 | 13 | 50,005 | 9.0 MB |
| 100k | 80 | 8 | 317 (2343) | 324 | 212 | 21 | 99,996 | 17.9 MB |

Systems average about 140 statements (5 to 300). That's big `Update` functions with state machines, timers,
neighbour reads, nearest-player searches, small loops over dependency tables, helper calls and event emission. Alive
counts average about 25 of 64–256 slots, and about a third of the systems run every 2nd or 4th tick, so the per-tick
cost stays modest. The dependency DAG uses mild preferential attachment: a few hubs with 10–17 dependents, a middle
tier with 3–9, and many leaves.

## 15. The reference interpreter

```
python3 interp.py features-10k.json --check                 # validate only (types, scopes, deps, schedule, usage)
python3 interp.py features-10k.json --ticks 50              # "init <hash>" then "%06d %016x" per tick (G_buffer)
python3 interp.py features-10k.json --ticks 5 --tables 3    # plus per-part hashes (resource/table/channel) at tick 3
python3 interp.py features-10k.json --ticks 3 --dump 2      # the full generated state at tick 2 as JSON
python3 interp.py features-10k.json --hooks hooks.jsonl     # use hook values dumped from a real build
```

**f32 method:** stdlib only, no numpy. Every f32 operation is computed in Python's double and rounded to f32 with
a `struct` pack/unpack round trip. For `+ - * /` and `sqrt` this gives exactly the IEEE f32 result, because double
has at least 2·24+2 bits, so double rounding is innocuous. Out-of-range results raise. min/max/abs/neg and
conversions follow section 8 exactly. XXH3-64 is a pure-Python port, checked against `bench/a/cpp/third_party/xxhash.h`
on 44 lengths covering every code path (0–16, 17–128, 129–240, long).

**Hook dump format (`--hooks`):** one JSON object per tick, starting at t=0, with every hook by name. f32 values
are 8-hex-digit bit-pattern strings (e.g. `"41a00000"`), and integers are JSON numbers. Arrays are for counted
hooks. With it, the interpreter reproduces a real build's `gameplay_hash` exactly. Use it to tell an emitter bug
from a hook-computation bug.

**Reference gameplay hashes** (synthetic hooks, seed-1 files; G_buffer only):

| File | init | tick 1 | tick 50 | last checked |
|---|---|---|---|---|
| features-10k.json | `4e4ec2b2a14088b6` (114,836 B) | `edc4b6fccc79e792` | `12ae2d10d2246a03` | tick 3600 `6e7016d437a5fdf9` |
| features-50k.json | `6d8911e94de6587e` (579,116 B) | `ed47113607ea52e8` | `b4aa0fadf113525a` | tick 200 `444d20c2b9d980bf` |
| features-100k.json | `05f05e82cc0d6a80` (1,227,024 B) | `517b6f25436f60f5` | `6ec160924a4101b6` | tick 60 `e98defd9b9ea9fbf` |

`interp.py` runs at about 0.06 s/tick at 10k and about 0.5 s/tick at 50k.

**Debug workflow:**
1. Run `--synthetic` against `interp.py` (diff the outputs).
2. On a mismatch at tick N, compare `--tables N` part hashes to find the table, then `--dump N` to find the field.
3. Then check against the real sim with `--hooks`.

## 16. Emitter checklist (where five languages diverge)

- **Literals:** print the IR decimal verbatim with the f32 marker (Rust `1.5f32` or a typed context, C++/C# `1.5f`,
  Zig/Odin typed constants). Literals are exact, so Zig's `comptime_float` and C#'s parser can't differ. Negative
  literals are inside function calls or binary operations: parenthesise. For u32 constants above 2^31 (e.g.
  `2654435761`), use an unsigned literal (`u`).
- **Wrapping integer ops everywhere** (Rust debug builds panic otherwise; C++ signed overflow is UB). u32 `mul` by
  2654435761 or 1664525 overflows constantly, by design.
- **min/max:** use the section 8 definition (a two-line helper), not `std::min` with mixed types or `Math.Min` with
  doubles.
- **Indices:** u32 values. Cast to `usize`/`size_t`/`int` for indexing. They're always in range: debug bounds checks
  will never fire unless the emitter has a bug.
- **No hidden reordering:** keep the per-entity loop sequential (section 6), and don't hoist loads across stores to
  the same table.
- **`each` alive** is read once before the loop, and a `for` count once before its loop.
- **Hash:** field-by-field from the IR description (no struct memcpy, since in-memory padding/bool layout is yours),
  with -0.0 canonicalisation for every f32, including dead slots and event records.
- **Zig:** `mut` tells you `var` vs `const`. Every local and parameter is used. Shift amounts are `u5`, use
  `@intFromFloat` (in range) and `@floatFromInt`.
- **C#:** `unchecked` arithmetic (the default; don't enable `CheckForOverflowUnderflow`), and `(float)uint` is exact
  round-to-nearest-even on .NET Core 3.0+.
