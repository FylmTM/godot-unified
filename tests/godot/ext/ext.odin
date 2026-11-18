// The binding test extension: a class (`Tester : Node3D`, and `TesterChild` extending it) that exercises every
// binding feature of unified:gdext, typed and dynamic; tests/godot/test.gd drives it under headless Godot
// (`uni test --suite godot-bindings`).
package gdext_test_ext

import "base:runtime"
import "core:fmt"
import "unified:devui"
import gd "unified:gdext"
import "unified:gdext/gdi"

Tester :: struct {
	using hdr:     gd.Instance_Header,
	value:         i64,
	dynamic_value: i64, // the dynamic property's
	readied:       bool,
	processed:     i64,
	image:         gd.Ref(gd.Image), // kept_image's: the instance owns it
	churn:         [16]i32, // a list for the Inspector whose live element changes every frame
}

tester, tester_child: gd.Class

@(export, link_name = "gdext_test_init")
gdext_test_init :: proc "c" (
	get_proc_address: gdi.InterfaceGetProcAddress,
	library: gdi.ClassLibraryPtr,
	init: ^gdi.Initialization,
) -> gdi.Bool {
	context = runtime.default_context()
	gd.init(get_proc_address, library)
	init.minimum_initialization_level = .INITIALIZATION_SCENE
	init.initialize = proc "c" (_: rawptr, level: gdi.InitializationLevel) {
		if level != .INITIALIZATION_SCENE do return
		context = runtime.default_context()
		runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
		register()
	}
	init.deinitialize = proc "c" (_: rawptr, level: gdi.InitializationLevel) {
		if level != .INITIALIZATION_SCENE do return
		context = runtime.default_context()
		runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
		devui.shutdown()
		gd.shutdown() // unregisters both classes, the child first
	}
	return 1
}

