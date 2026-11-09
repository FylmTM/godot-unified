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

Rule { pkg, dir, only_imports, ban_imports, allow_imports, ban_idents, ban_matrix, strict, tick, allow_globals }
sim_rule(pkg, dir, extra_imports) -> Rule      // what check_sim_package applies
check(t, Rule)                                 // lint every .odin file under rule.dir
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
  the block: not rolled back, not hashed).
- `tests/lint` holds unified's import graph: one rule per package of `src/` and of each game's `simulation/`
  (a package without one fails), and lints the in-repo games' sim packages through `check_sim_package`.
