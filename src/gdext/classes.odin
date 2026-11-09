// Extension classes: Odin structs that extend an engine class and show up in ClassDB (editor, GDScript).
//
//   My_Node :: struct { using hdr: gdext.Instance_Header, speed: f32 }
//   my_class := gdext.Class{name = "MyNode", parent = "Node3D", size = size_of(My_Node),
//                           ready = proc(i: rawptr) {...}, process = proc(i: rawptr, dt: f64) {...}}
//   gdext.register_class(&my_class)
//   gdext.bind_method(&my_class, "jump", proc(n: ^My_Node, height: f32) -> bool {...}, {"height"})
//   gdext.bind_property(&my_class, "speed", get_speed, set_speed)
//   gdext.bind_signal(&my_class, "landed", {"height", f32})
//
// Methods are bound from typed Odin procs (0-3 arguments, optional result): a trampoline per signature
// converts Variants (GDScript calls) and ptrcall slots (typed calls) with variant.odin. Engine virtuals
// are typed fields of Class. Hot reload (editor): Godot keeps the engine objects, calls recreate, then
// restores registered properties and sends NOTIFICATION_EXTENSION_RELOADED; Odin globals start fresh.
package gdext

import "base:runtime"
import "core:fmt"
import "unified:gdext/gdi"

Instance_Header :: struct {
	obj:   Object, // the engine object this instance extends
	class: ^Class,
}

Virtual :: enum u8 {
	Ready,
	Process,
	Input,
}

@(private)
VIRTUAL_NAMES := [Virtual]string {
	.Ready   = "_ready",
	.Process = "_process",
	.Input   = "_input",
}

@(private)
Virtual_Call :: struct {
	class: ^Class,
	which: Virtual,
}

Class :: struct {
	name, parent:       string,
	size:               int, // instance size; the instance struct starts with an Instance_Header
	runtime_only:       bool, // ClassDB "runtime" class: a placeholder in the editor, never runs there
	init:               proc(inst: rawptr), // after the header is set (also after a hot reload)
	fini:               proc(inst: rawptr),
	notification:       proc(inst: rawptr, what: i32),
	// Engine virtuals; nil = not overridden.
	ready:              proc(inst: rawptr),
	process:            proc(inst: rawptr, delta: f64),
	input:              proc(inst: rawptr, event: InputEvent),
	// filled by register_class
	name_sn, parent_sn: StringName,
	instances:          int,
	vcalls:             [Virtual]Virtual_Call,
}

@(private)
binding_callbacks := gdi.InstanceBindingCallbacks {
	create_callback = proc "c" (token: rawptr, instance: rawptr) -> rawptr {return nil},
	free_callback = proc "c" (token: rawptr, instance: rawptr, binding: rawptr) {},
	reference_callback = proc "c" (token: rawptr, binding: rawptr, reference: gdi.Bool) -> gdi.Bool {return 1},
}

@(private)
new_instance :: proc(cls: ^Class, obj: rawptr) -> rawptr {
	mem, err := runtime.mem_alloc(cls.size)
	assert(err == nil)
	inst := raw_data(mem)
	h := (^Instance_Header)(inst)
	h.obj = Object{obj}
	h.class = cls
	gdi.object_set_instance(obj, &cls.name_sn, inst)
	gdi.object_set_instance_binding(obj, library, inst, &binding_callbacks)
	cls.instances += 1
	if cls.init != nil do cls.init(inst)
	return inst
}

@(private)
cls_create :: proc "c" (userdata: rawptr, notify: gdi.Bool) -> gdi.ObjectPtr {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD() // LIFO: a nested callback never frees its caller's temp data
	cls := (^Class)(userdata)
	obj := gdi.classdb_construct_object2(&cls.parent_sn)
	new_instance(cls, obj)
	if notify != 0 do Object_notification(Object{obj}, 0) // NOTIFICATION_POSTINITIALIZE
	return obj
}

