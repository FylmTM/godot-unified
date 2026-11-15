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
import "core:strings"
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
	native:             string, // the engine class an instance is built on when `parent` is one of ours ("": parent)
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
	native_sn:          StringName,
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
	header := (^Instance_Header)(inst)
	header.obj = Object{obj}
	header.class = cls
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
	// construct_object3: a RefCounted comes back with its count right for the Ref the caller makes (2 otherwise)
	obj := gdi.classdb_construct_object3(cls.native != "" ? &cls.native_sn : &cls.parent_sn)
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
	header := (^Instance_Header)(inst)
	if header.class.notification != nil do header.class.notification(inst, what)
}

@(private)
cls_virtual_data :: proc "c" (userdata: rawptr, name: gdi.ConstStringNamePtr, hash: u32) -> rawptr {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	cls := (^Class)(userdata)
	virtual_name := string_name_to_odin(cast(^StringName)name)
	for candidate, which in VIRTUAL_NAMES {
		if candidate != virtual_name do continue
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
	virtual_call := (^Virtual_Call)(userdata)
	cls := virtual_call.class
	switch virtual_call.which {
	case .Ready:
		cls.ready(inst)
	case .Process:
		cls.process(inst, (^f64)(args[0])^)
	case .Input:
		cls.input(inst, transmute(InputEvent)(^rawptr)(args[0])^)
	}
}

// Registers `cls` (which must outlive the extension) with ClassDB. Call at the SCENE init level.
register_class :: proc(cls: ^Class) {
	cls.name_sn = string_name_from(cls.name)
	cls.parent_sn = string_name_from(cls.parent)
	if cls.native != "" do cls.native_sn = string_name_from(cls.native)
	for &virtual_call, which in cls.vcalls do virtual_call = {cls, which}
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

// Removes `cls` from ClassDB and frees its names. Call at the SCENE deinit level, subclasses before their parent
// (the reverse of registration).
unregister_class :: proc(cls: ^Class) {
	gdi.classdb_unregister_extension_class(library, &cls.name_sn)
	StringName_destroy(&cls.name_sn)
	StringName_destroy(&cls.parent_sn)
	if cls.native != "" do StringName_destroy(&cls.native_sn)
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
	method := (^Method)(userdata)
	when ODIN_DEBUG do call_counts.variant += 1
	err.error = .OK
	if int(argc) != method.nargs {
		err.error = int(argc) < method.nargs ? .ERROR_TOO_FEW_ARGUMENTS : .ERROR_TOO_MANY_ARGUMENTS
		err.expected = i32(method.nargs)
		return
	}
	method.call(method, inst, args, ret, err)
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
	method := (^Method)(userdata)
	when ODIN_DEBUG do call_counts.ptrcall += 1
	method.ptrcall(method, inst, args, ret)
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
	type_id: typeid,
	name: ^StringName,
	empty_sn: ^StringName,
	hint: ^String,
	usage: u32 = 6,
) -> gdi.PropertyInfo {
	kind := variant_type_of_id(type_id)
	return {
		type_       = kind,
		name        = name,
		class_name  = empty_sn,
		hint_string = hint,
		usage       = kind == .NIL ? usage | 131072 : usage, // PROPERTY_USAGE_NIL_IS_VARIANT
	}
}

@(private)
arg_metadata :: proc(type_id: typeid) -> gdi.ClassMethodArgumentMetadata {
	switch type_id {
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
register_method :: proc(cls: ^Class, name: string, method: ^Method, names: []string, types: []typeid, ret: typeid) {
	assert(len(names) == len(types))
	name_sn := string_name_from(name)
	defer StringName_destroy(&name_sn)
	empty_sn := string_name_from("")
	defer StringName_destroy(&empty_sn)
	empty_s := string_from("")
	defer String_destroy(&empty_s)
	count := len(types)
	sns := make([]StringName, count, context.temp_allocator)
	infos := make([]gdi.PropertyInfo, count + 1, context.temp_allocator)
	metas := make([]gdi.ClassMethodArgumentMetadata, count + 1, context.temp_allocator)
	for type_id, i in types {
		sns[i] = string_name_from(names[i])
		infos[i] = property_info(type_id, &sns[i], &empty_sn, &empty_s)
		metas[i] = arg_metadata(type_id)
	}
	defer for &string_name in sns do StringName_destroy(&string_name)
	ret_info := property_info(ret == nil ? typeid_of(Variant) : ret, &empty_sn, &empty_sn, &empty_s)
	method_info := gdi.ClassMethodInfo {
		name                  = &name_sn,
		method_userdata       = method,
		call_func             = method_call,
		ptrcall_func          = method_ptrcall,
		method_flags          = u32(gdi.ClassMethodFlags.FLAGS_DEFAULT),
		has_return_value      = ret != nil ? 1 : 0,
		return_value_info     = &ret_info,
		return_value_metadata = ret != nil ? arg_metadata(ret) : .NONE,
		argument_count        = u32(count),
		arguments_info        = count > 0 ? &infos[0] : nil,
		arguments_metadata    = count > 0 ? &metas[0] : nil,
	}
	gdi.classdb_register_extension_class_method(library, &cls.name_sn, &method_info)
}

@(private)
new_method :: proc(fn: rawptr, nargs: int) -> ^Method {
	method := new(Method)
	method.fn = fn
	method.nargs = nargs
	return method
}

// bind_method for a proc with no arguments and no result. Each signature gets its own pair of trampolines: a
// Variant call (GDScript, untyped calls) and a ptrcall (typed calls).
method_0 :: proc(cls: ^Class, name: string, f: proc(self: ^$Self)) {
	method := new_method(rawptr(f), 0)
	method.call = proc(
		method: ^Method,
		inst: rawptr,
		args: [^]gdi.ConstVariantPtr,
		ret: gdi.VariantPtr,
		err: ^gdi.CallError,
	) {
		(proc(_: ^Self))(method.fn)((^Self)(inst))
	}
	method.ptrcall = proc(method: ^Method, inst: rawptr, args: [^]gdi.ConstTypePtr, ret: gdi.TypePtr) {
		(proc(_: ^Self))(method.fn)((^Self)(inst))
	}
	register_method(cls, name, method, nil, nil, nil)
}

// bind_method for a proc with no arguments and a result (bind_property's getter).
method_0r :: proc(cls: ^Class, name: string, f: proc(self: ^$Self) -> $Result) {
	method := new_method(rawptr(f), 0)
	method.call = proc(
		method: ^Method,
		inst: rawptr,
		args: [^]gdi.ConstVariantPtr,
		ret: gdi.VariantPtr,
		err: ^gdi.CallError,
	) {
		result := (proc(_: ^Self) -> Result)(method.fn)((^Self)(inst))
		to_variant_slot(result, cast(^Variant)ret)
	}
	method.ptrcall = proc(method: ^Method, inst: rawptr, args: [^]gdi.ConstTypePtr, ret: gdi.TypePtr) {
		to_ptr((proc(_: ^Self) -> Result)(method.fn)((^Self)(inst)), ret)
	}
	register_method(cls, name, method, nil, nil, Result)
}

// bind_method for a proc with one argument and no result (bind_property's setter).
method_1 :: proc(cls: ^Class, name: string, f: proc(self: ^$Self, arg0: $Arg0), names: [1]string) {
	method := new_method(rawptr(f), 1)
	method.call = proc(
		method: ^Method,
		inst: rawptr,
		args: [^]gdi.ConstVariantPtr,
		ret: gdi.VariantPtr,
		err: ^gdi.CallError,
	) {
		arg0, ok0 := arg(Arg0, args, 0, err)
		if !ok0 do return
		defer release(&arg0)
		(proc(_: ^Self, _: Arg0))(method.fn)((^Self)(inst), arg0)
	}
	method.ptrcall = proc(method: ^Method, inst: rawptr, args: [^]gdi.ConstTypePtr, ret: gdi.TypePtr) {
		(proc(_: ^Self, _: Arg0))(method.fn)((^Self)(inst), from_ptr(Arg0, args[0]))
	}
	names := names
	register_method(cls, name, method, names[:], {Arg0}, nil)
}

// bind_method for a proc with one argument and a result.
method_1r :: proc(cls: ^Class, name: string, f: proc(self: ^$Self, arg0: $Arg0) -> $Result, names: [1]string) {
	method := new_method(rawptr(f), 1)
	method.call = proc(
		method: ^Method,
		inst: rawptr,
		args: [^]gdi.ConstVariantPtr,
		ret: gdi.VariantPtr,
		err: ^gdi.CallError,
	) {
		arg0, ok0 := arg(Arg0, args, 0, err)
		if !ok0 do return
		defer release(&arg0)
		result := (proc(_: ^Self, _: Arg0) -> Result)(method.fn)((^Self)(inst), arg0)
		to_variant_slot(result, cast(^Variant)ret)
	}
	method.ptrcall = proc(method: ^Method, inst: rawptr, args: [^]gdi.ConstTypePtr, ret: gdi.TypePtr) {
		to_ptr((proc(_: ^Self, _: Arg0) -> Result)(method.fn)((^Self)(inst), from_ptr(Arg0, args[0])), ret)
	}
	names := names
	register_method(cls, name, method, names[:], {Arg0}, Result)
}

// bind_method for a proc with two arguments and no result.
method_2 :: proc(cls: ^Class, name: string, f: proc(self: ^$Self, arg0: $Arg0, arg1: $Arg1), names: [2]string) {
	method := new_method(rawptr(f), 2)
	method.call = proc(
		method: ^Method,
		inst: rawptr,
		args: [^]gdi.ConstVariantPtr,
		ret: gdi.VariantPtr,
		err: ^gdi.CallError,
	) {
		arg0, ok0 := arg(Arg0, args, 0, err)
		if !ok0 do return
		defer release(&arg0)
		arg1, ok1 := arg(Arg1, args, 1, err)
		if !ok1 do return
		defer release(&arg1)
		(proc(_: ^Self, _: Arg0, _: Arg1))(method.fn)((^Self)(inst), arg0, arg1)
	}
	method.ptrcall = proc(method: ^Method, inst: rawptr, args: [^]gdi.ConstTypePtr, ret: gdi.TypePtr) {
		(proc(_: ^Self, _: Arg0, _: Arg1))(method.fn)((^Self)(inst), from_ptr(Arg0, args[0]), from_ptr(Arg1, args[1]))
	}
	names := names
	register_method(cls, name, method, names[:], {Arg0, Arg1}, nil)
}

// bind_method for a proc with two arguments and a result.
method_2r :: proc(
	cls: ^Class,
	name: string,
	f: proc(self: ^$Self, arg0: $Arg0, arg1: $Arg1) -> $Result,
	names: [2]string,
) {
	method := new_method(rawptr(f), 2)
	method.call = proc(
		method: ^Method,
		inst: rawptr,
		args: [^]gdi.ConstVariantPtr,
		ret: gdi.VariantPtr,
		err: ^gdi.CallError,
	) {
		arg0, ok0 := arg(Arg0, args, 0, err)
		if !ok0 do return
		defer release(&arg0)
		arg1, ok1 := arg(Arg1, args, 1, err)
		if !ok1 do return
		defer release(&arg1)
		result := (proc(_: ^Self, _: Arg0, _: Arg1) -> Result)(method.fn)((^Self)(inst), arg0, arg1)
		to_variant_slot(result, cast(^Variant)ret)
	}
	method.ptrcall = proc(method: ^Method, inst: rawptr, args: [^]gdi.ConstTypePtr, ret: gdi.TypePtr) {
		to_ptr(
			(proc(_: ^Self, _: Arg0, _: Arg1) -> Result)(method.fn)(
				(^Self)(inst),
				from_ptr(Arg0, args[0]),
				from_ptr(Arg1, args[1]),
			),
			ret,
		)
	}
	names := names
	register_method(cls, name, method, names[:], {Arg0, Arg1}, Result)
}

// bind_method for a proc with three arguments and no result.
method_3 :: proc(
	cls: ^Class,
	name: string,
	f: proc(self: ^$Self, arg0: $Arg0, arg1: $Arg1, arg2: $Arg2),
	names: [3]string,
) {
	method := new_method(rawptr(f), 3)
	method.call = proc(
		method: ^Method,
		inst: rawptr,
		args: [^]gdi.ConstVariantPtr,
		ret: gdi.VariantPtr,
		err: ^gdi.CallError,
	) {
		arg0, ok0 := arg(Arg0, args, 0, err)
		if !ok0 do return
		defer release(&arg0)
		arg1, ok1 := arg(Arg1, args, 1, err)
		if !ok1 do return
		defer release(&arg1)
		arg2, ok2 := arg(Arg2, args, 2, err)
		if !ok2 do return
		defer release(&arg2)
		(proc(_: ^Self, _: Arg0, _: Arg1, _: Arg2))(method.fn)((^Self)(inst), arg0, arg1, arg2)
	}
	method.ptrcall = proc(method: ^Method, inst: rawptr, args: [^]gdi.ConstTypePtr, ret: gdi.TypePtr) {
		(proc(_: ^Self, _: Arg0, _: Arg1, _: Arg2))(method.fn)(
			(^Self)(inst),
			from_ptr(Arg0, args[0]),
			from_ptr(Arg1, args[1]),
			from_ptr(Arg2, args[2]),
		)
	}
	names := names
	register_method(cls, name, method, names[:], {Arg0, Arg1, Arg2}, nil)
}

// bind_method for a proc with three arguments and a result.
method_3r :: proc(
	cls: ^Class,
	name: string,
	f: proc(self: ^$Self, arg0: $Arg0, arg1: $Arg1, arg2: $Arg2) -> $Result,
	names: [3]string,
) {
	method := new_method(rawptr(f), 3)
	method.call = proc(
		method: ^Method,
		inst: rawptr,
		args: [^]gdi.ConstVariantPtr,
		ret: gdi.VariantPtr,
		err: ^gdi.CallError,
	) {
		arg0, ok0 := arg(Arg0, args, 0, err)
		if !ok0 do return
		defer release(&arg0)
		arg1, ok1 := arg(Arg1, args, 1, err)
		if !ok1 do return
		defer release(&arg1)
		arg2, ok2 := arg(Arg2, args, 2, err)
		if !ok2 do return
		defer release(&arg2)
		result := (proc(_: ^Self, _: Arg0, _: Arg1, _: Arg2) -> Result)(method.fn)((^Self)(inst), arg0, arg1, arg2)
		to_variant_slot(result, cast(^Variant)ret)
	}
	method.ptrcall = proc(method: ^Method, inst: rawptr, args: [^]gdi.ConstTypePtr, ret: gdi.TypePtr) {
		result := (proc(_: ^Self, _: Arg0, _: Arg1, _: Arg2) -> Result)(method.fn)(
			(^Self)(inst),
			from_ptr(Arg0, args[0]),
			from_ptr(Arg1, args[1]),
			from_ptr(Arg2, args[2]),
		)
		to_ptr(result, ret)
	}
	names := names
	register_method(cls, name, method, names[:], {Arg0, Arg1, Arg2}, Result)
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
	NONE      = 0,
	RANGE     = 1,
	ENUM      = 2,
	NODE_TYPE = 34, // an Object property holding a Node: a node picker; a scene saves it as a path (hint_string: the class)
}

// An inspector-visible, saved property backed by get_<name>/set_<name> methods. An Object property's class is its
// hint_string (NODE_TYPE: "Node").
bind_property :: proc(
	cls: ^Class,
	name: string,
	get: proc(self: ^$Self) -> $Value,
	set: proc(self: ^Self, value: Value),
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
	hint_text := string_from(hint_string)
	defer String_destroy(&hint_text)
	getter_name := string_name_from(getter)
	defer StringName_destroy(&getter_name)
	setter_name := string_name_from(setter)
	defer StringName_destroy(&setter_name)
	class_sn := string_name_from(hint_string if variant_type_of_id(Value) == .OBJECT else "")
	defer StringName_destroy(&class_sn)
	info := property_info(Value, &name_sn, &class_sn, &hint_text)
	info.hint = u32(hint)
	gdi.classdb_register_extension_class_property(library, &cls.name_sn, &info, &setter_name, &getter_name)
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
	for argument, i in args {
		sns[i] = string_name_from(argument.name)
		infos[i] = property_info(argument.type, &sns[i], empty_sn, empty_s)
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
	defer for &string_name in sns do StringName_destroy(&string_name)
	gdi.classdb_register_extension_class_signal(library, &cls.name_sn, &name_sn, &infos[0], i64(len(args)))
}

// Declares an integer constant of the class, in the enum `enum_name` ("" for none): scripts read it as
// `Class.NAME` (and an enum's as `Class.Enum.NAME`, which can type a GDScript variable).
bind_constant :: proc(cls: ^Class, enum_name, name: string, value: i64) {
	enum_sn := string_name_from(enum_name)
	defer StringName_destroy(&enum_sn)
	name_sn := string_name_from(name)
	defer StringName_destroy(&name_sn)
	gdi.classdb_register_extension_class_integer_constant(library, &cls.name_sn, &enum_sn, &name_sn, value, 0)
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
	defer for &string_name in sns do StringName_destroy(&string_name)
	metas := make([]gdi.ClassMethodArgumentMetadata, max(len(args), 1), context.temp_allocator)
	virtual_info := gdi.ClassVirtualMethodInfo {
		name = &name_sn,
		method_flags = u32(gdi.ClassMethodFlags.FLAG_VIRTUAL),
		return_value = {
			type_       = .NIL,
			name        = &empty_sn,
			class_name  = &empty_sn,
			hint_string = &empty_s,
		},
		argument_count = u32(len(args)),
		arguments = &infos[0],
		arguments_metadata = &metas[0],
	}
	gdi.classdb_register_extension_class_virtual_method(library, &cls.name_sn, &virtual_info)
}

// ---- calling into Godot with Variants

// Emits `signal` on `obj` with Odin values (converted with variant_from_any).
emit_signal :: proc(obj: Object, signal: ^StringName, args: ..any) {
	@(static) method_bind_ptr: rawptr
	if method_bind_ptr == nil do method_bind_ptr = method_bind("Object", "emit_signal", 4047867050)
	variants := make([]Variant, len(args) + 1, context.temp_allocator)
	ptrs := make([]rawptr, len(args) + 1, context.temp_allocator)
	from_type(.STRING_NAME, &variants[0], signal)
	for argument, i in args do variants[i + 1] = variant_from_any(argument)
	for &variant, i in variants do ptrs[i] = &variant
	ret: Variant
	err: gdi.CallError
	gdi.object_method_bind_call(method_bind_ptr, obj.ptr, raw_data(ptrs), i64(len(ptrs)), &ret, &err)
	gdi.variant_destroy(&ret)
	for &variant in variants do gdi.variant_destroy(&variant)
}

// Whether the object's script implements `method`, so Odin can skip call_script for an optional script hook
// (checked once, not every call).
has_script_method :: proc(obj: Object, method: ^StringName) -> bool {
	return gdi.object_has_script_method(obj.ptr, method) != 0
}

// Calls a method implemented by the object's script (no-op without one); returns an owned Variant.
call_script :: proc(obj: Object, method: ^StringName, args: ..any) -> Variant {
	variants := make([]Variant, max(len(args), 1), context.temp_allocator)
	ptrs := make([]rawptr, max(len(args), 1), context.temp_allocator)
	for argument, i in args {
		variants[i] = variant_from_any(argument)
		ptrs[i] = &variants[i]
	}
	ret: Variant
	err: gdi.CallError
	gdi.object_call_script_method(obj.ptr, method, raw_data(ptrs), i64(len(args)), &ret, &err)
	for i in 0 ..< len(args) do gdi.variant_destroy(&variants[i])
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
	data := (^Callable_Data)(userdata)
	args := ([^]^Variant)(argv)[:argc]
	result := data.fn(data.user, args)
	(^Variant)(ret)^ = result
}

@(private)
callable_free :: proc "c" (userdata: rawptr) {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	free((^Callable_Data)(userdata))
}

// A Callable that calls `fn(user, args)`; pass `owner` so Godot drops it when that object dies.
callable_create :: proc(fn: Callable_Proc, user: rawptr, owner: Object = {}) -> Callable {
	data := new(Callable_Data)
	data^ = {fn, user}
	info := gdi.CallableCustomInfo2 {
		callable_userdata = data,
		token             = library,
		object_id         = owner.ptr != nil ? gdi.object_get_instance_id(owner.ptr) : 0,
		call_func         = callable_call,
		free_func         = callable_free,
	}
	callable: Callable
	gdi.callable_custom_create2(&callable, &info)
	return callable
}

// Connects `obj.signal` to a Callable (the connection keeps its own copy).
connect :: proc(obj: Object, signal: string, callable: Callable, flags: u32 = 0) {
	Object_connect(obj, signal, callable, int(flags))
}

// ---- methods described at run time

// A method whose arguments and result are Variants: `args` are borrowed, the result is owned (returned to
// Godot). `user` is the pointer given to bind_dynamic_method; `inst` the class instance.
Dynamic_Proc :: #type proc(user: rawptr, inst: rawptr, args: []^Variant) -> Variant

// One argument or the result of a dynamic method: its name and Variant type (NIL: any Variant), and for an OBJECT
// its class (typed in GDScript; "": any Object).
Dynamic_Arg :: struct {
	name:       string,
	type:       gdi.VariantType,
	class_name: string,
}

@(private)
Dynamic_Method :: struct {
	using method: Method,
	call_proc:    Dynamic_Proc,
	user:         rawptr,
	types:        []gdi.VariantType,
	result:       gdi.VariantType,
	has_result:   bool,
}

// Binds a method built at run time (e.g. from RTTI): GDScript and typed calls both reach `fn`, ptrcall
// arguments converted to Variants by their declared types. A `static` method is called on the class
// (`Class.name(...)`), with a nil instance.
bind_dynamic_method :: proc(
	cls: ^Class,
	name: string,
	fn: Dynamic_Proc,
	user: rawptr,
	args: []Dynamic_Arg,
	result: Maybe(Dynamic_Arg) = nil,
	static := false,
) {
	dynamic_method := new(Dynamic_Method)
	dynamic_method.call_proc = fn
	dynamic_method.user = user
	dynamic_method.nargs = len(args)
	dynamic_method.types = make([]gdi.VariantType, len(args))
	for argument, i in args do dynamic_method.types[i] = argument.type
	result_class := ""
	if declared, ok := result.?; ok {
		dynamic_method.result, dynamic_method.has_result = declared.type, true
		result_class = declared.class_name
	}
	dynamic_method.call = proc(
		method: ^Method,
		inst: rawptr,
		args: [^]gdi.ConstVariantPtr,
		ret: gdi.VariantPtr,
		err: ^gdi.CallError,
	) {
		dynamic_method := (^Dynamic_Method)(method)
		result := dynamic_method.call_proc(dynamic_method.user, inst, ([^]^Variant)(args)[:method.nargs])
		if dynamic_method.has_result {
			(^Variant)(ret)^ = result
		} else {
			variant_destroy(&result)
		}
	}
	dynamic_method.ptrcall = proc(method: ^Method, inst: rawptr, args: [^]gdi.ConstTypePtr, ret: gdi.TypePtr) {
		dynamic_method := (^Dynamic_Method)(method)
		variants := make([]Variant, method.nargs, context.temp_allocator)
		pointers := make([]^Variant, method.nargs, context.temp_allocator)
		for kind, i in dynamic_method.types {
			if kind == .NIL {
				gdi.variant_new_copy(&variants[i], cast(^Variant)args[i])
			} else {
				from_type(kind, &variants[i], args[i])
			}
			pointers[i] = &variants[i]
		}
		result := dynamic_method.call_proc(dynamic_method.user, inst, pointers)
		for &variant in variants do variant_destroy(&variant)
		if !dynamic_method.has_result {
			variant_destroy(&result)
			return
		}
		if dynamic_method.result == .NIL {
			gdi.variant_new_copy(cast(^Variant)ret, &result)
		} else {
			if is_opaque_builtin(dynamic_method.result) do builtin_destroy(dynamic_method.result, ret)
			to_type(dynamic_method.result, ret, &result)
		}
		variant_destroy(&result)
	}
	name_sn := string_name_from(name)
	defer StringName_destroy(&name_sn)
	empty_sn := string_name_from("")
	defer StringName_destroy(&empty_sn)
	empty_s := string_from("")
	defer String_destroy(&empty_s)
	count := len(args)
	sns := make([]StringName, count, context.temp_allocator)
	infos := make([]gdi.PropertyInfo, count + 1, context.temp_allocator)
	metas := make([]gdi.ClassMethodArgumentMetadata, count + 1, context.temp_allocator)
	classes := make([]StringName, count + 1, context.temp_allocator)
	for argument, i in args {
		sns[i] = string_name_from(argument.name)
		classes[i] = string_name_from(argument.class_name)
		infos[i] = dynamic_property_info(argument.type, &sns[i], &classes[i], &empty_s)
	}
	classes[count] = string_name_from(result_class)
	defer for &string_name in sns do StringName_destroy(&string_name)
	defer for &string_name in classes do StringName_destroy(&string_name)
	ret_info := dynamic_property_info(dynamic_method.result, &empty_sn, &classes[count], &empty_s)
	flags := gdi.ClassMethodFlags.FLAGS_DEFAULT
	if static do flags = .FLAG_STATIC
	method_info := gdi.ClassMethodInfo {
		name               = &name_sn,
		method_userdata    = &dynamic_method.method,
		call_func          = method_call,
		ptrcall_func       = method_ptrcall,
		method_flags       = u32(flags),
		has_return_value   = dynamic_method.has_result ? 1 : 0,
		return_value_info  = &ret_info,
		argument_count     = u32(count),
		arguments_info     = count > 0 ? &infos[0] : nil,
		arguments_metadata = count > 0 ? &metas[0] : nil,
	}
	gdi.classdb_register_extension_class_method(library, &cls.name_sn, &method_info)
}

@(private)
dynamic_property_info :: proc(
	kind: gdi.VariantType,
	name: ^StringName,
	class_name: ^StringName,
	hint: ^String,
) -> gdi.PropertyInfo {
	usage: u32 = 6 // PROPERTY_USAGE_DEFAULT
	if kind == .NIL do usage |= 131072 // PROPERTY_USAGE_NIL_IS_VARIANT
	return {
		type_       = kind,
		name        = name,
		class_name  = class_name,
		hint_string = hint,
		usage       = usage,
	}
}

// A property over methods already bound (`setter` "" for a read-only one), of Variant type `kind` (an OBJECT one of
// class `class_name`, typed in GDScript).
bind_property_by_name :: proc(
	cls: ^Class,
	name: string,
	kind: gdi.VariantType,
	getter: string,
	setter := "",
	class_name := "",
) {
	name_sn := string_name_from(name)
	defer StringName_destroy(&name_sn)
	class_sn := string_name_from(class_name)
	defer StringName_destroy(&class_sn)
	empty_s := string_from("")
	defer String_destroy(&empty_s)
	getter_name := string_name_from(getter)
	defer StringName_destroy(&getter_name)
	setter_name := string_name_from(setter)
	defer StringName_destroy(&setter_name)
	info := dynamic_property_info(kind, &name_sn, &class_sn, &empty_s)
	if setter == "" do info.usage = 4 | 8192 // PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY: not saved
	gdi.classdb_register_extension_class_property(library, &cls.name_sn, &info, &setter_name, &getter_name)
}

// The Odin instance behind an object of `cls` (one of this extension's classes) or a class extending it; nil for
// any other object. (object_cast can't tell: an extension class shares its native ancestor's class tag.)
instance_of :: proc(obj: Object, cls: ^Class) -> rawptr {
	if obj.ptr == nil || !Object_is_class(obj, &cls.name_sn) do return nil
	return gdi.object_get_instance_binding(obj.ptr, library, &binding_callbacks)
}

// Loads class reference XML (Godot's doc format) into the editor's help. Call at the EDITOR init level;
// a game (no editor) skips it.
load_class_docs :: proc(xml: string) {
	if gdi.editor_help_load_xml_from_utf8_chars_and_len == nil do return
	text := strings.clone_to_cstring(xml, context.temp_allocator)
	gdi.editor_help_load_xml_from_utf8_chars_and_len(text, gdi.Int(len(xml)))
}