register :: proc() {
	tester = {
		name = "Tester",
		parent = "Node3D",
		size = size_of(Tester),
		fini = proc(instance: rawptr) {
			self := (^Tester)(instance)
			gd.unref(self.image)
		},
		ready = proc(instance: rawptr) {
			(^Tester)(instance).readied = true
			devui.init({visible = true})
		},
		process = proc(instance: rawptr, dt: f64) {
			self := (^Tester)(instance)
			self.processed += 1
			self.churn = {}
			self.churn[self.processed % 16] = i32(self.processed)
			devui.inspect("tester", self^)
			devui.plot("dt ms", f32(dt * 1000))
			devui.stat("processed", "%d", self.processed)
			devui.log(u32(self.processed), .None, "frame %d", self.processed)
			devui.frame(dt)
		},
	}
	cls := &tester
	gd.register_class(cls)
	gd.bind_method(cls, "add", proc(self: ^Tester, left: i64, right: i64) -> i64 {return left + right}, {"a", "b"})
	gd.bind_method(
		cls,
		"greet",
		proc(self: ^Tester, who: string) -> string {return fmt.tprintf("hello %s", who)},
		{"who"},
	)
	gd.bind_method(cls, "scale", proc(self: ^Tester, vector: gd.Vector3, factor: f32) -> gd.Vector3 {
		return {vector.x * factor, vector.y * factor, vector.z * factor}
	}, {"v", "k"})
	gd.bind_method(cls, "make_dict", proc(self: ^Tester) -> gd.Dictionary {
		dict := gd.dict_new()
		gd.dict_set(&dict, "name", "odin")
		gd.dict_set(&dict, "n", 3)
		list := gd.array_new()
		gd.array_push(&list, 1)
		gd.array_push(&list, 2.5)
		gd.array_push(&list, "x")
		gd.dict_set(&dict, "list", list)
		gd.Array_destroy(&list)
		return dict
	})
	gd.bind_method(cls, "sum_array", proc(self: ^Tester, array: gd.Array) -> f64 {
		array := array
		sum := 0.0
		for i in 0 ..< gd.array_len(&array) {
			number, _ := gd.from_variant(f64, gd.array_at(&array, i))
			sum += number
		}
		return sum
	}, {"a"})
	gd.bind_method(
		cls,
		"node_name",
		proc(self: ^Tester, node: gd.Node) -> string {return gd.Node_get_name(node)},
		{"node"},
	)
	gd.bind_property(
		cls,
		"value",
		proc(self: ^Tester) -> i64 {return self.value},
		proc(self: ^Tester, value: i64) {self.value = value},
	)
	gd.bind_property(cls, "doubled", proc(self: ^Tester) -> i64 {return self.value * 2}) 	// read-only
	gd.bind_signal(cls, "fired", {{"n", .INT, ""}, {"msg", .STRING, ""}, {"pos", .VECTOR3, ""}}, doc = "Fired.")
	gd.bind_constant(cls, "Mode", "MODE_SLOW", 0)
	gd.bind_constant(cls, "Mode", "MODE_FAST", 7)
	gd.bind_constant(cls, "", "ANSWER", 42)
	gd.bind_method(cls, "fire", proc(self: ^Tester, number: i64) {
		gd.emit_signal(
			self.obj,
			gd.sn("fired"),
			number,
			fmt.tprintf("fired %d", number),
			gd.Vector3{f32(number), 0, 0},
		)
	}, {"n"})
	gd.bind_method(cls, "call_back", proc(self: ^Tester, value: i64) {
		result := gd.call_script(self.obj, gd.sn("_on_odin"), value)
		gd.variant_destroy(&result)
	}, {"x"})
	gd.bind_method(cls, "callable", proc(self: ^Tester) -> gd.Callable {
		return gd.callable_create(proc(_: rawptr, args: []^gd.Variant) -> gd.Variant {
				left, _ := gd.from_variant(i64, args[0])
				right, _ := gd.from_variant(i64, args[1])
				return gd.to_variant(left + right)
			}, nil, self.obj)
	})
	gd.bind_method(cls, "call_add_via_vararg", proc(self: ^Tester) -> i64 {
		result := gd.Object_call(self.obj, "add", i64(3), i64(4))
		defer gd.variant_destroy(&result)
		value, _ := gd.from_variant(i64, &result)
		return value
	})
	gd.bind_method(cls, "image_size", proc(self: ^Tester) -> i64 {
		img := gd.Image_create_empty(3, 4, false, .FORMAT_RGBA8)
		defer gd.unref(img)
		return i64(gd.Image_get_width(img) * gd.Image_get_height(img))
	})
	// A returned RefCounted: Ref(T) hands our reference over, a bare T is borrowed (Godot adds its own).
	gd.bind_method(cls, "new_image", proc(self: ^Tester) -> gd.Ref(gd.Image) {
		return gd.Image_create_empty(2, 3, false, .FORMAT_RGBA8)
	})
	gd.bind_method(cls, "kept_image", proc(self: ^Tester) -> gd.Image {
		if self.image.ptr == nil do self.image = gd.Image_create_empty(5, 1, false, .FORMAT_RGBA8)
		return self.image
	})
	gd.bind_dynamic_method(
		cls,
		"dynamic_kept_image",
		proc(_: rawptr, instance: rawptr, _: []^gd.Variant) -> gd.Variant {
			self := (^Tester)(instance)
			if self.image.ptr == nil do self.image = gd.Image_create_empty(5, 1, false, .FORMAT_RGBA8)
			return gd.variant_from_any(self.image.ref) // the Variant's reference, dropped after the call
		},
		nil,
		nil,
		gd.Dynamic_Arg{"", .OBJECT, "Image"},
	)
	// The dynamic half: a method and properties described at run time, a typed Array, instance_of.
	gd.bind_dynamic_method(cls, "dynamic_add", proc(_: rawptr, _: rawptr, args: []^gd.Variant) -> gd.Variant {
		left, _ := gd.from_variant(i64, args[0])
		right, _ := gd.from_variant(i64, args[1])
		return gd.to_variant(left + right)
	}, nil, {{"a", .INT, ""}, {"b", .INT, ""}}, gd.Dynamic_Arg{"", .INT, ""})
	gd.bind_dynamic_property(
		cls,
		{"dynamic_value", .INT, ""},
		proc(_: rawptr, instance: rawptr, _: []^gd.Variant) -> gd.Variant {return gd.to_variant(
				(^Tester)(instance).dynamic_value,
			)},
		proc(_: rawptr, instance: rawptr, args: []^gd.Variant) -> gd.Variant {
			(^Tester)(instance).dynamic_value, _ = gd.from_variant(i64, args[0])
			return gd.variant_nil()
		},
	)
	gd.bind_dynamic_property(
		cls,
		{"dynamic_parent", .OBJECT, "Node"},
		proc(_: rawptr, instance: rawptr, _: []^gd.Variant) -> gd.Variant {
			return gd.variant_from_any(gd.Node_get_parent(gd.cast_to(gd.Node, (^Tester)(instance).obj)))
		},
	)
	gd.bind_method(cls, "typed_ints", proc(self: ^Tester) -> gd.Array {
		ints := gd.array_new()
		gd.array_set_typed(&ints, .INT)
		gd.array_push(&ints, 4)
		gd.array_push(&ints, 2)
		return ints
	})
	gd.bind_method(cls, "is_tester", proc(self: ^Tester, object: gd.Object) -> bool {
		return gd.instance_of(object, &tester) != nil
	}, {"object"})
	gd.bind_method(cls, "is_readied", proc(self: ^Tester) -> bool {return self.readied})
	gd.bind_method(cls, "processed_count", proc(self: ^Tester) -> i64 {return self.processed})
	gd.bind_method(cls, "devui_items", proc(self: ^Tester) -> i64 {
		items, _ := devui.frame_stats()
		return i64(items)
	})
	// A nested callback (Odin -> Godot -> Odin) must not free or zero the caller's temp data.
	gd.bind_method(cls, "nested_temp", proc(self: ^Tester) -> bool {
		mine := fmt.tprintf("outer %d", 12345)
		result := gd.Object_call(self.obj, "greet", "inner")
		defer gd.variant_destroy(&result)
		got, _ := gd.from_variant(string, &result)
		return mine == "outer 12345" && got == "hello inner"
	})
	gd.bind_method(cls, "call_counts", proc(self: ^Tester) -> gd.Vector2i {
		return {i32(gd.call_counts.variant), i32(gd.call_counts.ptrcall)}
	})
	gd.bind_method(cls, "instances", proc(self: ^Tester) -> i64 {return i64(tester.instances)})
	// An extension class extending ours: built on the engine class (`native`), its instance a Tester.
	tester_child = {
		name   = "TesterChild",
		parent = "Tester",
		native = "Node3D",
		size   = size_of(Tester),
	}
	gd.register_class(&tester_child)
}
