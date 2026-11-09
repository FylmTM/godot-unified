# godot_host and gdext

Decided autonomously 2026-11-09, pending developer review.

`src/gdext` holds the Odin bindings for Godot's GDExtension API. `src/godot_host` is everything that touches
Godot for a game built on `unified`. Each game has a thin extension (`games/<game>/simulation/extension`) that
installs its sim and its glue.

## gdext

- **Generated code.** `python tools/dev.py gen` (~1 s fresh, cached by input hash) turns the committed
  `src/gdext/api/{extension_api,gdextension_interface}.json` (dumped from 4.7.2) and `bindings.txt` into
  git-ignored `gdi/gdi.gen.odin` (the C interface) and `api.gen.odin` (layouts, enums, typed wrappers
  `Class_method`). No Godot is needed to build.
- **Wrappers.** They use ptrcall. Strings in and out are Odin `string`s. Returns of RefCounted classes are
  `Ref(T)`, which the caller owns (`unref`). Vararg methods take `..any`. Debug builds check the main thread.
- **Extension classes.** `Class{name, parent, size, init, fini, notification, ready, process,
  physics_process, input, unhandled_input, runtime_only}`, then:
  - `bind_method(cls, name, proc(self: ^T, a: A, b: B) -> R, {"a", "b"})`, with 0–3 arguments and one typed
    trampoline per signature;
  - `bind_property(cls, name, get, set, hint)`;
  - `bind_signal(cls, name, {"arg", type}...)`;
  - `bind_script_virtual`, `emit_signal`, `call_script`;
  - `callable_create(proc, user, owner)`, `connect`;
  - `sn("name")` returns interned StringNames.
- **Value conversions.** `to_variant`, `from_variant`, `variant_from_any`, and the `dict_*` / `array_*` helpers.
- **Tests.** `python tools/dev.py godot-test` (1.7 s) runs a test class under headless Godot covering every
  feature above, plus a dev UI smoke test.

## godot_host API

```odin
godot_host.install(&GAME, glue)            // sim.Game(S, I, W, P) + Glue(S, I, W)
godot_host.set_transport(&transport)       // optional: online play (EOS...), never imported by godot_host
return godot_host.entry(gpa, lib, init)    // the extension's entry symbol
Glue { scene_kinds, bulk_kinds, actions: {move: [4]string, buttons: []string},
       extract(cur, prev, world, ^Frame), sample(Actions, slot, tick, ^S) -> I, scripted(seed, slot, tick, ^S) -> I,
       hud(^Frame, names, ^Dictionary), compat }
Frame { tick, verified, due_us, local_slot, net, scene: [256]Scene_Item, bulk: [4096]Bulk_Item, hud: [4096]u8 }
```

GDScript sees contract v0:

- **`UnifiedSession`**
  - methods: `start_single`, `host_online`, `join_online(code)`, `join_direct(addr)`, `leave`,
    `choose_levelup(n)`, `hud()`;
  - signals: `status_changed`, `lobby_code`, `sim_event`;
  - added for the game client: `view_root`, `host_direct(port)`, `set_player_name`, `get_status`,
    `is_running`, `get_tick`, `toggle_devui`.
- **`SimView`** (Node3D: `kind`, `entity`, `slot`, script virtuals `_sim_update(position, yaw, alpha)` and
  `_sim_event(kind, data)`).
- **`SimBulkView`** (MultiMeshInstance3D: `kind`).

Plain Node3D / MultiMeshInstance3D scene roots with the same script properties work too. Scripts run without
the extension that way, and the host uses `Object.set`/`call`.

## How it works

- **Threads.** A session (single player = a host with no remote links; host; join) runs netcode's
  `host_step`/`client_step` on its own thread. On macOS that thread uses the real-time (time-constraint) class
  and sleeps until the next deadline. While a session runs, the process opts out of background throttling
  (often a hosting player's game is in the background): on macOS, a user-initiated, latency-critical
  NSProcessInfo activity (no App Nap, no idle system sleep); on Windows, `timeBeginPeriod(1)` (Sleep rounds
  up to 15.6 ms without it) plus opting out of power throttling, since Windows 11 ignores a minimised
  process's timer request. The netcode hooks run there:
  - `sample` reads the input atomics, or scripted input in headless checks;
  - `frame` feeds the predicted ticks' events to the tracker and publishes a Frame (`extract`);
  - `verified` confirms or cancels events;
  - `status` posts the status.

  Godot is only called from the main thread.
- **Main thread.** `UnifiedSession._process` runs at priority −1000, before every other node:
  1. samples the InputMap actions into atomics (button presses accumulate until a tick takes them);
  2. takes the newest Frame;
  3. updates the scene views: spawn by key into `view_root`, push the poses of ticks P−1 and P into each view's
     `view.Track`, sample with alpha and smoothing, set position and quaternion, call `_sim_update`;
  4. writes each bulk view's MultiMesh buffer in one `set_buffer` (interpolated, stride from the MultiMesh flags);
  5. routes events: predicted ones and cancels go to `_sim_event` on the entity's or slot's view, verified ones
     go to the `sim_event` signal;
  6. draws the dev UI.
- **Leave, then Host or Join.** `leave` asks the session to end; it says goodbye on its thread (a client's Leave
  is acked within ~0.5 s, a host waits up to 3 s for its peers' acks). A start during the goodbye is accepted:
  it waits and starts as soon as the old session is gone. The goodbye is cut to 1 s, and the old session's
  last statuses and events are dropped. A `leave` before that cancels the waiting start.
- **Editor.** Classes register at SCENE level and nothing runs in the editor. Hot reload is editor-only.
  `deinitialize` stops the session thread, then calls the transport's optional `shutdown` (the survivor
  releases EOS there: left initialized, the SDK crashed in its own threads at exit, ~2 exits in 3). macOS dev builds are versioned files behind a symlink, because dyld
  never unloads an Odin dylib (thread-locals), so a same-path reload would keep the old code.
- **Commands.** `python tools/dev.py game build|run|editor|headless|editor-check|session-check <game>`.
  `headless` runs a scripted single-player session under headless Godot and compares its checksums with the
  offline headless binary's. `session-check` (`game/tools/session_check.gd`) checks starting during a goodbye.

## Open

- A netsim panel wired into the live client link.
- F3 extras: snapshot, input log, net stats.
- Typed `SimFrame` reads by reflection path for scripts.
- Pooling scene views.
- Real-time thread classes on Windows and Linux (to be measured).
- Running-game hot reload (needs the shim design).
