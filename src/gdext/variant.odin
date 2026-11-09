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
		vt, ok := builtin_variant_type(T)
		assert(ok, "type has no Variant equivalent")
		return vt
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
is_opaque_builtin :: proc(vt: gdi.VariantType) -> bool {
	#partial switch vt {
	case .STRING, .STRING_NAME, .NODE_PATH, .CALLABLE, .SIGNAL, .DICTIONARY, .ARRAY:
		return true
	}
	return vt >= .PACKED_BYTE_ARRAY && vt <= .PACKED_VECTOR4_ARRAY
}

// Runtime version of variant_type_of (for signal and script-virtual signatures given as typeids).
variant_type_of_id :: proc(id: typeid) -> gdi.VariantType {
	if id == Variant do return .NIL
	if vt, ok := builtin_variant_type(id); ok do return vt
	ti := runtime.type_info_base(type_info_of(id))
	#partial switch _ in ti.variant {
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
		ti := runtime.type_info_base(type_info_of(cur))
		s, ok := ti.variant.(runtime.Type_Info_Struct)
		if !ok || s.field_count == 0 || !s.usings[0] do return false
		cur = s.types[0].id
	}
}

variant_type :: proc(v: ^Variant) -> gdi.VariantType {
	return gdi.variant_get_type(v)
}

variant_nil :: proc() -> Variant {
	r: Variant
	gdi.variant_new_nil(&r)
	return r
}

variant_destroy :: proc(v: ^Variant) {
	gdi.variant_destroy(v)
}

variant_copy :: proc(v: ^Variant) -> Variant {
	r: Variant
	gdi.variant_new_copy(&r, v)
	return r
}

@(private)
from_type :: proc(vt: gdi.VariantType, dst: ^Variant, src: rawptr) {
	@(static) ctors: [gdi.VariantType]gdi.VariantFromTypeConstructorFunc
	if ctors[vt] == nil do ctors[vt] = gdi.get_variant_from_type_constructor(vt)
	ctors[vt](dst, src)
}

@(private)
to_type :: proc(vt: gdi.VariantType, dst: rawptr, src: ^Variant) {
	@(static) ctors: [gdi.VariantType]gdi.TypeFromVariantConstructorFunc
	if ctors[vt] == nil do ctors[vt] = gdi.get_variant_to_type_constructor(vt)
	ctors[vt](dst, src)
}

// Destroys an opaque builtin value of type vt in place.
builtin_destroy :: proc(vt: gdi.VariantType, p: rawptr) {
	@(static) dtors: [gdi.VariantType]gdi.PtrDestructor
	if dtors[vt] == nil do dtors[vt] = gdi.variant_get_ptr_destructor(vt)
	if dtors[vt] != nil do dtors[vt](p)
}

// ---- Odin value -> owned Variant

to_variant :: proc(v: $T) -> Variant {
	r: Variant
	when T == Variant {
		v := v
		gdi.variant_new_copy(&r, &v)
	} else when intrinsics.type_is_boolean(T) {
		b := u8(v)
		from_type(.BOOL, &r, &b)
	} else when intrinsics.type_is_integer(T) || intrinsics.type_is_enum(T) {
		i := i64(v)
		from_type(.INT, &r, &i)
	} else when intrinsics.type_is_float(T) {
		f := f64(v)
		from_type(.FLOAT, &r, &f)
	} else when T == string {
		s := string_from(v)
		from_type(.STRING, &r, &s)
		String_destroy(&s)
	} else when intrinsics.type_is_subtype_of(T, Object) {
		p := v.ptr
		from_type(.OBJECT, &r, &p)
	} else {
		v := v
		from_type(variant_type_of(T), &r, &v)
	}
	return r
}

variant_string_name :: proc(s: string) -> Variant {
	r: Variant
	n := string_name_from(s)
	from_type(.STRING_NAME, &r, &n)
	StringName_destroy(&n)
	return r
}

variant_node_path :: proc(s: string) -> Variant {
	r: Variant
	n := node_path_from(s)
	from_type(.NODE_PATH, &r, &n)
	NodePath_destroy(&n)
	return r
}

