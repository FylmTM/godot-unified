// Odin bindings for Godot's GDExtension API. Three layers:
//
//   gdi/gdi.gen.odin  generated: every C interface type and function pointer (package gdi)
//   api.gen.odin      generated: builtin layouts, enums, typed class wrappers (`Node3D_set_position`...)
//   runtime.odin      this file: init, strings, lookups, the StringName cache, main-thread check, printing
//   variant.odin      Odin values <-> Variant and ptrcall slots
//   classes.odin      extension classes: registration, virtuals, typed methods, properties, signals, Callables
//
// The generated files are git-ignored; `uni godot-gen` writes them from the committed
// api/*.json and bindings.txt. Every Godot call must happen on Godot's main thread (checked in debug builds).
package gdext

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:sync"
import "unified:gdext/gdi"

library: gdi.ClassLibraryPtr
main_thread_id: int

// Call from the extension's entry symbol, before anything else.
init :: proc(gpa: gdi.InterfaceGetProcAddress, lib: gdi.ClassLibraryPtr) {
	gdi.load(gpa)
	library = lib
	main_thread_id = sync.current_thread_id()
}

// Call from deinitialize (scene level): frees the interned StringNames.
shutdown :: proc() {
	for _, p in interned {
		StringName_destroy(p)
		free(p)
	}
	delete(interned)
	interned = nil
}

// Traps unless called on the thread that ran init (Godot's main thread). Generated wrappers call it in debug builds:
// Godot's object API is not thread-safe, so a call from a sim or network thread is a bug.
check_main_thread :: proc(loc := #caller_location) {
	if sync.current_thread_id() != main_thread_id {
		fail("Godot called from a non-main thread", loc)
	}
}

// Reports `msg` in Godot's error log with the caller's location, then traps: for an API mismatch or misuse that
// leaves nothing sensible to continue with.
fail :: proc(msg: string, loc := #caller_location) -> ! {
	print_error(msg, loc)
	runtime.trap()
}

// ---- printing into Godot's log (editor Output panel, stdout/stderr)

// Prints an error into Godot's log (the editor's Output panel, stderr), tagged with the caller's file, line and proc.
print_error :: proc(msg: string, loc := #caller_location) {
	cmsg := strings.clone_to_cstring(msg, context.temp_allocator)
	cfile := strings.clone_to_cstring(loc.file_path, context.temp_allocator)
	cproc := strings.clone_to_cstring(loc.procedure, context.temp_allocator)
	gdi.print_error(cmsg, cproc, cfile, i32(loc.line), 1)
}

// Like print_error, as a warning: for a misconfiguration the game can run through.
print_warning :: proc(msg: string, loc := #caller_location) {
	cmsg := strings.clone_to_cstring(msg, context.temp_allocator)
	cfile := strings.clone_to_cstring(loc.file_path, context.temp_allocator)
	cproc := strings.clone_to_cstring(loc.procedure, context.temp_allocator)
	gdi.print_warning(cmsg, cproc, cfile, i32(loc.line), 1)
}

// Godot's `print` (shows in the editor's Output panel as well as stdout).
print :: proc(args: ..any) {
	utility_print("print", fmt.tprint(..args))
}

// Godot's `print` with a format string (core:fmt verbs).
printf :: proc(format: string, args: ..any) {
	utility_print("print", fmt.tprintf(format, ..args))
}

@(private)
utility_print :: proc(name: string, msg: string) {
	@(static) functions: map[string]gdi.PtrUtilityFunction
	function, ok := functions[name]
	if !ok {
		name_sn := string_name_from(name)
		defer StringName_destroy(&name_sn)
		function = gdi.variant_get_ptr_utility_function(&name_sn, 2648703342)
		functions[name] = function
	}
	if function == nil {
		fmt.println(msg)
		return
	}
	message_variant := to_variant(msg)
	defer variant_destroy(&message_variant)
	args := [1]rawptr{&message_variant}
	ret: Variant
	function(&ret, &args[0], 1)
}

// ---- strings

// A new Godot String holding a copy of `text`; the caller owns it (String_destroy).
string_from :: proc(text: string) -> String {
	result: String
	gdi.string_new_with_utf8_chars_and_len2(&result, cstring(raw_data(text)), i64(len(text)))
	return result
}

// Copies a Godot String into an Odin UTF-8 string in `allocator` (temp by default); the String stays the caller's.
string_to_odin :: proc(string_ptr: ^String, allocator := context.temp_allocator) -> string {
	length := gdi.string_to_utf8_chars(string_ptr, nil, 0)
	buf := make([]u8, length, allocator)
	if length > 0 do gdi.string_to_utf8_chars(string_ptr, raw_data(buf), length)
	return string(buf)
}

// A new StringName for `text`; the caller owns it (StringName_destroy). A name passed often is cheaper interned
// with sn.
string_name_from :: proc(text: string) -> StringName {
	result: StringName
	gdi.string_name_new_with_utf8_chars_and_len(&result, cstring(raw_data(text)), i64(len(text)))
	return result
}

