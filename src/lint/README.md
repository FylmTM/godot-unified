# `unified:lint`: the determinism lint

The rules of a deterministic simulation (AGENTS.md, Deterministic simulation; `src/dmath/README.md`) as a library, so
a game outside this repo lints its simulation the way unified lints its own: one `check_game` call from a test of its
sim tests. Test-side code: it imports `core:testing` and runs inside `odin test`. A token scan, so it can't prove
determinism (end-to-end suites and reference runs do, `src/headless/README.md`); it stops the known traps from
creeping in.

`tests/lint` holds unified's own import graph: every package of `src/` has a rule there (its kind and the unified
packages it may import; a package without one fails), and every game under `examples/` is linted with `check_game`.

## Rules

- **A rule's kind says what is banned** (`Kind`): `Tick` for code inside a tick (only its listed imports, banned
  identifiers, builtins and constructs, no mutable package-level state), `Realtime` for real-time code beside the sim
  (no `core:math`, no float traps), `Host` for code that never feeds back into the sim.
- **Imports match as written.** An entry ending in `/` matches what is under it, one ending in `:` a whole collection
  (`unified:`, `system:` for a `foreign import`). A relative path is the importer's own neighbour, so a game's `../sim`
  is not `unified:sim` and must be listed itself. `bans` apply beside the imports, to what is under them too.
- **A game's layout is its rule table** (`check_game`): `headless/`, `extension/` and `tests/` are known, and every
  other directory is a sim package (`sim_rule`), so a new sim package is linted without editing a list. No game code
  imports Box3D's bindings: Box3D is physics' (`src/physics/README.md`, The boundary).
- **Allowances are by name, with a reason where listed.** A Tick rule may read named fields the bans list
  (`allow_fields`: the harness fills `Inputs.replaced`) and a named `#config` (`allow_config`: the harness's dev UI
  switch, `sim.DEV`); everything else of the kind stays banned.
- **What it can't see: types.** A float-to-int conversion goes through `dmath.to_i32_clamped` by convention, and
  `x := 1.5 * y` is f64 until a cast. `dmath`'s `min`, `max` and `clamp` take integers too, since the lint bans the
  builtins whatever the type. Address-dependent values are left to the end-to-end suites' desync detection.
