// Odin values <-> Godot Variants and ptrcall slots. Supported Odin types:
//
//   bool; integers and enums (Variant int); f32, f64 (float); string (String; also accepts StringName and
//   NodePath when reading); Variant itself; every builtin struct (Vector3, Color, Dictionary, Array,
//   Packed*Array, Callable, StringName, RID...); every class wrapper (Object, Node3D, Ref(Image)...).
//
// Ownership: `to_variant` returns an owned Variant (variant_destroy it); builtins passed in are copied.
// `from_variant` of an opaque builtin (Array, Dictionary, String-like, Packed*) returns an owned value.
package gdext

import "base:intrinsics"
import "base:runtime"
import "core:reflect"
import "unified:gdext/gdi"

// The Variant type of an Odin type (NIL for Variant itself: "any").
variant_type_of :: proc($T: typeid) -> gdi.VariantType {
	when T == Variant {
		return .NIL
	} else when intrinsics.type_is_boolean(T) {
		return .BOOL
	} else when intrinsics.type_is_integer(T) || intrinsics.type_is_enum(T) {
		return .INT
	} else when intrinsics.type_is_float(T) {
		return .FLOAT
	} else when T == string {
		return .STRING
	} else when intrinsics.type_is_subtype_of(T, Object) {
		return .OBJECT
	} else {
		kind, ok := builtin_variant_type(T)
		assert(ok, "type has no Variant equivalent")
		return kind
	}
}

// Builtin struct types (generated layouts and opaque types) -> Variant type.
builtin_variant_type :: proc(id: typeid) -> (gdi.VariantType, bool) {
	switch id {
	case String:
		return .STRING, true
	case Vector2:
		return .VECTOR2, true
	case Vector2i:
		return .VECTOR2I, true
	case Rect2:
		return .RECT2, true
	case Rect2i:
		return .RECT2I, true
	case Vector3:
		return .VECTOR3, true
	case Vector3i:
		return .VECTOR3I, true
	case Transform2D:
		return .TRANSFORM2D, true
	case Vector4:
		return .VECTOR4, true
	case Vector4i:
		return .VECTOR4I, true
	case Plane:
		return .PLANE, true
	case Quaternion:
		return .QUATERNION, true
	case AABB:
		return .AABB, true
	case Basis:
		return .BASIS, true
	case Transform3D:
		return .TRANSFORM3D, true
	case Projection:
		return .PROJECTION, true
	case Color:
		return .COLOR, true
	case StringName:
		return .STRING_NAME, true
	case NodePath:
		return .NODE_PATH, true
	case RID:
		return .RID, true
	case Callable:
		return .CALLABLE, true
	case Signal:
		return .SIGNAL, true
	case Dictionary:
		return .DICTIONARY, true
	case Array:
		return .ARRAY, true
	case PackedByteArray:
		return .PACKED_BYTE_ARRAY, true
	case PackedInt32Array:
		return .PACKED_INT32_ARRAY, true
	case PackedInt64Array:
		return .PACKED_INT64_ARRAY, true
	case PackedFloat32Array:
		return .PACKED_FLOAT32_ARRAY, true
	case PackedFloat64Array:
		return .PACKED_FLOAT64_ARRAY, true
	case PackedStringArray:
		return .PACKED_STRING_ARRAY, true
	case PackedVector2Array:
		return .PACKED_VECTOR2_ARRAY, true
	case PackedVector3Array:
		return .PACKED_VECTOR3_ARRAY, true
	case PackedColorArray:
		return .PACKED_COLOR_ARRAY, true
	case PackedVector4Array:
		return .PACKED_VECTOR4_ARRAY, true
	}
	return .NIL, false
}

// Builtins that own memory (need a destructor); the rest are plain values.
is_opaque_builtin :: proc(kind: gdi.VariantType) -> bool {
	#partial switch kind {
	case .STRING, .STRING_NAME, .NODE_PATH, .CALLABLE, .SIGNAL, .DICTIONARY, .ARRAY:
		return true
	}
	return kind >= .PACKED_BYTE_ARRAY && kind <= .PACKED_VECTOR4_ARRAY
}

// Runtime version of variant_type_of (for signal and script-virtual signatures given as typeids).
variant_type_of_id :: proc(id: typeid) -> gdi.VariantType {
	if id == Variant do return .NIL
	if kind, ok := builtin_variant_type(id); ok do return kind
	info := runtime.type_info_base(type_info_of(id))
	#partial switch _ in info.variant {
	case runtime.Type_Info_Boolean:
		return .BOOL
	case runtime.Type_Info_Integer, runtime.Type_Info_Enum:
		return .INT
	case runtime.Type_Info_Float:
		return .FLOAT
	case runtime.Type_Info_String:
		return .STRING
	}
	if is_object_type(id) do return .OBJECT
	return .NIL
}

