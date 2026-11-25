---
paths:
  - "**/*.odin"
---

# Odin pitfalls in this repo

- The traps a game meets too (tests in their own package, package names, `-vet` and imports used only in generic
  code, a field shadowing a package, a range's end, `*.gen.odin`): `docs/agent-guide.md`, Odin traps. Read them.
  Here, tests live in `tests/<module>/`; `unified:headless/modes` is a package of its own so the game suites, which
  import `unified:headless`, never instantiate the CLI modes; netcode's `client.odin` imports `sim` as `usim`
  (`Client.sim`).
- `core:hash/xxhash`'s streaming XXH3 (`XXH3_64_update/digest`) returns wrong digests for some input lengths (e.g.
  100,097 bytes), and is still deterministic, so it's easy to miss. Hash one-shot with `XXH3_64_default`
  (upstream fix: odin-lang/Odin#8257).
- `foreign import` takes no absolute path and no `#config` path; relative paths work (the `box3d:` bindings).
- Windows sleeps round to ~15.6 ms without `timeBeginPeriod(1)` (headless startup calls it), and UDP `recvfrom`
  reports WSAECONNRESET after an ICMP port-unreachable: skip it, it isn't "no data".

# Names

- Descriptive names: a reader knows what a name holds without finding its declaration. Whole words or the usual
  short forms (`pos`, `vel`, `dt`, `id`, `ok`, `err`, `count`, `index`), not private abbreviations (`sh`, `tk`,
  `cnt`).
- No one-letter locals or parameters, except loop indices (`i`, `j`, `k`) and the letters of a formula
  (`x`, `y`, `z` components, `a`, `b`, `t` in `lerp(a, b, t)`), a test's `t: ^testing.T` (Odin's convention), and
  a sim's `t: ^Tick` and a glue's `f: ^Frame`: read their fields in place (`t.state.balls`), no local copies
  (`state := t.state`). Library code takes the style when it is touched.
- Type parameters name their role: `$State, $Input, $World, $PLAYERS`; `$G` is the game type (a `sim.Game`). Otherwise one
  letter only for a container's element and size (`Table($T, $N)`, `Queue($T, $N)`, `Handle($T)`).
- `player` is a `sim.Player` handle (a session member, the person) everywhere: fields, parameters, events, views;
  `players` the State's `sim.Players`. `slot` is the input index `0 ..< PLAYERS` a player holds while present
  (`Inputs`, commands, scripted input, the relay's seats). A ring's or a table's own slot is a `ring_slot` or a
  table index.