// Dynamic version of to_variant (vararg calls, signals).
variant_from_any :: proc(a: any) -> Variant {
	r: Variant
	if a.data == nil {
		gdi.variant_new_nil(&r)
		return r
	}
	if vt, ok := builtin_variant_type(a.id); ok {
		from_type(vt, &r, a.data)
		return r
	}
	id := runtime.typeid_base(a.id)
	switch id {
	case Variant:
		gdi.variant_new_copy(&r, (^Variant)(a.data))
		return r
	case string:
		return to_variant((^string)(a.data)^)
	case cstring:
		return to_variant(string((^cstring)(a.data)^))
	}
	if vt, ok := builtin_variant_type(id); ok {
		from_type(vt, &r, a.data)
		return r
	}
	ti := runtime.type_info_base(type_info_of(id))
	#partial switch _ in ti.variant {
	case runtime.Type_Info_Boolean:
		b := u8(reflect.as_bool(a) or_else false)
		from_type(.BOOL, &r, &b)
		return r
	case runtime.Type_Info_Integer, runtime.Type_Info_Enum:
		i := reflect.as_i64(a) or_else 0
		from_type(.INT, &r, &i)
		return r
	case runtime.Type_Info_Float:
		f := reflect.as_f64(a) or_else 0
		from_type(.FLOAT, &r, &f)
		return r
	}
	if is_object_type(id) {
		from_type(.OBJECT, &r, a.data) // the struct is exactly the Object* field
		return r
	}
	print_error("variant_from_any: unsupported type")
	gdi.variant_new_nil(&r)
	return r
}

// ---- Variant -> Odin value (ints and floats convert into each other; ok = false on a mismatch)

from_variant :: proc($T: typeid, v: ^Variant) -> (r: T, ok: bool) {
	vt := gdi.variant_get_type(v)
	when T == Variant {
		return v^, true // borrowed
	} else when intrinsics.type_is_boolean(T) {
		if vt != .BOOL do return
		b: u8
		to_type(.BOOL, &b, v)
		return b != 0, true
	} else when intrinsics.type_is_integer(T) || intrinsics.type_is_enum(T) || intrinsics.type_is_float(T) {
		i: i64
		f: f64
		#partial switch vt {
		case .INT:
			to_type(.INT, &i, v)
			f = f64(i)
		case .FLOAT:
			to_type(.FLOAT, &f, v)
			i = i64(f)
		case .BOOL:
			b: u8
			to_type(.BOOL, &b, v)
			i, f = i64(b), f64(b)
		case:
			return
		}
		when intrinsics.type_is_float(T) {
			return T(f), true
		} else {
			return T(i), true
		}
	} else when T == string {
		#partial switch vt {
		case .STRING:
			s: String
			to_type(.STRING, &s, v)
			defer String_destroy(&s)
			return string_to_odin(&s), true
		case .STRING_NAME:
			s: StringName
			to_type(.STRING_NAME, &s, v)
			defer StringName_destroy(&s)
			return string_name_to_odin(&s), true
		case .NODE_PATH:
			s: NodePath
			to_type(.NODE_PATH, &s, v)
			defer NodePath_destroy(&s)
			return node_path_to_odin(&s), true
		}
		return
	} else when intrinsics.type_is_subtype_of(T, Object) {
		if vt == .NIL do return {}, true
		if vt != .OBJECT do return
		p: rawptr
		to_type(.OBJECT, &p, v)
		return transmute(T)p, true
	} else {
		want := variant_type_of(T)
		if vt != want do return
		to_type(want, &r, v)
		return r, true
	}
}

// ---- ptrcall slots (arguments are borrowed for the duration of the call)

from_ptr :: proc($T: typeid, p: rawptr) -> T {
	when intrinsics.type_is_boolean(T) {
		return (^u8)(p)^ != 0
	} else when intrinsics.type_is_integer(T) || intrinsics.type_is_enum(T) {
		return T((^i64)(p)^)
	} else when intrinsics.type_is_float(T) {
		return T((^f64)(p)^)
	} else when T == string {
		return string_to_odin((^String)(p))
	} else when intrinsics.type_is_subtype_of(T, Object) {
		return transmute(T)(^rawptr)(p)^
	} else {
		return (^T)(p)^ // Variant and builtins: a borrowed bitwise view
	}
}