// Class wrappers are structs whose `using` chain ends at Object{ptr}.
is_object_type :: proc(id: typeid) -> bool {
	cur := id
	for {
		if cur == Object do return true
		info := runtime.type_info_base(type_info_of(cur))
		struct_info, ok := info.variant.(runtime.Type_Info_Struct)
		if !ok || struct_info.field_count == 0 || !struct_info.usings[0] do return false
		cur = struct_info.types[0].id
	}
}

// The type of the value a Variant holds.
variant_type :: proc(variant: ^Variant) -> gdi.VariantType {
	return gdi.variant_get_type(variant)
}

// A nil Variant: the "no value" result of a dynamic method or Callable, and a default for Dictionary lookups.
variant_nil :: proc() -> Variant {
	result: Variant
	gdi.variant_new_nil(&result)
	return result
}

// Frees what a Variant owns (a String, a reference to an Array or object...). Every owned Variant ends here.
variant_destroy :: proc(variant: ^Variant) {
	gdi.variant_destroy(variant)
}

// An owned copy of a Variant. Arrays, Dictionaries and objects are shared by reference, not deep-copied.
variant_copy :: proc(variant: ^Variant) -> Variant {
	result: Variant
	gdi.variant_new_copy(&result, variant)
	return result
}

@(private)
from_type :: proc(kind: gdi.VariantType, dst: ^Variant, src: rawptr) {
	@(static) ctors: [gdi.VariantType]gdi.VariantFromTypeConstructorFunc
	if ctors[kind] == nil do ctors[kind] = gdi.get_variant_from_type_constructor(kind)
	ctors[kind](dst, src)
}

@(private)
to_type :: proc(kind: gdi.VariantType, dst: rawptr, src: ^Variant) {
	@(static) ctors: [gdi.VariantType]gdi.TypeFromVariantConstructorFunc
	if ctors[kind] == nil do ctors[kind] = gdi.get_variant_to_type_constructor(kind)
	ctors[kind](dst, src)
}

// Destroys an opaque builtin value of type `kind` in place.
builtin_destroy :: proc(kind: gdi.VariantType, ptr: rawptr) {
	@(static) dtors: [gdi.VariantType]gdi.PtrDestructor
	if dtors[kind] == nil do dtors[kind] = gdi.variant_get_ptr_destructor(kind)
	if dtors[kind] != nil do dtors[kind](ptr)
}

// ---- Odin value -> owned Variant

// Converts an Odin value into a new, owned Variant (variant_destroy it): strings become String, enums int; builtins
// are copied.
to_variant :: proc(value: $T) -> Variant {
	result: Variant
	when T == Variant {
		value := value
		gdi.variant_new_copy(&result, &value)
	} else when intrinsics.type_is_boolean(T) {
		as_bool := u8(value)
		from_type(.BOOL, &result, &as_bool)
	} else when intrinsics.type_is_integer(T) || intrinsics.type_is_enum(T) {
		as_int := i64(value)
		from_type(.INT, &result, &as_int)
	} else when intrinsics.type_is_float(T) {
		as_float := f64(value)
		from_type(.FLOAT, &result, &as_float)
	} else when T == string {
		text := string_from(value)
		from_type(.STRING, &result, &text)
		String_destroy(&text)
	} else when intrinsics.type_is_subtype_of(T, Object) {
		ptr := value.ptr
		from_type(.OBJECT, &result, &ptr)
	} else {
		value := value
		from_type(variant_type_of(T), &result, &value)
	}
	return result
}

// An owned Variant holding a StringName (not a String) for `text`, for an argument Godot declares as StringName
// (generated vararg wrappers) or an enum value that reaches scripts as its name (`&"name"`).
variant_string_name :: proc(text: string) -> Variant {
	result: Variant
	name := string_name_from(text)
	from_type(.STRING_NAME, &result, &name)
	StringName_destroy(&name)
	return result
}

// An owned Variant holding a NodePath parsed from `text`, for an argument Godot declares as NodePath.
variant_node_path :: proc(text: string) -> Variant {
	result: Variant
	path := node_path_from(text)
	from_type(.NODE_PATH, &result, &path)
	NodePath_destroy(&path)
	return result
}

