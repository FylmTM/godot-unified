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

- The rules for a game's files (typed GDScript, `.uid` and `.import` files, `.godot/`, tool scripts and autoloads,
  typed sim data, what GDScript may do) are the `unified-godot-authoring` skill's, Rules for the files: read them
  before editing here. Making scenes, levels, input maps and UI without the editor is the same skill.
- The test projects (`tests/godot*`) git-ignore their `.uid` files: nothing there refers to a file by UID.
- `res://unified/tools_godot/` is a git-ignored mirror of `tools_godot/` in unified's own projects: change the
  source, never the mirror (`src/cli/README.md`, Tool scripts).
- After any change here, `./uni test <game> --suite godot --only validate` (the `unified-godot` skill has the rest of
  the loop).