@(private)
cls_recreate :: proc "c" (userdata: rawptr, obj: gdi.ObjectPtr) -> gdi.ClassInstancePtr {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	return new_instance((^Class)(userdata), obj)
}

@(private)
cls_free :: proc "c" (userdata: rawptr, inst: gdi.ClassInstancePtr) {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	cls := (^Class)(userdata)
	if cls.fini != nil do cls.fini(inst)
	cls.instances -= 1
	runtime.mem_free(inst)
}

@(private)
cls_notification :: proc "c" (inst: gdi.ClassInstancePtr, what: i32, reversed: gdi.Bool) {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	if inst == nil do return
	h := (^Instance_Header)(inst)
	if h.class.notification != nil do h.class.notification(inst, what)
}

@(private)
cls_virtual_data :: proc "c" (userdata: rawptr, name: gdi.ConstStringNamePtr, hash: u32) -> rawptr {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	cls := (^Class)(userdata)
	n := string_name_to_odin(cast(^StringName)name)
	for vn, which in VIRTUAL_NAMES {
		if vn != n do continue
		set := false
		switch which {
		case .Ready:
			set = cls.ready != nil
		case .Process:
			set = cls.process != nil
		case .Input:
			set = cls.input != nil
		}
		return set ? &cls.vcalls[which] : nil
	}
	return nil
}

@(private)
cls_virtual_call :: proc "c" (
	inst: gdi.ClassInstancePtr,
	name: gdi.ConstStringNamePtr,
	userdata: rawptr,
	args: [^]gdi.ConstTypePtr,
	ret: gdi.TypePtr,
) {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	vc := (^Virtual_Call)(userdata)
	c := vc.class
	switch vc.which {
	case .Ready:
		c.ready(inst)
	case .Process:
		c.process(inst, (^f64)(args[0])^)
	case .Input:
		c.input(inst, transmute(InputEvent)(^rawptr)(args[0])^)
	}
}

// Registers `cls` (which must outlive the extension) with ClassDB. Call at the SCENE init level.
register_class :: proc(cls: ^Class) {
	cls.name_sn = string_name_from(cls.name)
	cls.parent_sn = string_name_from(cls.parent)
	for &vc, which in cls.vcalls do vc = {cls, which}
	info := gdi.ClassCreationInfo6 {
		is_exposed                  = 1,
		is_runtime                  = cls.runtime_only ? 1 : 0,
		notification_func           = cls_notification,
		create_instance_func        = cls_create,
		free_instance_func          = cls_free,
		recreate_instance_func      = cls_recreate,
		get_virtual_call_data_func  = cls_virtual_data,
		call_virtual_with_data_func = cls_virtual_call,
		class_userdata              = cls,
	}
	gdi.classdb_register_extension_class6(library, &cls.name_sn, &cls.parent_sn, &info)
}

unregister_class :: proc(cls: ^Class) {
	gdi.classdb_unregister_extension_class(library, &cls.name_sn)
	StringName_destroy(&cls.name_sn)
	StringName_destroy(&cls.parent_sn)
}

// ---- typed methods

Method :: struct {
	fn:      rawptr,
	nargs:   int,
	call:    proc(m: ^Method, inst: rawptr, args: [^]gdi.ConstVariantPtr, ret: gdi.VariantPtr, err: ^gdi.CallError),
	ptrcall: proc(m: ^Method, inst: rawptr, args: [^]gdi.ConstTypePtr, ret: gdi.TypePtr),
}

// Debug builds count bound-method calls by path (tests check that typed GDScript calls take ptrcall).
call_counts: struct {
	variant, ptrcall: int,
}

@(private)
method_call :: proc "c" (
	userdata: rawptr,
	inst: gdi.ClassInstancePtr,
	args: [^]gdi.ConstVariantPtr,
	argc: gdi.Int,
	ret: gdi.VariantPtr,
	err: ^gdi.CallError,
) {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	m := (^Method)(userdata)
	when ODIN_DEBUG do call_counts.variant += 1
	err.error = .OK
	if int(argc) != m.nargs {
		err.error = int(argc) < m.nargs ? .ERROR_TOO_FEW_ARGUMENTS : .ERROR_TOO_MANY_ARGUMENTS
		err.expected = i32(m.nargs)
		return
	}
	m.call(m, inst, args, ret, err)
}