// Writes a return value into a ptrcall slot. Opaque builtins move into the (constructed) slot.
to_ptr :: proc(v: $T, p: rawptr) {
	when intrinsics.type_is_boolean(T) {
		(^u8)(p)^ = u8(v)
	} else when intrinsics.type_is_integer(T) || intrinsics.type_is_enum(T) {
		(^i64)(p)^ = i64(v)
	} else when intrinsics.type_is_float(T) {
		(^f64)(p)^ = f64(v)
	} else when T == string {
		String_destroy((^String)(p))
		(^String)(p)^ = string_from(v)
	} else when intrinsics.type_is_subtype_of(T, Object) {
		(^rawptr)(p)^ = v.ptr
	} else when T == Variant {
		gdi.variant_destroy((^Variant)(p))
		(^Variant)(p)^ = v
	} else {
		vt := variant_type_of(T)
		if is_opaque_builtin(vt) do builtin_destroy(vt, p)
		(^T)(p)^ = v
	}
}

// Writes an owned return value into a Variant slot (moves opaque builtins).
to_variant_slot :: proc(v: $T, slot: ^Variant) {
	gdi.variant_destroy(slot)
	slot^ = to_variant(v)
	when T != Variant && !intrinsics.type_is_subtype_of(T, Object) && T != string {
		when !intrinsics.type_is_boolean(
			T,
		) && !intrinsics.type_is_integer(T) && !intrinsics.type_is_enum(T) && !intrinsics.type_is_float(T) {
			vt := variant_type_of(T)
			if is_opaque_builtin(vt) {
				v := v
				builtin_destroy(vt, &v)
			}
		}
	} else when T == Variant {
		v := v
		gdi.variant_destroy(&v)
	}
}

// Releases a value produced by from_variant (opaque builtins only).
release :: proc(v: ^$T) {
	when T != Variant && T != string && !intrinsics.type_is_subtype_of(T, Object) {
		when !intrinsics.type_is_boolean(
			T,
		) && !intrinsics.type_is_integer(T) && !intrinsics.type_is_enum(T) && !intrinsics.type_is_float(T) {
			vt := variant_type_of(T)
			if is_opaque_builtin(vt) do builtin_destroy(vt, v)
		}
	}
}

// ---- Dictionary and Array helpers (String keys, like GDScript literals)

dict_new :: proc() -> Dictionary {
	return Dictionary_new0()
}

dict_set :: proc(d: ^Dictionary, key: string, value: $T) {
	k := to_variant(key)
	defer gdi.variant_destroy(&k)
	slot := (^Variant)(gdi.dictionary_operator_index(d, &k))
	gdi.variant_destroy(slot)
	slot^ = to_variant(value)
}

// Moves an owned Dictionary/Array value into d[key].
dict_set_move :: proc(d: ^Dictionary, key: string, value: ^$T) {
	dict_set(d, key, value^)
	release(value)
}

dict_get :: proc(d: ^Dictionary, $T: typeid, key: string) -> (T, bool) {
	k := to_variant(key)
	defer gdi.variant_destroy(&k)
	slot := (^Variant)(gdi.dictionary_operator_index_const(d, &k))
	if slot == nil do return {}, false
	return from_variant(T, slot)
}

array_new :: proc() -> Array {
	return Array_new0()
}

array_push :: proc(a: ^Array, value: $T) {
	v := to_variant(value)
	defer gdi.variant_destroy(&v)
	Array_push_back(a, v)
}

// Moves an owned Dictionary/Array value onto the end of a.
array_push_move :: proc(a: ^Array, value: ^$T) {
	array_push(a, value^)
	release(value)
}

array_len :: proc(a: ^Array) -> int {
	return int(Array_size(a))
}

array_at :: proc(a: ^Array, i: int) -> ^Variant {
	return (^Variant)(gdi.array_operator_index(a, i64(i)))
}
