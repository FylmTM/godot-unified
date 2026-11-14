// The binding test extension: one class (`Tester : Node3D`) that exercises every binding feature of
// unified:gdext; tests/godot/test.gd drives it under headless Godot (`uni test --suite godot-bindings`).
package gdext_test_ext

import "base:runtime"
import "core:fmt"
import "unified:devui"
import gd "unified:gdext"
import "unified:gdext/gdi"

Tester :: struct {
	using hdr: gd.Instance_Header,
	value:     i64,
	readied:   bool,
	processed: i64,
}

tester: gd.Class

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
		gd.unregister_class(&tester)
		gd.shutdown()
	}
	return 1
}

register :: proc() {
	tester = {
		name = "Tester",
		parent = "Node3D",
		size = size_of(Tester),
		ready = proc(instance: rawptr) {
			(^Tester)(instance).readied = true
			devui.init({visible = true})
		},
		process = proc(instance: rawptr, dt: f64) {
			self := (^Tester)(instance)
			self.processed += 1
			devui.inspect("tester", self^)
			devui.plot("dt ms", f32(dt * 1000))
			devui.stat("processed", "%d", self.processed)
			devui.log(u32(self.processed), "frame %d", self.processed)
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
		gd.dict_set_move(&dict, "list", &list)
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
	gd.bind_signal(cls, "fired", {"n", i64}, {"msg", string}, {"pos", gd.Vector3})
	gd.bind_method(cls, "fire", proc(self: ^Tester, number: i64) {
		gd.emit_signal(
			self.obj,
			gd.sn("fired"),
			number,
			fmt.tprintf("fired %d", number),
			gd.Vector3{f32(number), 0, 0},
		)
	}, {"n"})
	gd.bind_script_virtual(cls, "_on_odin", {"x", i64})
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
	gd.bind_method(cls, "sn_same", proc(self: ^Tester) -> bool {return gd.sn("abc") == gd.sn("abc")})
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
}