@(private)
method_ptrcall :: proc "c" (
	userdata: rawptr,
	inst: gdi.ClassInstancePtr,
	args: [^]gdi.ConstTypePtr,
	ret: gdi.TypePtr,
) {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	m := (^Method)(userdata)
	when ODIN_DEBUG do call_counts.ptrcall += 1
	m.ptrcall(m, inst, args, ret)
}

@(private)
arg :: proc($T: typeid, args: [^]gdi.ConstVariantPtr, i: int, err: ^gdi.CallError) -> (T, bool) {
	v, ok := from_variant(T, cast(^Variant)args[i])
	if !ok {
		err.error = .ERROR_INVALID_ARGUMENT
		err.argument = i32(i)
		err.expected = i32(variant_type_of(T))
	}
	return v, ok
}

Arg :: struct {
	name: string,
	type: typeid,
}

@(private)
property_info :: proc(
	t: typeid,
	name: ^StringName,
	empty_sn: ^StringName,
	hint: ^String,
	usage: u32 = 6,
) -> gdi.PropertyInfo {
	vt := variant_type_of_id(t)
	return {
		type_       = vt,
		name        = name,
		class_name  = empty_sn,
		hint_string = hint,
		usage       = vt == .NIL ? usage | 131072 : usage, // PROPERTY_USAGE_NIL_IS_VARIANT
	}
}

@(private)
arg_metadata :: proc(t: typeid) -> gdi.ClassMethodArgumentMetadata {
	switch t {
	case f32:
		return .REAL_IS_FLOAT
	case f64:
		return .REAL_IS_DOUBLE
	case i32:
		return .INT_IS_INT32
	case u32:
		return .INT_IS_UINT32
	case u8:
		return .INT_IS_UINT8
	case i64, int:
		return .INT_IS_INT64
	}
	return .NONE
}

@(private)
register_method :: proc(cls: ^Class, name: string, m: ^Method, names: []string, types: []typeid, ret: typeid) {
	assert(len(names) == len(types))
	name_sn := string_name_from(name)
	defer StringName_destroy(&name_sn)
	empty_sn := string_name_from("")
	defer StringName_destroy(&empty_sn)
	empty_s := string_from("")
	defer String_destroy(&empty_s)
	n := len(types)
	sns := make([]StringName, n, context.temp_allocator)
	infos := make([]gdi.PropertyInfo, n + 1, context.temp_allocator)
	metas := make([]gdi.ClassMethodArgumentMetadata, n + 1, context.temp_allocator)
	for t, i in types {
		sns[i] = string_name_from(names[i])
		infos[i] = property_info(t, &sns[i], &empty_sn, &empty_s)
		metas[i] = arg_metadata(t)
	}
	defer for &s in sns do StringName_destroy(&s)
	ret_info := property_info(ret == nil ? typeid_of(Variant) : ret, &empty_sn, &empty_sn, &empty_s)
	mi := gdi.ClassMethodInfo {
		name                  = &name_sn,
		method_userdata       = m,
		call_func             = method_call,
		ptrcall_func          = method_ptrcall,
		method_flags          = u32(gdi.ClassMethodFlags.FLAGS_DEFAULT),
		has_return_value      = ret != nil ? 1 : 0,
		return_value_info     = &ret_info,
		return_value_metadata = ret != nil ? arg_metadata(ret) : .NONE,
		argument_count        = u32(n),
		arguments_info        = n > 0 ? &infos[0] : nil,
		arguments_metadata    = n > 0 ? &metas[0] : nil,
	}
	gdi.classdb_register_extension_class_method(library, &cls.name_sn, &mi)
}