// Dynamic version of to_variant (vararg calls, signals).
variant_from_any :: proc(value: any) -> Variant {
	result: Variant
	if value.data == nil {
		gdi.variant_new_nil(&result)
		return result
	}
	if kind, ok := builtin_variant_type(value.id); ok {
		from_type(kind, &result, value.data)
		return result
	}
	if value.id == Variant {
		gdi.variant_new_copy(&result, (^Variant)(value.data))
		return result
	}
	id := runtime.typeid_base(value.id)
	switch id {
	case Variant:
		gdi.variant_new_copy(&result, (^Variant)(value.data))
		return result
	case string:
		return to_variant((^string)(value.data)^)
	case cstring:
		return to_variant(string((^cstring)(value.data)^))
	}
	if kind, ok := builtin_variant_type(id); ok {
		from_type(kind, &result, value.data)
		return result
	}
	info := runtime.type_info_base(type_info_of(id))
	#partial switch _ in info.variant {
	case runtime.Type_Info_Boolean:
		as_bool := u8(reflect.as_bool(value) or_else false)
		from_type(.BOOL, &result, &as_bool)
		return result
	case runtime.Type_Info_Integer, runtime.Type_Info_Enum:
		as_int := reflect.as_i64(value) or_else 0
		from_type(.INT, &result, &as_int)
		return result
	case runtime.Type_Info_Float:
		as_float := reflect.as_f64(value) or_else 0
		from_type(.FLOAT, &result, &as_float)
		return result
	}
	if is_object_type(value.id) || is_object_type(id) {
		from_type(.OBJECT, &result, value.data) // the struct is exactly the Object* field
		return result
	}
	print_error("variant_from_any: unsupported type")
	gdi.variant_new_nil(&result)
	return result
}

// ---- Variant -> Odin value (ints and floats convert into each other; ok = false on a mismatch)

// Reads a Variant as `T`; ok is false when it holds another type. Ints, floats and bools convert into each other;
// a string reads String, StringName or NodePath. Reading a Variant as Variant borrows it.
from_variant :: proc($T: typeid, variant: ^Variant) -> (result: T, ok: bool) {
	kind := gdi.variant_get_type(variant)
	when T == Variant {
		_ = kind
		return variant^, true // borrowed
	} else when intrinsics.type_is_boolean(T) {
		if kind != .BOOL do return
		flag: u8
		to_type(.BOOL, &flag, variant)
		return flag != 0, true
	} else when intrinsics.type_is_integer(T) || intrinsics.type_is_enum(T) || intrinsics.type_is_float(T) {
		as_int: i64
		as_float: f64
		#partial switch kind {
		case .INT:
			to_type(.INT, &as_int, variant)
			as_float = f64(as_int)
		case .FLOAT:
			to_type(.FLOAT, &as_float, variant)
			as_int = i64(as_float)
		case .BOOL:
			flag: u8
			to_type(.BOOL, &flag, variant)
			as_int, as_float = i64(flag), f64(flag)
		case:
			return
		}
		when intrinsics.type_is_float(T) {
			return T(as_float), true
		} else {
			return T(as_int), true
		}
	} else when T == string {
		#partial switch kind {
		case .STRING:
			text: String
			to_type(.STRING, &text, variant)
			defer String_destroy(&text)
			return string_to_odin(&text), true
		case .STRING_NAME:
			text: StringName
			to_type(.STRING_NAME, &text, variant)
			defer StringName_destroy(&text)
			return string_name_to_odin(&text), true
		case .NODE_PATH:
			text: NodePath
			to_type(.NODE_PATH, &text, variant)
			defer NodePath_destroy(&text)
			return node_path_to_odin(&text), true
		}
		return
	} else when intrinsics.type_is_subtype_of(T, Object) {
		if kind == .NIL do return {}, true
		if kind != .OBJECT do return
		ptr: rawptr
		to_type(.OBJECT, &ptr, variant)
		return transmute(T)ptr, true
	} else {
		want := variant_type_of(T)
		if kind != want do return
		to_type(want, &result, variant)
		return result, true
	}
}

// ---- ptrcall slots (arguments are borrowed for the duration of the call)

// Reads a ptrcall argument slot as `T` (the typed-call path of bound methods). Variants and builtins come back as
// borrowed views; strings are copied into the temp allocator.
from_ptr :: proc($T: typeid, ptr: rawptr) -> T {
	when intrinsics.type_is_boolean(T) {
		return (^u8)(ptr)^ != 0
	} else when intrinsics.type_is_integer(T) || intrinsics.type_is_enum(T) {
		return T((^i64)(ptr)^)
	} else when intrinsics.type_is_float(T) {
		return T((^f64)(ptr)^)
	} else when T == string {
		return string_to_odin((^String)(ptr))
	} else when intrinsics.type_is_subtype_of(T, Object) {
		return transmute(T)(^rawptr)(ptr)^
	} else {
		return (^T)(ptr)^ // Variant and builtins: a borrowed bitwise view
	}
}

