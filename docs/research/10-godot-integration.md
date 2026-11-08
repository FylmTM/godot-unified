# 10: Godot integration, GDExtension vs LibGodot

Researched 2026-11-08 against Godot 4.7.2 (source tag `4.7.2-stable`, `ed1daf0bf`) and the open PRs as of that day.
**(unverified)** marks claims I couldn't confirm from source code, a primary doc or my own run. "Spike" means I
built and ran it on this Mac (M4 Pro, 14 cores). The scratch code is outside the repo, and no repo files were changed.

## TL;DR

**Keep GDExtension as the integration route (confidence: high, about 80%). Keep LibGodot as a cheap,
reversible option for later, mostly for tooling.** The key finding is that the two routes share one seam. LibGodot's
host hands Godot an ordinary `GDExtensionInitializationFunction`, so **the prototype's `bench_init` ran unchanged as
a LibGodot host**. The same sim hash came out, the same screenshot, about 80 lines of Odin host code, and about an
hour of work including building Godot. Choosing GDExtension now doesn't close the LibGodot door.

LibGodot in 4.6/4.7 is only "part 1": create, start, iterate, destroy, in Godot's own window or headless. Embedding
into a host window, restart, log hooks and early extension registration are all still open PRs. It doesn't give us
what we'd want it for (our own main thread, control of frame timing, several instances, offscreen rendering). It does
cost us a Godot source build per platform and config, and it has several sharp edges (below).

## 1. LibGodot today

