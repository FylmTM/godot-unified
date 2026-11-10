# Godot API dump

`extension_api.json` and `gdextension_interface.json` are Godot's own description of its GDExtension API, dumped from
the baseline Godot (4.7) and committed on purpose: builds, `vet` and CI generate the bindings (`python tools/dev.py
gen`) without a Godot binary, and the baseline API is pinned. They are generated files (`.gitattributes` marks them
`linguist-generated` and `-diff`); never edit them.

Regenerate them only when the baseline Godot version changes: the `upgrade-dependency` skill (`.claude/skills/`).
