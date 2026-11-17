# gdext

Status: signed off 2026-11-15 (#9).

Odin bindings for Godot's GDExtension API: what `unified:godot` and a game's extension call Godot through.

- **Generated code.** `uni godot-gen` (well under a second, cached by input hash) turns the committed
  `api/{extension_api,gdextension_interface}.json` (dumped from 4.7.2) and `bindings.txt` into git-ignored
  `gdi/gdi.gen.odin` (the C interface) and `api.gen.odin` (layouts, enums, typed wrappers `Class_method`). No Godot
  is needed to build. `bindings.txt` lists only what Odin code uses (`tests/gdext` fails on an unused entry).
- **Wrappers.** They cache their method bind on first use and call through ptrcall. Strings in and out are Odin
  `string`s; a method with StringName parameters is a proc group that also takes interned `^StringName`s
  (`gd.sn("move_left")`, no per-call conversion; hot paths use it). Returns of RefCounted classes are `Ref(T)`,
  which the caller owns (`unref`). Vararg methods take `..any`. Debug builds assert the main thread.
- **Extension classes.** `Class{name, parent, size, init, fini, notification, ready, process, input,
  runtime_only}`, then:
  - `bind_method(cls, name, proc(self: ^T, a: A, b: B) -> R, {"a", "b"})`, with 0–3 arguments and one typed
    trampoline per signature; a RefCounted result `R` says who owns it: `Ref(T)` hands the method's reference to
    Godot, a bare `T` is borrowed (Godot takes a reference of its own), on the typed and the Variant path alike;
  - `bind_dynamic_method(cls, name, call, user, args, ret, static)`: one method whose arguments and result are
    Variants, described at run time (`unified:godot` registers its RTTI-built event, command, data and enum classes
    with it); an OBJECT argument or result may name its class (typed in GDScript); a `static` one is called on the
    class (`EnumPhase.name(value)`);
  - `bind_property(cls, name, get, set, hint, hint_string)` (`.NODE_TYPE` with `"Node"`: a Node property the
    inspector picks and a scene saves as a path), and `bind_property_by_name` for a property over methods already
    bound (an OBJECT one names its class: `Unified.data.hud: DataHud`);
  - `bind_signal(cls, name, {"arg", type}...)`;
  - `bind_constant(cls, enum_name, name, value)` (an integer constant, `Class.NAME`; in an enum, `Class.Enum.NAME`);
  - `bind_script_virtual`, `emit_signal`, `call_script`, `instance_of(obj)` (the Odin instance behind an object of
    one of our classes);
  - `callable_create(proc, user, owner)`, `connect`;
  - `sn("name")` returns interned StringNames;
  - `load_class_docs(xml)`: class reference XML for the editor's help (editor only; no-op in a game).
- **Callbacks.** Every Godot -> Odin callback opens a temp-allocator guard: a nested callback (Odin calls Godot,
  Godot calls back into Odin) never frees its caller's temp data.
- **Who calls Godot.** The library's bindings are the only ones: a game's extension fills frames, and its Godot calls
  go in GDScript or through `unified:godot` helpers (no game's extension calls a Godot class method today). Per-game
  binding lists (a game's `bindings.txt` merged at generation, the trim test scanning library plus games) come only
  if a real need appears (#287).
- **Value conversions.** `to_variant`, `from_variant`, `variant_from_any`, and the `dict_*` / `array_*` helpers.
- **Tests.** `uni test --suite godot-bindings` runs a test class (`tests/godot`) under headless Godot (`--verbose`;
  an orphan StringName or a leak at exit fails it) covering every feature above, again through typed calls (checked
  to take ptrcall), a nested callback, class constants, plus a dev UI smoke test.