@(private)
new_method :: proc(fn: rawptr, nargs: int) -> ^Method {
	m := new(Method)
	m.fn = fn
	m.nargs = nargs
	return m
}

method_0 :: proc(cls: ^Class, name: string, f: proc(self: ^$T)) {
	m := new_method(rawptr(f), 0)
	m.call = proc(m: ^Method, inst: rawptr, args: [^]gdi.ConstVariantPtr, ret: gdi.VariantPtr, err: ^gdi.CallError) {
		(proc(_: ^T))(m.fn)((^T)(inst))
	}
	m.ptrcall = proc(m: ^Method, inst: rawptr, args: [^]gdi.ConstTypePtr, ret: gdi.TypePtr) {
		(proc(_: ^T))(m.fn)((^T)(inst))
	}
	register_method(cls, name, m, nil, nil, nil)
}

method_0r :: proc(cls: ^Class, name: string, f: proc(self: ^$T) -> $R) {
	m := new_method(rawptr(f), 0)
	m.call = proc(m: ^Method, inst: rawptr, args: [^]gdi.ConstVariantPtr, ret: gdi.VariantPtr, err: ^gdi.CallError) {
		r := (proc(_: ^T) -> R)(m.fn)((^T)(inst))
		to_variant_slot(r, cast(^Variant)ret)
	}
	m.ptrcall = proc(m: ^Method, inst: rawptr, args: [^]gdi.ConstTypePtr, ret: gdi.TypePtr) {
		to_ptr((proc(_: ^T) -> R)(m.fn)((^T)(inst)), ret)
	}
	register_method(cls, name, m, nil, nil, R)
}

method_1 :: proc(cls: ^Class, name: string, f: proc(self: ^$T, a: $A), names: [1]string) {
	m := new_method(rawptr(f), 1)
	m.call = proc(m: ^Method, inst: rawptr, args: [^]gdi.ConstVariantPtr, ret: gdi.VariantPtr, err: ^gdi.CallError) {
		a, ok_a := arg(A, args, 0, err)
		if !ok_a do return
		defer release(&a)
		(proc(_: ^T, _: A))(m.fn)((^T)(inst), a)
	}
	m.ptrcall = proc(m: ^Method, inst: rawptr, args: [^]gdi.ConstTypePtr, ret: gdi.TypePtr) {
		(proc(_: ^T, _: A))(m.fn)((^T)(inst), from_ptr(A, args[0]))
	}
	names := names
	register_method(cls, name, m, names[:], {A}, nil)
}

method_1r :: proc(cls: ^Class, name: string, f: proc(self: ^$T, a: $A) -> $R, names: [1]string) {
	m := new_method(rawptr(f), 1)
	m.call = proc(m: ^Method, inst: rawptr, args: [^]gdi.ConstVariantPtr, ret: gdi.VariantPtr, err: ^gdi.CallError) {
		a, ok_a := arg(A, args, 0, err)
		if !ok_a do return
		defer release(&a)
		r := (proc(_: ^T, _: A) -> R)(m.fn)((^T)(inst), a)
		to_variant_slot(r, cast(^Variant)ret)
	}
	m.ptrcall = proc(m: ^Method, inst: rawptr, args: [^]gdi.ConstTypePtr, ret: gdi.TypePtr) {
		to_ptr((proc(_: ^T, _: A) -> R)(m.fn)((^T)(inst), from_ptr(A, args[0])), ret)
	}
	names := names
	register_method(cls, name, m, names[:], {A}, R)
}

