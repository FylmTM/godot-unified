// Nested values read from the game's classes (src/godot/README.md, Data and classes): a field that reads as an object
// (a nested struct), an Array or a Dictionary keeps one cached value per object that holds the field, so a script that
// reads an unchanged field makes nothing. The value is the same while the field's bytes are those it was made from.
// When they change, a struct's object is refilled in place if only the cache holds it, else the cache lets it go (the
// script keeps it as it was) and makes another; an Array or a Dictionary is made anew, read-only (an extension can't
// read an Array's reference count, so it is never refilled). A script that sets a field of a cached object, the value
// itself or a struct element of a cached Array, detaches it: the cache never hands that value out again.
#+private
package godot

import "base:runtime"
import gd "unified:gdext"
import "unified:gdext/gdi"

// One field's cached value, and the bytes it was made from.
Value_Cache :: struct {
	held:     gd.Variant, // the cache's reference to the value (made: set)
	bytes:    []u8, // the field's bytes the value was made from (allocated at the first read)
	members:  [dynamic]^Data_Object, // the nested objects in the value (a struct's: the value), each pointing back
	made:     bool,
	detached: bool, // a script set a field of one of its members: let go at the next read
}

// A field's value from `bytes` (field_kind says as what), the cached one when the field reads as an object, an Array
// or a Dictionary. `caches` is the holder's, one per field of its class (`field_count`), made at its first such read.
cached_field_variant :: proc(
	caches: ^[]Value_Cache,
	field_count: int,
	field: ^Sim_Field,
	bytes: []u8,
	units: Units,
) -> gd.Variant {
	#partial switch field.kind {
	case .OBJECT, .ARRAY, .DICTIONARY:
	case:
		return field_variant(field.type, bytes, units)
	}
	if caches^ == nil do caches^ = make([]Value_Cache, field_count, runtime.heap_allocator())
	cache := &caches[field.index]
	if cache.made && !cache.detached {
		if string(cache.bytes) == string(bytes) do return variant_copy(&cache.held)
		// a struct's object nothing but the cache holds: refilled in place
		if field.kind == .OBJECT && len(cache.members) == 1 {
			member := cache.members[0]
			if gd.RefCounted_get_reference_count(transmute(gd.RefCounted)member.obj) == 1 {
				nested_fill(D.nested[field.type.id], member.obj, bytes, units)
				copy(cache.bytes, bytes)
				return variant_copy(&cache.held)
			}
		}
	}
	value_cache_drop(cache)
	cache.held = field_variant(field.type, bytes, units, cache)
	cache.made = true
	if cache.bytes == nil do cache.bytes = make([]u8, len(bytes), runtime.heap_allocator())
	copy(cache.bytes, bytes)
	return variant_copy(&cache.held)
}

// A new reference to the value a Variant holds (a getter's result: the caller owns it).
variant_copy :: proc(value: ^gd.Variant) -> gd.Variant {
	result: gd.Variant
	gdi.variant_new_copy(&result, value)
	return result
}

// Lets go of a cached value: its members stop pointing back, and it is freed unless a script holds it.
value_cache_drop :: proc(cache: ^Value_Cache) {
	for member in cache.members do member.cache = nil
	clear(&cache.members)
	if cache.made do gd.variant_destroy(&cache.held)
	cache.held = {}
	cache.made, cache.detached = false, false
}

// Lets go of a holder's cached values and frees them (the holder is freed).
value_caches_free :: proc(caches: ^[]Value_Cache) {
	for &cache in caches^ {
		value_cache_drop(&cache)
		delete(cache.members)
		delete(cache.bytes, runtime.heap_allocator())
	}
	delete(caches^, runtime.heap_allocator())
	caches^ = nil
}

// A script set a field of a nested object: the cached value it belongs to (if any) is never handed out again.
value_detach :: proc(object: ^Data_Object) {
	if object.cache != nil do object.cache.detached = true
}
