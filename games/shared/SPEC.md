# The demo games' shared Godot code

Decided autonomously 2026-11-14 (#101, #74); its home signed off in the review of #147 (demo-games code, not the
library: `src/` is library only).

What the Godot projects of this repo's demo games (survivor, friendslop, drift) share, kept once here and mirrored
by `uni` into each game as `res://addons/shared/` (git-ignored there). A game uses it when its `project.godot` names
`res://addons/shared/` (its autoloads, its bus layout). `games/shared` is not a game: `uni` and the lint treat only
a directory with `project.godot` and `simulation/` as one.

## How a game picks it up

- **The mirror** (`src/cli/shared_godot.odin`). Godot loads nothing from outside a project, so before every Godot
  run (`ensure_imported`, `write_extension_list`: every command that runs Godot, `release` too) `uni` copies the
  project's `games/shared` into `<game>/addons/shared/` (this file stays behind): new and changed files copied,
  removed ones deleted. The copy is read-only by convention: one edited in place (the Godot editor saves there)
  stops the run with a message, since the change belongs here. A `.uid` file Godot writes for a new script here is
  copied back, so it is committed and every game shares the UID.
- **Tool scripts.** `uni tool <game> <name>` and the godot suite run `game/tools/<name>.gd`, else `tools/<name>.gd`
  here. A game adds its own steps by extending the shared script in `game/tools/`.
- **Exports** leave `addons/shared/tools/` out (each game's `export_presets.cfg`).
- **Conventions** the shared code relies on: the menu scene at `res://game/ui/main_menu.tscn` (root `MainMenu`, the
  shared menu instanced as `Menu`), the play scene at `res://game/arena/arena.tscn` (root `Arena`, with `Views`,
  `HUD` whose `Root` control holds the session panel and controls list, and the shared `PauseMenu`); the input
  actions `menu`, `toggle_devui`, `ui_accept`, `ui_cancel` and the audio buses Master and SFX.

## API

Autoloads (a game registers its own script, extending the shared one, or the shared one itself):

- **`UnifiedGame`** (`autoload/game.gd`, the `Game` autoload): the app's flow, MENU -> CONNECTING -> PLAYING, owning
  the session. Flow: `play_single`, `host_online`, `host_direct(port)`, `join_online(code)`, `join_direct(address)`,
  `leave_to_menu(error)`, `quit_app(exit_code)`, `send_command(name, args)`. State: `session`, `is_mock`, `flow`,
  `mode`, `status`, `status_detail`, `lobby_code`, `lan_port`, `lan_address`, `last_error`, `hud`, `constants`,
  `using_pad`. Helpers: `local_player()` (the index), `player_info(player)`, `local_player_info()`, `present_players()`,
  `player_name(info)`,
  `hint(keys, pad)`, `rumble`, `clipboard_get/set`, `copy_with_feedback`. Signals: `flow_changed`,
  `status_changed`, `lobby_code_changed`, `input_device_changed`. Virtual: `_create_session()` (a game with a
  GDScript stand-in returns it and sets `is_mock`).
- **`UnifiedSettings`** (`autoload/settings.gd`, `Settings`): `get_value`, `set_value(key, v, persist)`, `save`,
  `has`, signal `changed`. The shared keys (`DEFAULTS`: volumes, window mode, vsync, show FPS, player name); a game
  adds its own in `_game_keys()`, among them the standard optional ones (`OPTIONAL`: `render_scale`,
  `mouse_sensitivity`, `invert_y`), which the settings panel shows when present.
- **`UnifiedSfx`** (`autoload/sfx.gd`, `Sfx`): `play(name, volume_db, pitch)`; `click` and `gem` built in; a game
  adds its sounds in `_add_sounds()` with `add(name, stream, min_gap)`, `tone()`, `arpeggio()`.

UI (`ui/`): `UiTheme` (the theme and palette, installed by `Game`), `MainMenu` (`main_menu.tscn`, exports `title`
and `tagline`), `pause_menu.tscn`, `connect_overlay.tscn` (shown by `Game` while connecting), `SettingsPanel`,
`SessionPanel` and `ControlsPanel` (a HUD's top-right session panel and bottom-right controls list: the game passes
rows and bindings, the panel owns the look), `OrbitCamera` (a 3D menu backdrop). Views: `GameView` (`views/`, a
GDScript base for 3D scene views with the native `SimView`'s properties), `SimEvent` (`views/sim_event.gd`: the
event states `EMITTED`, `CONFIRMED`, `CANCELLED`, the native `UnifiedSession.EVENT_*` values, which `Game` checks at
start; scripts use them so they also run on a GDScript stand-in session). Audio: `audio/bus_layout.tres`.

Tools (`tools/`): `UnifiedTool` (the base of every tool script: `_run()`, `step`, `expect`, `fail`, `finish`, waits,
real input events, screenshots, `--frames` with `UnifiedFrameLog`, errors through `UnifiedLogCapture`),
`UnifiedValidate` (`validate`, with the game's `_check_contract()`), `UnifiedUiWalk` (`ui_walk`, with
`_walk_play()` and `_walk_online()`), `UnifiedCoop` (`coop`, with `_host_play()`, `_join_play()`, `_playing()`).
A tool script is compiled before the autoloads exist, so it never names a script that uses them: it reaches the game
through its untyped `game` and the scene tree.

## Flags every game accepts

After `--`: `--no-settings` (tools: defaults, nothing saved, no window changes), `--smoke-test` (start single
player at boot; `uni release`), `--mock` (a game with a GDScript stand-in session uses it; others ignore it), plus
the native session's own (`--autostart`, `--scripted`, `--join`, ...: `src/godot_host`).

## How it works

- **Quitting** goes through `Game.quit_app()` (the menus, the window's close button, every tool): the session ends
  (no event starts a sound any more), every AudioStreamPlayer (2D, 3D) in the tree stops, and the quit waits (at
  most 1 s) until the AudioServer has freed their playbacks: one it still holds at exit is reported as leaked.
- **`Game.hud` is current for event handlers.** The session emits its events before `Game` refreshes `hud` in its
  `_process`; `Game` connects to the session first and refreshes `hud` on the frame's first event, so a handler
  never compares against the previous frame's (a stale `local_player` of -1 made single player announce its own join).
- **Play scene** (#89): the main menu loads the play scene on a worker thread
  (`ResourceLoader.load_threaded_request`) once it is on screen, so its shaders compile in the background, and
  collects it on leaving. In Godot 4.7.2 a resource a script first loads with `preload()` on a worker thread is
  reported as leaked at exit (one object per resource), even when the threaded load is collected; the same script
  with `load()` doesn't leak, nor does a project without the threaded load (reproduced without unified: a menu that
  requests a scene whose script preloads a texture). So the scripts the play scene loads use `load()`, never
  `preload()`; the shared `validate` fails on a `preload(` in any script the play scene depends on.

## Library candidates

What `uni` itself drives for every game lives here for now and may belong in the library later: `tools/tool.gd`
(`UnifiedTool`, with `log_capture.gd` and `frame_log.gd`), `tools/validate.gd`, `tools/ui_walk.gd` and
`tools/coop.gd` (the godot suite's `validate` and `walk` steps and `uni coop` fall back to them).