method_2 :: proc(cls: ^Class, name: string, f: proc(self: ^$T, a: $A, b: $B), names: [2]string) {
	m := new_method(rawptr(f), 2)
	m.call = proc(m: ^Method, inst: rawptr, args: [^]gdi.ConstVariantPtr, ret: gdi.VariantPtr, err: ^gdi.CallError) {
		a, ok_a := arg(A, args, 0, err)
		if !ok_a do return
		defer release(&a)
		b, ok_b := arg(B, args, 1, err)
		if !ok_b do return
		defer release(&b)
		(proc(_: ^T, _: A, _: B))(m.fn)((^T)(inst), a, b)
	}
	m.ptrcall = proc(m: ^Method, inst: rawptr, args: [^]gdi.ConstTypePtr, ret: gdi.TypePtr) {
		(proc(_: ^T, _: A, _: B))(m.fn)((^T)(inst), from_ptr(A, args[0]), from_ptr(B, args[1]))
	}
	names := names
	register_method(cls, name, m, names[:], {A, B}, nil)
}

method_2r :: proc(cls: ^Class, name: string, f: proc(self: ^$T, a: $A, b: $B) -> $R, names: [2]string) {
	m := new_method(rawptr(f), 2)
	m.call = proc(m: ^Method, inst: rawptr, args: [^]gdi.ConstVariantPtr, ret: gdi.VariantPtr, err: ^gdi.CallError) {
		a, ok_a := arg(A, args, 0, err)
		if !ok_a do return
		defer release(&a)
		b, ok_b := arg(B, args, 1, err)
		if !ok_b do return
		defer release(&b)
		r := (proc(_: ^T, _: A, _: B) -> R)(m.fn)((^T)(inst), a, b)
		to_variant_slot(r, cast(^Variant)ret)
	}
	m.ptrcall = proc(m: ^Method, inst: rawptr, args: [^]gdi.ConstTypePtr, ret: gdi.TypePtr) {
		to_ptr((proc(_: ^T, _: A, _: B) -> R)(m.fn)((^T)(inst), from_ptr(A, args[0]), from_ptr(B, args[1])), ret)
	}
	names := names
	register_method(cls, name, m, names[:], {A, B}, R)
}

method_3 :: proc(cls: ^Class, name: string, f: proc(self: ^$T, a: $A, b: $B, c: $C), names: [3]string) {
	m := new_method(rawptr(f), 3)
	m.call = proc(m: ^Method, inst: rawptr, args: [^]gdi.ConstVariantPtr, ret: gdi.VariantPtr, err: ^gdi.CallError) {
		a, ok_a := arg(A, args, 0, err)
		if !ok_a do return
		defer release(&a)
		b, ok_b := arg(B, args, 1, err)
		if !ok_b do return
		defer release(&b)
		c, ok_c := arg(C, args, 2, err)
		if !ok_c do return
		defer release(&c)
		(proc(_: ^T, _: A, _: B, _: C))(m.fn)((^T)(inst), a, b, c)
	}
	m.ptrcall = proc(m: ^Method, inst: rawptr, args: [^]gdi.ConstTypePtr, ret: gdi.TypePtr) {
		(proc(_: ^T, _: A, _: B, _: C))(m.fn)(
			(^T)(inst),
			from_ptr(A, args[0]),
			from_ptr(B, args[1]),
			from_ptr(C, args[2]),
		)
	}
	names := names
	register_method(cls, name, m, names[:], {A, B, C}, nil)
}

method_3r :: proc(cls: ^Class, name: string, f: proc(self: ^$T, a: $A, b: $B, c: $C) -> $R, names: [3]string) {
	m := new_method(rawptr(f), 3)
	m.call = proc(m: ^Method, inst: rawptr, args: [^]gdi.ConstVariantPtr, ret: gdi.VariantPtr, err: ^gdi.CallError) {
		a, ok_a := arg(A, args, 0, err)
		if !ok_a do return
		defer release(&a)
		b, ok_b := arg(B, args, 1, err)
		if !ok_b do return
		defer release(&b)
		c, ok_c := arg(C, args, 2, err)
		if !ok_c do return
		defer release(&c)
		r := (proc(_: ^T, _: A, _: B, _: C) -> R)(m.fn)((^T)(inst), a, b, c)
		to_variant_slot(r, cast(^Variant)ret)
	}
	m.ptrcall = proc(m: ^Method, inst: rawptr, args: [^]gdi.ConstTypePtr, ret: gdi.TypePtr) {
		r := (proc(_: ^T, _: A, _: B, _: C) -> R)(m.fn)(
			(^T)(inst),
			from_ptr(A, args[0]),
			from_ptr(B, args[1]),
			from_ptr(C, args[2]),
		)
		to_ptr(r, ret)
	}
	names := names
	register_method(cls, name, m, names[:], {A, B, C}, R)
}