// Writes a return value into a ptrcall slot. Opaque builtins move into the (constructed) slot. A RefCounted's slot is a
// reference of Godot's: a `Ref(T)` result hands ours over, a bare `T` is borrowed (the slot takes its own).
to_ptr :: proc(value: $T, ptr: rawptr) {
	when intrinsics.type_is_boolean(T) {
		(^u8)(ptr)^ = u8(value)
	} else when intrinsics.type_is_integer(T) || intrinsics.type_is_enum(T) {
		(^i64)(ptr)^ = i64(value)
	} else when intrinsics.type_is_float(T) {
		(^f64)(ptr)^ = f64(value)
	} else when T == string {
		String_destroy((^String)(ptr))
		(^String)(ptr)^ = string_from(value)
	} else when intrinsics.type_is_specialization_of(T, Ref) {
		gdi.ref_set_object(ptr, value.ptr)
		unref(RefCounted{{value.ptr}})
	} else when intrinsics.type_is_subtype_of(T, RefCounted) {
		gdi.ref_set_object(ptr, value.ptr)
	} else when intrinsics.type_is_subtype_of(T, Object) {
		(^rawptr)(ptr)^ = value.ptr
	} else when T == Variant {
		gdi.variant_destroy((^Variant)(ptr))
		(^Variant)(ptr)^ = value
	} else {
		kind := variant_type_of(T)
		if is_opaque_builtin(kind) do builtin_destroy(kind, ptr)
		(^T)(ptr)^ = value
	}
}

// Writes an owned return value into a Variant slot (moves opaque builtins; the Variant takes a reference of a
// RefCounted of its own: a `Ref(T)` result's is dropped, a bare `T` is borrowed).
to_variant_slot :: proc(value: $T, slot: ^Variant) {
	gdi.variant_destroy(slot)
	slot^ = to_variant(value)
	when intrinsics.type_is_specialization_of(T, Ref) {
		unref(RefCounted{{value.ptr}})
	} else when T != Variant && !intrinsics.type_is_subtype_of(T, Object) && T != string {
		when !intrinsics.type_is_boolean(
			T,
		) && !intrinsics.type_is_integer(T) && !intrinsics.type_is_enum(T) && !intrinsics.type_is_float(T) {
			kind := variant_type_of(T)
			if is_opaque_builtin(kind) {
				value := value
				builtin_destroy(kind, &value)
			}
		}
	} else when T == Variant {
		value := value
		gdi.variant_destroy(&value)
	}
}

// Releases a value produced by from_variant (opaque builtins only).
release :: proc(value: ^$T) {
	when T != Variant && T != string && !intrinsics.type_is_subtype_of(T, Object) {
		when !intrinsics.type_is_boolean(
			T,
		) && !intrinsics.type_is_integer(T) && !intrinsics.type_is_enum(T) && !intrinsics.type_is_float(T) {
			kind := variant_type_of(T)
			if is_opaque_builtin(kind) do builtin_destroy(kind, value)
		}
	}
}

// ---- Dictionary and Array helpers (String keys, like GDScript literals)

// A new, empty Dictionary the caller owns until it hands it on (returns it from a bound method, dict_set_move).
dict_new :: proc() -> Dictionary {
	return Dictionary_new0()
}

// Sets dict[key] to `value` converted with to_variant (a builtin is copied). Keys are Strings, as in GDScript
// literals.
dict_set :: proc(dict: ^Dictionary, key: string, value: $T) {
	key_variant := to_variant(key)
	defer gdi.variant_destroy(&key_variant)
	slot := (^Variant)(gdi.dictionary_operator_index(dict, &key_variant))
	gdi.variant_destroy(slot)
	slot^ = to_variant(value)
}

// Moves an owned Dictionary/Array value into d[key].
dict_set_move :: proc(dict: ^Dictionary, key: string, value: ^$T) {
	dict_set(dict, key, value^)
	release(value)
}

// A new, empty Array the caller owns until it hands it on (returns it from a bound method, array_push_move).
array_new :: proc() -> Array {
	return Array_new0()
}

// Appends `value` converted with to_variant (a builtin is copied).
array_push :: proc(array: ^Array, value: $T) {
	variant := to_variant(value)
	defer gdi.variant_destroy(&variant)
	Array_push_back(array, variant)
}

// Moves an owned Dictionary/Array value onto the end of a.
array_push_move :: proc(array: ^Array, value: ^$T) {
	array_push(array, value^)
	release(value)
}

// The number of elements in the Array.
array_len :: proc(array: ^Array) -> int {
	return int(Array_size(array))
}

// The element at `index`, borrowed: a pointer into the Array, read with from_variant.
array_at :: proc(array: ^Array, index: int) -> ^Variant {
	return (^Variant)(gdi.array_operator_index(array, i64(index)))
}
