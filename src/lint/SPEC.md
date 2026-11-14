# lint

Signed off by the developer 2026-11-09.

The determinism lint (AGENTS.md "Deterministic simulation") as a library, so a game outside this repo lints its
sim package the way unified lints its own. Test-side code: it imports `core:testing` and runs inside `odin test`.
A token scan, a few ms: it can't prove determinism (end-to-end suites and reference runs do), it stops the known
traps from creeping in.

## API

```odin
import "unified:lint"

// in a game's sim tests (e.g. simulation/tests/lint_test.odin):
@(test)
sim_is_deterministic :: proc(t: ^testing.T) {
	lint.check_sim_package(t, #directory + "/../mygame")   // one failure per violation
	// the game's own deterministic packages, as its sim imports them: extra_imports = {"../grid", "../ai/"}
}
// or the whole simulation/ by its layout (headless/, extension/, tests/, and every other directory a sim package):
lint.check_game(t, #directory + "/..")

Rule { pkg, dir, only_imports, ban_imports, allow_imports, ban_idents, ban_matrix, strict, tick, allow_globals }
sim_rule(pkg, dir, extra_imports) -> Rule      // what check_sim_package applies
check(t, Rule)                                 // lint every .odin file under rule.dir
check_game(t, simulation_dir, extra_imports) -> sim dirs   // a game's simulation/ by its layout (2026-11-10)
scan(Rule, name, src) -> []string              // one line per violation (imports, identifiers, matrix, strict)
scan_globals(Rule, name, src) -> []string      // tick packages: package-level variables not @(rodata)
TICK_IMPORTS, SIM_IDENTS, FLOAT_TRAPS, MATH, MATH_OK
```

## Rules

- **Sim rule** (`sim_rule`): imports only `TICK_IMPORTS` (`unified:sim`, `physics`, `level`, `dmath`, `box3d`,
  `wire`, `base:intrinsics`, `core:math/bits`) plus `extra_imports` (exact, or a prefix ending in `/`); none of
  `SIM_IDENTS` (f64/f16 types, fused multiply-add, quaternion/complex types, cycle counters, random generators);
  no `matrix`; strict: no `foreign`, no `map`, no `x := 1.5` (an untyped float literal is f64); tick: every
  package-level variable is `@(rodata)` or listed in `allow_globals` (a write during a tick would be state outside
  the block: not rolled back, not hashed). unified's own tick packages name their exceptions with a reason
  (physics' `world_mutex`); `sim` and `physics` also import what the harness needs (RTTI, hashing, files, a mutex).
- **What it can't see:** types. A float-to-int conversion goes through `dmath.to_i32_clamped` by convention (x86
  and ARM convert out-of-range floats differently).
- **Game layout** (`check_game`): `headless/` gets the real-time rule (off `core:math`, no float traps),
  `extension/` and `tests/` nothing (host and test code), every other directory the sim rule. A new sim package
  is linted without editing a list.
- `tests/lint` holds unified's import graph: one rule per package of `src/` (a package without one fails), and
  lints every game under `games/` with `check_game` (and checks `tests/tests.odin` imports its tests).