// Binds a method callable from GDScript (and typed calls from other extensions): the Odin proc takes the
// instance pointer, then 0-3 arguments; `names` are the argument names shown in the editor.
bind_method :: proc {
	method_0,
	method_0r,
	method_1,
	method_1r,
	method_2,
	method_2r,
	method_3,
	method_3r,
}

Property_Hint :: enum u32 {
	NONE  = 0,
	RANGE = 1,
	ENUM  = 2,
}

// An inspector-visible, saved property backed by get_<name>/set_<name> methods.
bind_property :: proc(
	cls: ^Class,
	name: string,
	get: proc(self: ^$T) -> $V,
	set: proc(self: ^T, v: V),
	hint := Property_Hint.NONE,
	hint_string := "",
) {
	getter, setter := accessor_names(name)
	method_0r(cls, getter, get)
	method_1(cls, setter, set, {"value"})
	name_sn := string_name_from(name)
	defer StringName_destroy(&name_sn)
	empty_sn := string_name_from("")
	defer StringName_destroy(&empty_sn)
	hs := string_from(hint_string)
	defer String_destroy(&hs)
	g := string_name_from(getter)
	defer StringName_destroy(&g)
	s := string_name_from(setter)
	defer StringName_destroy(&s)
	info := property_info(V, &name_sn, &empty_sn, &hs)
	info.hint = u32(hint)
	gdi.classdb_register_extension_class_property(library, &cls.name_sn, &info, &s, &g)
}

@(private)
accessor_names :: proc(name: string) -> (getter, setter: string) {
	return fmt.tprintf("get_%s", name), fmt.tprintf("set_%s", name)
}

@(private)
arg_infos :: proc(
	args: []Arg,
	empty_sn: ^StringName,
	empty_s: ^String,
) -> (
	sns: []StringName,
	infos: []gdi.PropertyInfo,
) {
	sns = make([]StringName, len(args), context.temp_allocator)
	infos = make([]gdi.PropertyInfo, max(len(args), 1), context.temp_allocator)
	for a, i in args {
		sns[i] = string_name_from(a.name)
		infos[i] = property_info(a.type, &sns[i], empty_sn, empty_s)
	}
	return
}

// Declares a signal; GDScript connects to it like to any engine signal.
bind_signal :: proc(cls: ^Class, name: string, args: ..Arg) {
	name_sn := string_name_from(name)
	defer StringName_destroy(&name_sn)
	empty_sn := string_name_from("")
	defer StringName_destroy(&empty_sn)
	empty_s := string_from("")
	defer String_destroy(&empty_s)
	sns, infos := arg_infos(args, &empty_sn, &empty_s)
	defer for &s in sns do StringName_destroy(&s)
	gdi.classdb_register_extension_class_signal(library, &cls.name_sn, &name_sn, &infos[0], i64(len(args)))
}

// Declares a virtual that scripts may implement (docs, autocomplete); Odin calls it with call_script.
bind_script_virtual :: proc(cls: ^Class, name: string, args: ..Arg) {
	name_sn := string_name_from(name)
	defer StringName_destroy(&name_sn)
	empty_sn := string_name_from("")
	defer StringName_destroy(&empty_sn)
	empty_s := string_from("")
	defer String_destroy(&empty_s)
	sns, infos := arg_infos(args, &empty_sn, &empty_s)
	defer for &s in sns do StringName_destroy(&s)
	metas := make([]gdi.ClassMethodArgumentMetadata, max(len(args), 1), context.temp_allocator)
	vi := gdi.ClassVirtualMethodInfo {
		name = &name_sn,
		method_flags = u32(gdi.ClassMethodFlags.FLAG_VIRTUAL),
		return_value = {type_ = .NIL, name = &empty_sn, class_name = &empty_sn, hint_string = &empty_s},
		argument_count = u32(len(args)),
		arguments = &infos[0],
		arguments_metadata = &metas[0],
	}
	gdi.classdb_register_extension_class_virtual_method(library, &cls.name_sn, &vi)
}

