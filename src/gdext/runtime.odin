// Odin bindings for Godot's GDExtension API. Three layers:
//
//   gdi/gdi.gen.odin  generated: every C interface type and function pointer (package gdi)
//   api.gen.odin      generated: builtin layouts, enums, typed class wrappers (`Node3D_set_position`...)
//   runtime.odin      this file: init, strings, lookups, the StringName cache, main-thread check, printing
//   variant.odin      Odin values <-> Variant and ptrcall slots
//   classes.odin      extension classes: registration, virtuals, typed methods, properties, signals, Callables
//
// The generated files are git-ignored; `python tools/dev.py gen` writes them from the committed
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

check_main_thread :: proc(loc := #caller_location) {
	if sync.current_thread_id() != main_thread_id {
		fail("Godot called from a non-main thread", loc)
	}
}

fail :: proc(msg: string, loc := #caller_location) -> ! {
	print_error(msg, loc)
	runtime.trap()
}

// ---- printing into Godot's log (editor Output panel, stdout/stderr)

print_error :: proc(msg: string, loc := #caller_location) {
	cmsg := strings.clone_to_cstring(msg, context.temp_allocator)
	cfile := strings.clone_to_cstring(loc.file_path, context.temp_allocator)
	cproc := strings.clone_to_cstring(loc.procedure, context.temp_allocator)
	gdi.print_error(cmsg, cproc, cfile, i32(loc.line), 1)
}

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

printf :: proc(format: string, args: ..any) {
	utility_print("print", fmt.tprintf(format, ..args))
}

@(private)
utility_print :: proc(name: string, msg: string) {
	@(static) fns: map[string]gdi.PtrUtilityFunction
	fp, ok := fns[name]
	if !ok {
		n := string_name_from(name)
		defer StringName_destroy(&n)
		fp = gdi.variant_get_ptr_utility_function(&n, 2648703342)
		fns[name] = fp
	}
	if fp == nil {
		fmt.println(msg)
		return
	}
	v := to_variant(msg)
	defer variant_destroy(&v)
	args := [1]rawptr{&v}
	ret: Variant
	fp(&ret, &args[0], 1)
}

// ---- strings

string_from :: proc(s: string) -> String {
	r: String
	gdi.string_new_with_utf8_chars_and_len2(&r, cstring(raw_data(s)), i64(len(s)))
	return r
}

string_to_odin :: proc(s: ^String, allocator := context.temp_allocator) -> string {
	n := gdi.string_to_utf8_chars(s, nil, 0)
	buf := make([]u8, n, allocator)
	if n > 0 do gdi.string_to_utf8_chars(s, raw_data(buf), n)
	return string(buf)
}

string_name_from :: proc(s: string) -> StringName {
	r: StringName
	gdi.string_name_new_with_utf8_chars_and_len(&r, cstring(raw_data(s)), i64(len(s)))
	return r
}

string_name_to_odin :: proc(s: ^StringName, allocator := context.temp_allocator) -> string {
	str := String_new2(s^) // String(StringName)
	defer String_destroy(&str)
	return string_to_odin(&str, allocator)
}

node_path_from :: proc(s: string) -> NodePath {
	str := string_from(s)
	defer String_destroy(&str)
	return NodePath_new2(str) // NodePath(String)
}

node_path_to_odin :: proc(p: ^NodePath, allocator := context.temp_allocator) -> string {
	str := String_new3(p^) // String(NodePath)
	defer String_destroy(&str)
	return string_to_odin(&str, allocator)
}

// ---- interned StringNames: created once per distinct string, alive until shutdown(). Main thread only.

@(private)
interned: map[string]^StringName

// A StringName for `s` that stays valid until shutdown(): use it for signal, method and action names
// passed every frame.
sn :: proc(s: string) -> ^StringName {
	if p, ok := interned[s]; ok do return p
	p := new(StringName)
	p^ = string_name_from(s)
	interned[strings.clone(s)] = p
	return p
}

// ---- lookups (cached by the generated wrappers)

method_bind :: proc(class, method: string, hash: i64) -> rawptr {
	c := string_name_from(class)
	defer StringName_destroy(&c)
	m := string_name_from(method)
	defer StringName_destroy(&m)
	mb := gdi.classdb_get_method_bind(&c, &m, hash)
	if mb == nil do fail(fmt.tprintf("method bind %s.%s (hash %d) not found: API mismatch", class, method, hash))
	return mb
}

builtin_method :: proc(vt: gdi.VariantType, method: string, hash: i64) -> gdi.PtrBuiltInMethod {
	m := string_name_from(method)
	defer StringName_destroy(&m)
	fp := gdi.variant_get_ptr_builtin_method(vt, &m, hash)
	if fp == nil do fail(fmt.tprintf("builtin method %v.%s (hash %d) not found", vt, method, hash))
	return fp
}

get_singleton :: proc(name: string) -> rawptr {
	n := string_name_from(name)
	defer StringName_destroy(&n)
	return gdi.global_get_singleton(&n)
}

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
	n := string_name_from(class)
	defer StringName_destroy(&n)
	o := gdi.classdb_construct_object3(&n)
	if o == nil do fail(fmt.tprintf("cannot construct %s", class))
	Object_notification(Object{o}, 0) // NOTIFICATION_POSTINITIALIZE
	return o
}

// Reinterprets an object handle as another class (check with is_class or object_cast first).
cast_to :: proc($T: typeid, o: Object) -> T {
	return transmute(T)o.ptr
}

// The object as `T` when it is one (by class tag), else a null handle.
object_cast :: proc($T: typeid, o: Object, class: string) -> T {
	if o.ptr == nil do return {}
	tag := gdi.classdb_get_class_tag(sn(class))
	return transmute(T)gdi.object_cast_to(o.ptr, tag)
}

// Drops one reference; destroys the object when it was the last.
unref :: proc(o: RefCounted) {
	if o.ptr != nil && RefCounted_unreference(o) do gdi.object_destroy(o.ptr)
}

// Adds a reference (to keep an object that Godot handed over without one, e.g. a ptrcall argument).
ref :: proc(o: $T) -> Ref(T) {
	if o.ptr != nil do RefCounted_reference(RefCounted{o.ptr})
	return Ref(T){o}
}

is_valid :: proc(o: Object) -> bool {
	return o.ptr != nil
}
