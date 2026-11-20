---
paths:
  - "examples/**/*.gd"
  - "examples/**/*.tscn"
  - "examples/**/*.tres"
  - "examples/**/*.gdshader"
  - "examples/**/project.godot"
  - "examples/**/*.gdextension"
  - "tests/godot*/**"
---

# Editing a Godot project as text

- Godot 4 (the version pinned in `pins.cfg`), standard (non-.NET) build. Check APIs against 4.x docs, not Godot 3: training data mixes them.
- Edit `.gd`, `.tscn`, `.tres` and `project.godot` as text, or make them with a throwaway script through Godot's
  API: the `unified-godot-authoring` skill (the text that works, levels, input maps, UI).
- GDScript is typed: every declaration has a type (the games make `untyped_declaration` an error, and every
  tool-script run fails on warnings).
- Godot writes a `.uid` file next to every new script and shader: in a game, commit it with the file. The test
  projects (`tests/godot*`) git-ignore them: nothing there refers to a file by UID.
- Never edit `.godot/` or `.import` files; they are Godot's cache.
- A game's `addons/unified/` is a copy of `src/godot/tools` (the library's tool scripts), refreshed by `uni` before
  every run: change it there, never in a game. Everything else in a game is the game's own.
- Static typing per Godot's style guide, members in its order (signals, enums, constants, exports, vars,
  `@onready` vars, virtuals, public, private).
- A tool script (`-s`) is compiled before the autoloads exist: it never names a script that uses `Game`,
  `Settings` or `Sfx` (reach them through the scene tree). Scripts the play scene loads never `preload()`.
- Sim data is typed end to end: an event handler dispatches by class (`if event is EventRockHit: var hit := event
  as EventRockHit`) with `state: UnifiedSession.EventState`, never on `event.kind`; nested data is read as its class
  (`for p: DataHudPlayer in Unified.data.hud.players`), never with `.get("field")`.
- GDScript belongs to the view layer only. It reads the sim and never writes it: input and commands are the only way
  in. Anything performance-critical is Odin.
- After editing a level scene in `game/levels/`, run `./uni bake <game>` and commit both files.
- After any change here, `./uni test <game> --suite godot --only validate` (the `unified-godot` skill has the rest of
  the loop).