// ---- calling into Godot with Variants

// Emits `signal` on `obj` with Odin values (converted with variant_from_any).
emit_signal :: proc(obj: Object, signal: ^StringName, args: ..any) {
	@(static) mb: rawptr
	if mb == nil do mb = method_bind("Object", "emit_signal", 4047867050)
	vs := make([]Variant, len(args) + 1, context.temp_allocator)
	ps := make([]rawptr, len(args) + 1, context.temp_allocator)
	from_type(.STRING_NAME, &vs[0], signal)
	for a, i in args do vs[i + 1] = variant_from_any(a)
	for &v, i in vs do ps[i] = &v
	ret: Variant
	err: gdi.CallError
	gdi.object_method_bind_call(mb, obj.ptr, raw_data(ps), i64(len(ps)), &ret, &err)
	gdi.variant_destroy(&ret)
	for &v in vs do gdi.variant_destroy(&v)
}

has_script_method :: proc(obj: Object, method: ^StringName) -> bool {
	return gdi.object_has_script_method(obj.ptr, method) != 0
}

// Calls a method implemented by the object's script (no-op without one); returns an owned Variant.
call_script :: proc(obj: Object, method: ^StringName, args: ..any) -> Variant {
	vs := make([]Variant, max(len(args), 1), context.temp_allocator)
	ps := make([]rawptr, max(len(args), 1), context.temp_allocator)
	for a, i in args {
		vs[i] = variant_from_any(a)
		ps[i] = &vs[i]
	}
	ret: Variant
	err: gdi.CallError
	gdi.object_call_script_method(obj.ptr, method, raw_data(ps), i64(len(args)), &ret, &err)
	for i in 0 ..< len(args) do gdi.variant_destroy(&vs[i])
	return ret
}

// ---- Callables backed by Odin procs

// Called with the Variant arguments; returns an owned Variant (or a nil Variant).
Callable_Proc :: #type proc(user: rawptr, args: []^Variant) -> Variant

@(private)
Callable_Data :: struct {
	fn:   Callable_Proc,
	user: rawptr,
}

@(private)
callable_call :: proc "c" (
	userdata: rawptr,
	argv: [^]gdi.ConstVariantPtr,
	argc: gdi.Int,
	ret: gdi.VariantPtr,
	err: ^gdi.CallError,
) {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	err.error = .OK // Godot doesn't initialise it
	d := (^Callable_Data)(userdata)
	args := ([^]^Variant)(argv)[:argc]
	r := d.fn(d.user, args)
	(^Variant)(ret)^ = r
}

@(private)
callable_free :: proc "c" (userdata: rawptr) {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	free((^Callable_Data)(userdata))
}

// A Callable that calls `fn(user, args)`; pass `owner` so Godot drops it when that object dies.
callable_create :: proc(fn: Callable_Proc, user: rawptr, owner: Object = {}) -> Callable {
	d := new(Callable_Data)
	d^ = {fn, user}
	info := gdi.CallableCustomInfo2 {
		callable_userdata = d,
		token             = library,
		object_id         = owner.ptr != nil ? gdi.object_get_instance_id(owner.ptr) : 0,
		call_func         = callable_call,
		free_func         = callable_free,
	}
	c: Callable
	gdi.callable_custom_create2(&c, &info)
	return c
}

// Connects `obj.signal` to a Callable (the connection keeps its own copy).
connect :: proc(obj: Object, signal: string, c: Callable, flags: u32 = 0) {
	Object_connect(obj, signal, c, int(flags))
}
