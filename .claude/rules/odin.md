---
paths:
  - "**/*.odin"
---

# Odin pitfalls in this repo

- `_test.odin` files are compiled into normal builds (and pull in `core:testing`), so tests live in their own packages
  (`tests/<module>/`, a game's `simulation/tests/`), never next to the code.
- Package names must be unique program-wide and must avoid Odin's own (`net`, `log`, `bytes`, ...): `core:net` is
  package `net`, which is why ours is `netcode`.
- Generic procs only type-check when instantiated, so `-vet` flags an import used only inside them as unused in a
  package that doesn't call them. Keep such imports behind small non-generic helpers (`sim.write_file`,
  `sim.hash_bytes`, ...), or in a package of their own (`unified:headless/modes`: the game suites import
  `unified:headless` and never instantiate the CLI modes).
- A struct field named like an imported package shadows it inside generic code (`Client.sim`): netcode's
  `client.odin` imports `sim` as `usim`.
- `core:hash/xxhash`'s streaming XXH3 (`XXH3_64_update/digest`) returns wrong digests for some input lengths (e.g.
  100,097 bytes), and is still deterministic, so it's easy to miss. Hash one-shot with `XXH3_64_default`
  (upstream fix: odin-lang/Odin#8257).
- `foreign import` takes no absolute path and no `#config` path; relative paths work (the `box3d:` bindings).
- Windows sleeps round to ~15.6 ms without `timeBeginPeriod(1)` (headless startup calls it), and UDP `recvfrom`
  reports WSAECONNRESET after an ICMP port-unreachable: skip it, it isn't "no data".
- Never edit `*.gen.odin`: `uni godot-gen` writes them. `.odin` files are formatted with odinfmt on every edit (a
  hook); `uni fmt --check` is what CI runs.

# Names

- Descriptive names: a reader knows what a name holds without finding its declaration. Whole words or the usual
  short forms (`pos`, `vel`, `dt`, `id`, `ok`, `err`, `count`, `index`), not private abbreviations (`sh`, `tk`,
  `cnt`).
- No one-letter locals or parameters, except loop indices (`i`, `j`, `k`) and the letters of a formula
  (`x`, `y`, `z` components, `a`, `b`, `t` in `lerp(a, b, t)`), and a test's `t: ^testing.T` (Odin's convention).
- Type parameters name their role: `$State, $Input, $World, $PLAYERS`. One letter only for a container's element
  and size (`Table($T, $N)`, `Queue($T, $N)`, `Handle($T)`).
- The player index (a seat, `0 ..< PLAYERS`) is `player` everywhere: fields, parameters, `NO_PLAYER`. `slot` means
  only a ring slot or a table slot.
