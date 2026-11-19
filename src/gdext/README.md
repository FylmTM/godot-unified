# `unified:gdext`: Odin bindings for Godot's GDExtension API

What `unified:godot` and `unified:devui` call Godot through: the engine's classes as typed wrappers, Variant
conversions, and extension classes (Odin structs registered with ClassDB, documented in the editor's help). A game
reaches Godot through `unified:godot` or GDScript: no game's extension calls a Godot class method, and none imports
this package. It imports nothing of the collection but its own `gdi` (the C interface).

## How it works

- **Generated code.** The CLI turns the committed `api/` dump of the pinned Godot (`api/README.md`) and
  `bindings.txt` into the git-ignored `gdi/gdi.gen.odin` and `api.gen.odin`, whenever a command needs the bindings
  and their inputs' hash changed. No Godot is needed to build. `bindings.txt` lists only what the code that calls
  Godot uses: every listed class costs compile time on every build, so `tests/gdext` scans the library's host
  packages, the binding test extensions and the games' extensions, and fails on an entry none of them uses (a class
  never named through the bindings, a builtin whose methods are never called).
- **Wrappers.** One proc per engine method, `Class_method`, called through ptrcall with the method bind cached on
  first use. Strings in and out are Odin `string`s (returned ones in the temp allocator). A method with StringName
  parameters is a proc group that also takes interned `^StringName`s (`sn("move_left")`): no per-call conversion,
  what hot paths pass. A RefCounted result is a `Ref(T)` the caller owns (`unref`). Vararg methods take `..any`.
  Debug builds trap a wrapper called off Godot's main thread.
- **A member's doc lives where it is bound.** Every `bind_*` takes the editor's help text for what it binds, and
  `load_docs` builds Godot's class reference from those records: the GDScript-facing API of `unified:godot` is
  documented in its bindings, beside the code.
- **Callbacks.** Every Godot -> Odin callback (instance creation, notifications, virtuals, bound methods, Callables)
  sets the Odin context and opens a temp-allocator guard: a nested callback (Odin calls Godot, Godot calls back into
  Odin) never frees its caller's temp data.
- **Main thread only.** Godot's object API is not thread-safe; `init` records the main thread, and the sim and
  network threads of `unified:godot` never call Godot.
