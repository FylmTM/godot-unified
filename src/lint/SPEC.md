# lint

Status: signed off 2026-11-18 (#331)

The determinism lint (AGENTS.md "Deterministic simulation") as a library, so a game outside this repo lints its
simulation the way unified lints its own. Test-side code: it imports `core:testing` and runs inside `odin test`. A
token scan: it can't prove determinism (end-to-end suites and reference runs do), it stops the known traps from
creeping in.

## API

```odin
import "unified:lint"

@(test)
determinism_lint :: proc(t: ^testing.T) {
	lint.check_game(t, #directory + "/..")   // a game's simulation/ by its layout; one failure per violation
	// the game's own deterministic packages, as its sim imports them: extra_imports = {"../grid", "../ai/"}
}

Kind :: enum {Host, Realtime, Tick}
Rule { pkg, dir, kind, imports, bans, allow_globals }
sim_rule(pkg, dir, extra_imports) -> Rule      // a game's sim package
check(t, Rule)                                 // lint every .odin file under rule.dir
check_game(t, simulation_dir, extra_imports) -> sim dirs
scan(Rule, name, src) -> []string              // one line per violation (imports, identifiers, constructs)
scan_globals(Rule, name, src) -> []string      // Tick packages: package-level variables not @(rodata)
TICK_IMPORTS, GAME_TICK_IMPORTS, GAME_IMPORTS, SIM_IDENTS, FLOAT_TRAPS, B3, BOX3D
```

## Rules

- **A rule's kind says what is banned:**
  - `Tick`, code inside a tick: only the rule's `imports` (Odin's own included); none of `SIM_IDENTS` (f64 and f16
    types, fused multiply-add, quaternion and complex types, cycle counters, random generators, `static` and
    `thread_local`: state outside the block, `ODIN_OS`, `ODIN_ARCH`, `ODIN_DEBUG`: a sim per platform or build); no
    `matrix`, `foreign`, `map`, `---` (uninitialised memory), `#config`, or `x := 1.5` (an untyped float literal is
    f64); every package-level variable is `@(rodata)` or in `allow_globals`, each with a reason where listed (a
    write during a tick would be state outside the block).
  - `Realtime`, real-time code beside the sim (netcode, headless): Odin's own packages and the rule's `imports`, but
    not `core:math` (`core:math/bits` is fine), `FLOAT_TRAPS` or `matrix`.
  - `Host`, code that never feeds back into the sim: Odin's own packages and the rule's `imports`.
- **Imports** match as written: an entry ending in `/` matches what is under it, one ending in `:` a whole collection
  (`unified:`, `system:` for a `foreign import`). A relative path is the importer's own neighbour, so a game's
  `../sim` is not `unified:sim` and must be listed. `bans` (`BOX3D`) apply beside the imports, to what is under them
  too.
- **A game's sim package** (`sim_rule`) is a Tick package importing `GAME_TICK_IMPORTS` (`unified:sim`, `physics`,
  `level`, `dmath`; not `unified:b3`, which is physics' own) plus its `extra_imports`: a game lists
  `unified:wire`, `base:intrinsics` or `core:math/bits` there to use them.
- **A game's layout** (`check_game`): `headless/` is Realtime, `extension/` and `tests/` are Host, all three importing
  `GAME_IMPORTS` (unified and the game's own packages) but not Box3D (`BOX3D`: `unified:b3` and the `box3d:`
  bindings); every other directory is a sim package. A new sim package is linted without editing a list.
- **What it can't see:** types. A float-to-int conversion goes through `dmath.to_i32_clamped` by convention, and
  `x := 1.5 * y` is f64 until a cast. Address-dependent values are left to the end-to-end suites' desync detection.
- `tests/lint` holds unified's import graph: every package of `src/` has a rule (one line: its kind and the unified
  packages it may import; a package without one fails), and every game under `games/` is linted with `check_game`.
