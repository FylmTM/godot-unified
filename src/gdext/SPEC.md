# gdext

Status: signed off 2026-11-15 (#9).

Odin bindings for Godot's GDExtension API: what `unified:godot` and a game's extension call Godot through.

- **Generated code.** The CLI (well under a second, whenever a command needs the bindings and its inputs' hash
  changed) turns the committed
  `api/{extension_api,gdextension_interface}.json` (dumped from 4.7.2) and `bindings.txt` into git-ignored
  `gdi/gdi.gen.odin` (the C interface) and `api.gen.odin` (layouts, enums, typed wrappers `Class_method`). No Godot
  is needed to build. `bindings.txt` lists only what the code that calls Godot uses (`tests/gdext` scans the library's
  host packages, the binding test extensions and the games' extensions, and fails on an unused entry: a class the
  code never names through the bindings, a builtin whose methods it never calls).
- **Wrappers.** They cache their method bind on first use and call through ptrcall. Strings in and out are Odin
  `string`s; a method with StringName parameters is a proc group that also takes interned `^StringName`s
  (`gd.sn("move_left")`, no per-call conversion; hot paths use it). Returns of RefCounted classes are `Ref(T)`,
  which the caller owns (`unref`). Vararg methods take `..any`. Debug builds assert the main thread.
- **Extension classes.** `Class{name, parent, native, size, init, fini, notification, ready, process, input,
  runtime_only, doc_brief, doc}` (`size` 0: the header alone; `native`: the engine class an instance is built on when
  `parent` is one of ours), `register_class(cls)` in order, parent first, then the members below. Every `bind_*` takes
  a `doc` (the editor's help text) and records what it bound; `load_docs()` (EDITOR init level; a game skips it)
  builds Godot's class reference from that, so a member's doc lives where it is bound. A `Dynamic_Arg{name, type,
  class_name}` describes an argument, a result or a property: `class_name` is an OBJECT's class, an INT's enum
  (`"UnifiedSession.Status"`) or an ARRAY's element type (`"Node"`: `Array[Node]`), all typed in GDScript:
  - `bind_method(cls, name, proc(self: ^T, a: A, b: B) -> R, {"a", "b"})`, with 0–3 arguments and one typed
    trampoline per signature; a RefCounted result `R` says who owns it: `Ref(T)` hands the method's reference to
    Godot, a bare `T` is borrowed (Godot takes a reference of its own), on the typed and the Variant path alike;
  - `bind_dynamic_method(cls, name, call, user, args, ret, static)`: one method whose arguments and result are
    Variants, described at run time (`unified:godot` registers its RTTI-built event, command, data and enum classes
    with it); a `static` one is called on the class (`EnumPhase.name(value)`);
  - `bind_property(cls, name, get, set = nil, hint, hint_string, class_name)`: typed accessors, read-only without a
    setter (not saved, not in the inspector); an Object property is typed by its class, `class_name` names an int's
    enum (`.NODE_TYPE` with `"Node"`: a Node property the inspector picks and a scene saves as a path);
  - `bind_dynamic_property(cls, Dynamic_Arg, get, set = nil, user)`: the same over dynamic methods
    (`Unified.data.hud: DataHud`);
  - `bind_signal(cls, name, []Dynamic_Arg)`;
  - `bind_constant(cls, enum_name, name, value)` (an integer constant, `Class.NAME`; in an enum, `Class.Enum.NAME`);
  - `emit_signal`, `call_script`, `has_script_method`, `instance_of(obj, cls)` (the Odin instance behind an object of
    one of our classes or a class extending it);
  - `object_cast(T, obj)`: the object as engine class `T` (`gd.Node2D`) when it is one, else a null handle (the
    class is `T`'s name; its tag is looked up once per `T`);
  - `shutdown()` (scene deinit, after the extension's objects are gone) unregisters every class in reverse order
    and frees their bound methods and the interned StringNames;
  - `callable_create(proc, user, owner)`, `connect`;
  - `sn("name")` returns interned StringNames;
  - `variant_type_name(kind)` (Godot's name of a Variant type) and `variant_to_bytes` (a plain builtin's value).
- **Callbacks.** Every Godot -> Odin callback opens a temp-allocator guard: a nested callback (Odin calls Godot,
  Godot calls back into Odin) never frees its caller's temp data.
- **Who calls Godot.** The library's bindings are the only ones: a game's extension fills frames, and its Godot calls
  go in GDScript or through `unified:godot` helpers (no game's extension calls a Godot class method today). Per-game
  binding lists (a game's `bindings.txt` merged at generation, the trim test scanning library plus games) come only
  if a real need appears (#287).
- **Value conversions.** `to_variant`, `from_variant`, `variant_from_any`, and the `dict_*` / `array_*` helpers.
- **Tests.** `uni test --suite godot-bindings` runs a test class (`tests/godot`) under headless Godot (`--verbose`;
  an orphan StringName or a leak at exit fails it): the typed and the dynamic bindings through Variant calls and
  again through typed calls (checked to take ptrcall), a subclass of an extension class, a nested callback, plus a
  dev UI smoke test.
