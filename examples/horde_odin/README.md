# horde_odin: everything in Odin

[examples/horde](../horde/)'s game (its sim, shared) with everything the player sees drawn in Odin, immediate mode
(`src/godot/immediate.odin`, experimental): the world and the effects as in [horde_hybrid](../horde_hybrid/), and the
HUD and level-up cards from the State itself (`hud.odin`: no session data). The only GDScript is the measurement probe
and the script that starts the session. Part of the render experiment: horde's README says what each example
compares.

The UI two ways, chosen with `-- --ui`:

- **immediate** (the default, `ui_immediate.odin`): text, bars and cards drawn on a screen layer every frame, the
  mouse and keys read in Odin, a pick sent with `godot.send`.
- **controls** (`ui_controls.odin`): Godot Controls (labels, bars, buttons) made once and updated from Odin, a text
  set only when it changes, the buttons polled. The library has no Odin API for Controls, so this file imports
  `unified:gdext` itself, the one example file that does.

**Sprites** (`-- --sprites`, `sprites.odin`): the enemies as animated pixel-art sprites from `game/art/enemies.png`
(made by `game/tools/make_enemy_sheet.gd`), one sprite batch for all of them (`godot.sprite_batch_create`). Each
enemy's clip (spawning, hurt, walking, idle) comes from the State and its frame from a clock in the State, the tick it
spawned, so a rollback replays the same frame; `--y-sort` draws them from the top of the screen down
(`godot.batch_y_sort`).