**What shipped.** [PR #110863](https://github.com/godotengine/godot/pull/110863) (Migeran, merged 2025-10-08,
milestone 4.6) is "Part 1" of the original [#90510](https://github.com/godotengine/godot/pull/90510). It adds the
`GodotInstance` class, two C entry points, and library builds for Linux, Windows and macOS. Nothing LibGodot-specific
was added in 4.7. The 4.8 milestone has cleanup fixes ([#123717](https://github.com/godotengine/godot/pull/123717))
and stricter main-thread rules ([#121161](https://github.com/godotengine/godot/pull/121161)).

**C API** ([`libgodot.h`](https://github.com/godotengine/godot/blob/4.7.2-stable/core/extension/libgodot.h)):

```c
GDExtensionObjectPtr libgodot_create_godot_instance(int argc, char *argv[], GDExtensionInitializationFunction init);
void                 libgodot_destroy_godot_instance(GDExtensionObjectPtr instance);
```

Everything else goes through the normal GDExtension API. `GodotInstance` is an ordinary class in
`extension_api.json` (our dump already has it), with `start`, `is_started`, `iteration`, `focus_in`/`focus_out` and
`pause`/`resume` ([class ref](https://docs.godotengine.org/en/stable/classes/class_godotinstance.html)). In the
source ([`godot_instance.cpp`](https://github.com/godotengine/godot/blob/4.7.2-stable/core/extension/godot_instance.cpp),
[`libgodot_macos.mm`](https://github.com/godotengine/godot/blob/4.7.2-stable/platform/macos/libgodot_macos.mm)):

- `create` constructs the OS singleton, runs `Main::setup(argv)`, then loads **our init function as an extension
  named `libgodot://main`**. Godot calls it with `get_proc_address` exactly as it would call a dylib's entry symbol.
- `start` = `Main::setup2()` + `Main::start()` + `main_loop->initialize()`.
- `iteration` = `DisplayServer::process_events()` + `Main::iteration()`, which is one whole Godot frame: physics
  steps from Godot's own wall-clock accumulator, `_process`, extension `frame` callbacks, render, present, and then
  `add_frame_delay` (the `max_fps` sleep). It returns true when the game quits. **You can't pass a delta or split
  "update" from "draw".**
- `destroy` = `stop` + `Main::cleanup()`. The static instance pointer is never cleared (a comment says "when Godot
  supports reinitialization"), so **it's one instance per process lifetime, not just one at a time**. The spike
  confirmed this: a second create fails with `Only one Godot Instance may be created.`

**How it's built.** Official releases ship no desktop library. I checked the
[4.7.2 release assets](https://github.com/godotengine/godot/releases/tag/4.7.2-stable): the only `godot-lib` files
are the Android `.aar`s. You build from source with `scons library_type=shared_library` (the values are
`executable|static_library|shared_library`). Only `linuxbsd`, `macos` and `windows` list `"library"` as supported in
their `detect.py`. **Static linking is broken** ([#111876](https://github.com/godotengine/godot/issues/111876),
open; "the build system claims it does. It's lying", in
[zorbathut/libgodot_example](https://github.com/zorbathut/libgodot_example)). So we'd ship a dylib/DLL/.so next to
our executable. Web ([#121502](https://github.com/godotengine/godot/pull/121502)) and .NET
([#123251](https://github.com/godotengine/godot/pull/123251)) support are open PRs. iOS, Android and visionOS don't
offer library builds upstream. **Consoles:** console ports are third-party and under NDA, and I found nothing saying
any of them supports library builds **(unverified, assume no)**.

**Feature matrix (4.7, upstream):**

| | Status |
|---|---|
| Godot's own window(s), input, audio | ✅ It's the normal DisplayServer. Spike: rendering, 4 windows not tried, mouse and keyboard not tried |
| Render into *our* window or surface | ❌ Apple-only in Migeran's fork ([libgodot_project](https://github.com/migeran/libgodot_project)). Upstream prep is in [#123555](https://github.com/godotengine/godot/pull/123555), open. The [GodotCon talk (Apr 2026)](https://talks.godotengine.org/godotcon-ams-2026/talk/DQXZZC/) calls it "being merged" |
| `--headless` (dummy renderer, no GPU) | ✅ Spike: hash correct, start 164 ms |
| Offscreen rendering without a window | ❌ Not upstream. Downstream embedders do it on Linux/Vulkan ([#124665](https://github.com/godotengine/godot/pull/124665)) |
| Gamepads | ⚠️ **Broken on macOS and Linux**: SDL joypad events are pumped in the OS run loop, not in `GodotInstance::iteration` ([#112044](https://github.com/godotengine/godot/issues/112044), fix [#123911](https://github.com/godotengine/godot/pull/123911) open). I confirmed this in `os_macos.mm` and `os_linuxbsd.cpp`. Windows pumps them in `DisplayServer::process_events`, so it's OK there |
| Restart in-process | ❌ About 12 open PRs ([#123720](https://github.com/godotengine/godot/pull/123720) lists them). 2dog carries its own fork for this |
| Multiple instances | ❌ Global singletons. 2dog's experimental concurrent hosting needs a separate copy of the native library per instance, and macOS is unsupported ([2dog](https://github.com/outfox/2dog/blob/main/docs/content/known-issues/single-instance.md)) |
| Editor in-process | ✅ Spike: an editor-target libgodot opened the editor (`--editor --path …`), ran 390 iterations and quit cleanly. `--headless --import` worked, but 1 of 7 runs segfaulted on teardown |
| Logging hooks, crash handler control | ❌ [#124012](https://github.com/godotengine/godot/pull/124012) is open. Godot's crash handler overwrites the host's signal handlers ([#119079](https://github.com/godotengine/godot/issues/119079), [#121494](https://github.com/godotengine/godot/issues/121494)) |

**Maturity.** The main upstream author is Migeran (sponsors Xibbon/Xogot, Smirk). Users I could verify:
[2dog](https://github.com/outfox/2dog) (.NET hosts Godot, 234★, active, but **it ships a patched libgodot** for
restart, loading order and prebuilt natives); [SwiftGodotKit](https://github.com/migueldeicaza/SwiftGodotKit)
(v4.7.3, Sep 2026, on its own `swiftgodotkit-4.6` Godot branch); zorbathut's example, whose README ends "This whole
thing seems . . . kind of half-baked? No comment". Xogot (Godot editor on iPad) probably runs on it, since it
sponsors the work **(unverified)**. Other open bugs: no system cursors on Windows
([#113125](https://github.com/godotengine/godot/issues/113125)); a crash on `--dump-extension-api`
([#120954](https://github.com/godotengine/godot/issues/120954)), which our binding generator relies on, although we
could dump with the stock binary; a ResourceLoader use-after-free on destroy
([#124796](https://github.com/godotengine/godot/issues/124796)). In short: it works for the straight-line case,
every serious user forks it, and the interesting parts are a version or two away.

## 2. Spike: the prototype as a LibGodot host

Scratch dir: `…/scratchpad/libgodot/` (Godot 4.7.2 shallow clone, scons 4.11 in a Python venv, no system installs).

| Step | Result |
|---|---|
| Clone + venv + scons | 65 s + 10 s |
| `scons platform=macos target=template_debug library_type=shared_library vulkan=no accesskit=no angle=no -j14` | **2 m 22 s**, `libgodot.dylib` 61 MB (arm64). Changing any flag rebuilds everything (2 m 17 s) |
| Same with `target=editor` | 3 m 20 s, 131 MB |
| Host: `host/main.odin`, 82 lines, imports `bench/b/godot-odin/src/bench` unchanged and calls `libgodot_create_godot_instance(…, bench.bench_init)`, then `GodotInstance.start` and `iteration` through `gd.method_bind` + ptrcall | Builds in 2 s, 1.1 MB |
| `--frames 600 --ticks 600 --sim-speed 8` | `sim_hash 35554353d1bd4fcb`, **equal to bench-a**. Windowed and `--headless` |
| Screenshot | Same image as the GDExtension run (main-loop callbacks fire as usual) |
| Startup (create / start / `startup_ms`) | 47–65 ms / 417–435 ms / **~480 ms** warm (first run 7.6 s while the shader cache filled). GDExtension with the stock editor binary: 620–950 ms. The difference is probably the binary (lean template vs the 353 MB mono editor), not the route **(unverified)** |
| Frame cost | `frame_ms` 6.5–7.7, `cpu_ms` 1.1–1.5, the same range as the GDExtension run |
| Create on a non-main thread | **Crash** (`NSException` in `-[NSApplication setMainMenu:]`) |
| Second create after destroy | Refused |

Surprises the spike turned up (all fixable, none documented):

1. **Template builds refuse `--path`** and refuse a `project.godot` in the working directory
   (`disable_path_overrides` defaults to true for templates). Dev builds need `disable_path_overrides=no` or the
   editor target. Shipping builds must load a `.pck`.
2. **The dylib's install name is the relative `bin/libgodot…dylib`**. You need `install_name_tool -id @rpath/…`
   and a re-sign.
3. **Memory grows by about 7 KB per frame on macOS** unless the host wraps `iteration` in an autorelease pool. Stock
   Godot runs each frame inside `@autoreleasepool` from a CFRunLoop observer, and `GodotInstance` doesn't. Peak RSS
   over 300 → 3,000 frames went +19 MB without a pool and +2 MB with
   `objc_autoreleasePoolPush/Pop` (that's about 1.5 GB/hour at 60 fps without it).
4. `ERROR: Could not load global script cache` on every run of a template build without an exported
   `.godot/` (harmless).

## 3. What LibGodot would change for us

- **Main loop ownership: smaller than it sounds.** We'd own the `while` loop, but each `iteration()` is still one
  monolithic Godot frame with Godot's own clock, vsync wait and `max_fps` sleep. What we'd gain: code before Godot
  boots (parse the CLI, open sockets, join the relay while Godot initialises) and a choice about when to call
  `iteration` (for example, step the sim N ticks headless without rendering). Both are mostly possible in
  GDExtension too: the extension's init runs early in setup, and the frame callback can run any number of sim
  ticks. Rendering only on a new tick works in both routes with `RenderingServer.render_loop_enabled` /
  `force_draw` **(unverified for our use)**. Our fixed 60 Hz sim never used Godot's physics clock anyway.
- **Threading: no difference.** Godot must live on the process main thread (AppKit; the spike crashed otherwise),
  so LibGodot doesn't free the main thread for our sim. In both routes the right design is the same: sim and
  netcode on our own Odin threads at a fixed cadence, publishing pointer-free snapshots (a triple buffer); Godot's
  main thread interpolates in the frame callback; **no Godot calls from our threads**. This also keeps netcode
  ticking when the main thread stalls (shader compiles, macOS live resize, the Windows modal move loop). Whether
  Windows' modal loop calls `Main::iteration` behind a LibGodot host's back is **unverified**.
- **Headless tests and agent tooling.** In-process boot works (`--headless` hash run, 0.2 s start). But it's one
  instance per process lifetime, it can't be restarted, and on macOS it must be on the main thread. So a test
  runner still needs one process per Godot boot, which is what `Godot --headless --path … -- --ticks N` already
  gives with GDExtension. Screenshots still need a visible window on macOS in both routes (README item 7). The real
  gain: our `unified` binary would *be* the game, with no external Godot to locate (`run.sh`'s search goes away).
- **Hot reload.** Godot's extension reload works only in editor builds (`GDExtensionManager::reload_extension`
  under `#ifndef TOOLS_ENABLED` fails with "only … in an editor build"), needs `reloadable = true`, and needs
  binding support for `recreate_instance`. The embedded `libgodot://main` extension isn't a file, so it can't be
  reloaded. **In both routes the robust plan is our own**: a thin, stable shim that `dlopen`s a game-logic dylib
  and reloads it, keeping state in our pointer-free state block (snapshot = memcpy). That design suits us
  unusually well.
- **Debugging.** LibGodot: `lldb ./unified` with our symbols in the executable, and Godot built by us with symbols
  or ASan when we want them. GDExtension: `lldb Godot`, with our dylib loaded later and breakpoints pending. Both
  are fine. A custom Godot build with symbols is possible in either route.
- **Build and link.** GDExtension: zero Godot builds, official signed binaries, only `odin build` (0.55 s dev).
  LibGodot: a Godot source build for each platform × {template_debug, template_release, editor?} × arch, plus
  install-name, signing and rpath handling, and CI caching keyed by Godot commit. Here that's 2–3.5 min per config
  on 14 cores; CI runners would be much slower **(unverified, guess 15–40 min uncached)**. Godot upgrades mean
  rebuilds.
- **Startup and size.** Startup is the same within noise. Size: libgodot `template_debug` arm64 is 61 MB vs our 1.1
  MB host. Comparable to an official single-arch template **(unverified, I didn't download the 1 GB `.tpz`)**.
- **Class registration and scripts.** These work the same: the host init is an extension, so anything we register
  (classes, callbacks, singletons) works in both routes, and GDScript/other extensions still load. But **the stock
  editor never sees host-embedded code**. Custom nodes, inspector plugins or `@tool` behaviour would need a
  separate GDExtension dylib anyway. And editor "Run" launches the stock binary, not our executable **(unverified
  whether a custom run executable can be set)**.
- **Shipping.** We'd ship our own executable + libgodot + `.pck` (export "PCK only"), our own app bundle, signing,
  notarization and Steam depot layout, and no consoles. GDExtension uses Godot's normal export with official
  templates (including macOS signing), and console ports would at least have a chance.

## 4. GDExtension route: what we keep and give up

**Gains.** Official binaries on every platform, no engine build. The project opens normally in the stock editor
(asset import, scene editing, LightmapGI bakes, which are editor-only per 03). Standard export pipeline. The widest
platform reach, including whatever console vendors support **(unverified per vendor)**. All of 4.5+'s
main-loop callbacks (`register_main_loop_callbacks`, `since: 4.5` in the interface JSON), which let the prototype
skip class registration entirely.

**Gives up.** Godot owns the process: our netcode threads live inside a plugin and start when Godot loads us. That's
early enough, and the threads are ours. Godot's crash handler and stdout are Godot's. And `reloadable` reload is
editor-only and class-centric.

**Gotchas to fix in our design.** (a) The main-loop callbacks also fire **inside the editor** when the editor
loads the extension, so `startup` must check `Engine.is_editor_hint()` or it builds the game scene into the
editor's window. That's my inference from `Main::iteration` calling `GDExtensionManager::frame()` in all builds; I
didn't test it in the editor. (b) Windows locks loaded DLLs, so reload needs copy-on-load
([gdext #1](https://github.com/godot-rust/gdext/issues/1), secondary). (c) Hash-pinned method binds keep working
across versions thanks to `hash_compatibility` (README item 8).

## 5. Side by side

| | GDExtension (Godot hosts Odin) | LibGodot (Odin hosts Godot) |
|---|---|---|
| Engine binaries | Official, signed, every platform | Build from source; desktop only; static broken |
| Main thread | Godot's | Still Godot's (must be the process main thread) |
| Frame control | `frame` callback before draw; own threads | Outer loop is ours; `iteration()` is still a whole frame |
| Editor | Opens the project normally; can host editor plugins | Stock editor can't see our code; editor-target lib works but is new |
| Hot reload | Editor builds only via `reloadable`; our own shim works | Our own shim only |
| Headless/tests | `Godot --headless -- …`, one process per run | In-process, but once per process |
| Screenshots on macOS | Visible window | Visible window (no offscreen upstream) |
| Gamepads | ✅ | ❌ macOS/Linux until #123911 |
| Restart / multi-instance | Process-level | ❌ / ❌ upstream |
| Crash/log control | Godot's | Godot's handler overwrites ours; hooks are PRs |
| Shipping | Godot export | Our bundle + lib + pck; we own signing |
| Consoles | Possible via third-party ports **(unverified)** | No path known |
| Reversibility | The init function moves to LibGodot unchanged (spike) | Same seam back |

**LibGodot surprises, good:** the host *is* a GDExtension, so bindings, callbacks and code carry over 1:1. The
build takes under 3 minutes on this Mac. Startup is fast. Headless works. An editor-target lib can open the editor
and run imports in-process.
**Bad:** gamepads silently dead on macOS/Linux; an autorelease leak on macOS; templates refuse `--path`; the
relative install name; one instance per *process lifetime*; must be created on the main thread; static linking
broken; Godot's crash handler overwrites the host's; no embedding or restart upstream; serious users run forks.

**Hybrid options.**
1. **GDExtension for the game, plus an optional LibGodot "embedded runner" for tooling** (our `unified` CLI links
   libgodot to boot the project headless for hash runs, evals and agent REPLs). Cost: a Godot build in CI. Gain over
   spawning `Godot --headless`: small today, since it's still one boot per process.
2. **The same Odin package exposes one `unified_init` entry**, used by the `.gdextension` file *and* by a LibGodot
   host. That's what the spike did. It costs nothing to keep both alive, so the decision stays reversible.
3. Revisit LibGodot as the primary route when restart and native-surface embedding land upstream, and gamepads are
   fixed (4.9+ at the earliest, judging by milestones).

## 6. Recommendation and a one-day spike

**Recommendation: GDExtension, with the integration seam kept route-neutral (option 2). Confidence about 80%.**
What would flip it: we need Godot inside our own window or UI, in-process restarts for a test runner, or full
control of crash handling and logging, *and* those land upstream. Or a console vendor turns out to require it.

**Spike (1 day), GDExtension route, extending `bench/b/godot-odin`:**

| # | Build | Pass / fail |
|---|---|---|
| 1 | Sim + loopback netcode (two peers, fake 80 ms RTT, rollback) on **one Odin thread** at a fixed 60 Hz, publishing snapshots through a triple buffer; the `frame` callback only interpolates and draws | Over 3,600 ticks the sim thread's tick jitter p99 is < 1 ms **while the window is dragged and live-resized**; final hash equals the single-thread run; a debug assert proves no Godot call from the sim thread |
| 2 | Open the project in the stock 4.7.2 editor with the extension loaded; guard `startup` with `is_editor_hint` | Editor opens without errors or an injected scene; Run from the editor plays the game |
| 3 | Our own hot reload: shim dylib + `game.dylib` (sim + view logic) reloaded on change, state kept in the pointer-free block | Edit → rebuild → resumed in < 1 s with no restart; hash continuity is checked against a non-reloaded run |
| 4 | Gamepad → Godot `Input` in `frame` → sim input | Works on macOS with a real pad |
| 5 | Headless hash run with official Godot on Linux and Windows CI | Same hash as bench-a on both; < 5 s wall |
| 6 | Keep the scratch LibGodot host as `unified run --embedded` (autorelease pool, `@rpath`, `disable_path_overrides=no`) | Same hash; documented as experimental, not on the critical path |

If the developer prefers LibGodot instead, its spike is items 1, 3 and 4 on the host from §2, plus a cached
Linux/Windows CI libgodot build (fail if it's over 20 min cached-miss or needs patches) and a gamepad workaround
(our own SDL input in the host, which arguably suits rollback input sampling anyway).
