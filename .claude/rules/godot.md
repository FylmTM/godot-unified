---
paths:
  - "games/**/*.gd"
  - "games/**/*.tscn"
  - "games/**/*.tres"
  - "games/**/*.gdshader"
  - "games/**/project.godot"
  - "games/**/*.gdextension"
  - "tests/godot*/**"
---

# Editing a Godot project as text

- Godot 4.7, standard (non-.NET) build. Check APIs against 4.x docs, not Godot 3: training data mixes them.
- Edit `.gd`, `.tscn`, `.tres` and `project.godot` as text. Hand-written scenes stay minimal: `[gd_scene format=3]`,
  `ext_resource` by `path` with a short `id`, no `uid=`, and no properties set to their default values.
- GDScript is typed: every declaration has a type (`untyped_declaration` is a warning, and `game validate` fails on
  warnings).
- Godot writes a `.uid` file next to every new script and shader: commit it with the file.
- Never edit `.godot/` or `.import` files; they are Godot's cache.
- GDScript belongs to the view layer only. It reads the sim and never writes it: input and commands are the only way
  in. Anything performance-critical or shared across games is Odin.
- After editing a level scene in `game/levels/`, run `python tools/dev.py game export-level <game>` and commit both
  files.
- After any change here, `python tools/dev.py game validate <game>` (the `godot-game` skill has the rest of the loop).
