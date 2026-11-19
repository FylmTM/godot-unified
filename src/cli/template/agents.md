## unified

This game is built on unified, the `unified/` submodule: a deterministic simulation in Odin with rollback netcode,
and Godot as its view. Every doc below is at the pinned version. These rules always apply:

- **The simulation is deterministic.** f32 only; no `core:math` transcendentals (`dmath`'s), no builtin `min`, `max`
  or `clamp` (`dmath`'s), no `matrix` types, no wall-clock time, no unordered iteration that affects state, no
  pointers, slices or maps in the state, no NaN in it. The determinism lint (`./uni test`) and `./uni vet` enforce
  what they can see: fix what they name, never work around them.
- **The view never writes to the sim.** Godot reads the state and the events; input and commands are the only way in.
- **Bump `Game.version`** with every rule or tuning change, and re-pin the reference run only after a change meant to
  compute differently.
- **Everything runs through `./uni`** (`uni.cmd` on Windows): `./uni help`, `./uni <command> -h`. Before handing
  work back: `./uni verify`.

Where to read:

- `unified/README.md`: what unified is and why; `unified/docs/getting-started.md`: the toolchain and first commands.
- `unified/examples/minimal_3d/GUIDE.md`: writing gameplay that survives rollback, and the gotchas by symptom.
- `./uni doc` lists the packages, `./uni doc <pkg>` prints one's API; `unified/src/<pkg>/README.md`: how it works.
- `.claude/skills/`: unified's skills for Claude Code (`unified.txt` lists them), the same procedures for any agent:
  the godot suite and `uni drive`, changing what the sim computes, finding a desync.