// Copies a StringName's text into an Odin string in `allocator` (temp by default).
string_name_to_odin :: proc(name: ^StringName, allocator := context.temp_allocator) -> string {
	str := String_new2(name^) // String(StringName)
	defer String_destroy(&str)
	return string_to_odin(&str, allocator)
}

// A new NodePath parsed from `path`; the caller owns it (NodePath_destroy).
node_path_from :: proc(path: string) -> NodePath {
	str := string_from(path)
	defer String_destroy(&str)
	return NodePath_new2(str) // NodePath(String)
}

// A NodePath's text as an Odin string in `allocator` (temp by default).
node_path_to_odin :: proc(path: ^NodePath, allocator := context.temp_allocator) -> string {
	str := String_new3(path^) // String(NodePath)
	defer String_destroy(&str)
	return string_to_odin(&str, allocator)
}

// ---- interned StringNames: created once per distinct string, alive until shutdown(). Main thread only.

@(private)
interned: map[string]^StringName

// A StringName for `s` that stays valid until shutdown(): use it for signal, method and action names
// passed every frame.
sn :: proc(text: string) -> ^StringName {
	if name, ok := interned[text]; ok do return name
	name := new(StringName)
	name^ = string_name_from(text)
	interned[strings.clone(text)] = name
	return name
}

// ---- lookups (cached by the generated wrappers)

// Looks up an engine method by class, name and hash. Traps when it is missing: the running Godot's API differs from
// the dump the bindings were generated from. Generated class wrappers cache the result.
method_bind :: proc(class, method: string, hash: i64) -> rawptr {
	class_sn := string_name_from(class)
	defer StringName_destroy(&class_sn)
	method_sn := string_name_from(method)
	defer StringName_destroy(&method_sn)
	bind := gdi.classdb_get_method_bind(&class_sn, &method_sn, hash)
	if bind == nil do fail(fmt.tprintf("method bind %s.%s (hash %d) not found: API mismatch", class, method, hash))
	return bind
}

// Looks up a builtin type's method (Array.push_back...) by name and hash, trapping when it is missing. Generated
// builtin wrappers cache the result.
builtin_method :: proc(kind: gdi.VariantType, method: string, hash: i64) -> gdi.PtrBuiltInMethod {
	method_sn := string_name_from(method)
	defer StringName_destroy(&method_sn)
	function := gdi.variant_get_ptr_builtin_method(kind, &method_sn, hash)
	if function == nil do fail(fmt.tprintf("builtin method %v.%s (hash %d) not found", kind, method, hash))
	return function
}

// The engine singleton named `name` (Input, Engine...), nil if there is none; generated `<Class>_singleton` procs
// cache it.
get_singleton :: proc(name: string) -> rawptr {
	name_sn := string_name_from(name)
	defer StringName_destroy(&name_sn)
	return gdi.global_get_singleton(&name_sn)
}

// Logs a failed Variant call (wrong argument count or type), `what` naming the call site. Generated vararg wrappers
// report through it and carry on.
call_error :: proc(err: gdi.CallError, what: string) {
	print_error(
		fmt.tprintf(
			"%s: Variant call failed: %v (argument %d, expected %d)",
			what,
			err.error,
			err.argument,
			err.expected,
		),
	)
}

// ---- objects

// An owned reference to a RefCounted object, returned by wrappers and constructors. It converts to
// `T` implicitly; drop it with `unref` (or hand it to Godot and then unref).
Ref :: struct($T: typeid) {
	using ref: T,
}

// Constructs an engine object. RefCounted objects come back with one reference the caller owns;
// POSTINITIALIZE is sent here (Godot 4.4+ leaves it to the caller).
construct_object :: proc(class: string) -> rawptr {
	class_sn := string_name_from(class)
	defer StringName_destroy(&class_sn)
	object := gdi.classdb_construct_object3(&class_sn)
	if object == nil do fail(fmt.tprintf("cannot construct %s", class))
	Object_notification(Object{object}, 0) // NOTIFICATION_POSTINITIALIZE
	return object
}

// Reinterprets an object handle as another class (check with is_class or object_cast first).
cast_to :: proc($T: typeid, object: Object) -> T {
	return transmute(T)object.ptr
}

// The object as `T` when it is one (by class tag), else a null handle.
object_cast :: proc($T: typeid, object: Object, class: string) -> T {
	if object.ptr == nil do return {}
	tag := gdi.classdb_get_class_tag(sn(class))
	return transmute(T)gdi.object_cast_to(object.ptr, tag)
}

// Drops one reference; destroys the object when it was the last.
unref :: proc(object: RefCounted) {
	if object.ptr != nil && RefCounted_unreference(object) do gdi.object_destroy(object.ptr)
}

// Adds a reference (to keep an object that Godot handed over without one, e.g. a ptrcall argument).
ref :: proc(object: $T) -> Ref(T) {
	if object.ptr != nil do RefCounted_reference(RefCounted{object.ptr})
	return Ref(T){object}
}

// Whether the handle points at an object at all. It does not detect an object that was freed since.
is_valid :: proc(object: Object) -> bool {
	return object.ptr != nil
}
