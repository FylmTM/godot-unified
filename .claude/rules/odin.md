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
  `sim.hash_bytes`, ...), or in a package of their own (`unified:headless/cli`: the game suites import
  `unified:headless` and never instantiate the CLI modes).
- A struct field named like an imported package shadows it inside generic code (`Client.sim`): netcode's
  `client.odin` imports `sim` as `usim`.
- `core:hash/xxhash`'s streaming XXH3 (`XXH3_64_update/digest`) returns wrong digests for some input lengths (e.g.
  100,097 bytes), and is still deterministic, so it's easy to miss. Hash one-shot with `XXH3_64_default`
  (upstream fix: odin-lang/Odin#8257).
- `foreign import` takes no absolute path and no `#config` path; relative paths work (`src/README.md`, Box3D binding).
- Windows links the static CRT (`/defaultlib:libcmt`): C libraries we build (Box3D, Dear ImGui) use `/MT` to match.
- Windows sleeps round to ~15.6 ms without `timeBeginPeriod(1)` (headless startup calls it), and UDP `recvfrom`
  reports WSAECONNRESET after an ICMP port-unreachable: skip it, it isn't "no data".
- Never edit `*.gen.odin`: `python tools/dev.py gen` writes them. `.odin` files are formatted with odinfmt on every
  edit (a hook); `python tools/dev.py fmt --check` is what CI runs.
