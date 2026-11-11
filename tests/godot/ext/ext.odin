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
	gpa: gdi.InterfaceGetProcAddress,
	lib: gdi.ClassLibraryPtr,
	init: ^gdi.Initialization,
) -> gdi.Bool {
	context = runtime.default_context()
	gd.init(gpa, lib)
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
		ready = proc(i: rawptr) {
			(^Tester)(i).readied = true
			devui.init({visible = true})
		},
		process = proc(i: rawptr, dt: f64) {
			t := (^Tester)(i)
			t.processed += 1
			devui.inspect("tester", t^)
			devui.plot("dt ms", f32(dt * 1000))
			devui.stat("processed", "%d", t.processed)
			devui.log(u32(t.processed), "frame %d", t.processed)
			devui.frame(dt)
		},
	}
	c := &tester
	gd.register_class(c)
	gd.bind_method(c, "add", proc(t: ^Tester, a: i64, b: i64) -> i64 {return a + b}, {"a", "b"})
	gd.bind_method(c, "greet", proc(t: ^Tester, who: string) -> string {return fmt.tprintf("hello %s", who)}, {"who"})
	gd.bind_method(c, "scale", proc(t: ^Tester, v: gd.Vector3, k: f32) -> gd.Vector3 {
		return {v.x * k, v.y * k, v.z * k}
	}, {"v", "k"})
	gd.bind_method(c, "make_dict", proc(t: ^Tester) -> gd.Dictionary {
		d := gd.dict_new()
		gd.dict_set(&d, "name", "odin")
		gd.dict_set(&d, "n", 3)
		list := gd.array_new()
		gd.array_push(&list, 1)
		gd.array_push(&list, 2.5)
		gd.array_push(&list, "x")
		gd.dict_set_move(&d, "list", &list)
		return d
	})
	gd.bind_method(c, "sum_array", proc(t: ^Tester, a: gd.Array) -> f64 {
		a := a
		sum := 0.0
		for i in 0 ..< gd.array_len(&a) {
			x, _ := gd.from_variant(f64, gd.array_at(&a, i))
			sum += x
		}
		return sum
	}, {"a"})
	gd.bind_method(c, "node_name", proc(t: ^Tester, n: gd.Node) -> string {return gd.Node_get_name(n)}, {"node"})
	gd.bind_property(c, "value", proc(t: ^Tester) -> i64 {return t.value}, proc(t: ^Tester, v: i64) {t.value = v})
	gd.bind_signal(c, "fired", {"n", i64}, {"msg", string}, {"pos", gd.Vector3})
	gd.bind_method(c, "fire", proc(t: ^Tester, n: i64) {
		gd.emit_signal(t.obj, gd.sn("fired"), n, fmt.tprintf("fired %d", n), gd.Vector3{f32(n), 0, 0})
	}, {"n"})
	gd.bind_script_virtual(c, "_on_odin", {"x", i64})
	gd.bind_method(c, "call_back", proc(t: ^Tester, x: i64) {
		r := gd.call_script(t.obj, gd.sn("_on_odin"), x)
		gd.variant_destroy(&r)
	}, {"x"})
	gd.bind_method(c, "callable", proc(t: ^Tester) -> gd.Callable {
		return gd.callable_create(proc(_: rawptr, args: []^gd.Variant) -> gd.Variant {
				a, _ := gd.from_variant(i64, args[0])
				b, _ := gd.from_variant(i64, args[1])
				return gd.to_variant(a + b)
			}, nil, t.obj)
	})
	gd.bind_method(c, "call_add_via_vararg", proc(t: ^Tester) -> i64 {
		r := gd.Object_call(t.obj, "add", i64(3), i64(4))
		defer gd.variant_destroy(&r)
		v, _ := gd.from_variant(i64, &r)
		return v
	})
	gd.bind_method(c, "image_size", proc(t: ^Tester) -> i64 {
		img := gd.Image_create_empty(3, 4, false, .FORMAT_RGBA8)
		defer gd.unref(img)
		return i64(gd.Image_get_width(img) * gd.Image_get_height(img))
	})
	gd.bind_method(c, "sn_same", proc(t: ^Tester) -> bool {return gd.sn("abc") == gd.sn("abc")})
	gd.bind_method(c, "is_readied", proc(t: ^Tester) -> bool {return t.readied})
	gd.bind_method(c, "processed_count", proc(t: ^Tester) -> i64 {return t.processed})
	gd.bind_method(c, "devui_items", proc(t: ^Tester) -> i64 {
		items, _ := devui.frame_stats()
		return i64(items)
	})
	// A nested callback (Odin -> Godot -> Odin) must not free or zero the caller's temp data.
	gd.bind_method(c, "nested_temp", proc(t: ^Tester) -> bool {
		mine := fmt.tprintf("outer %d", 12345)
		r := gd.Object_call(t.obj, "greet", "inner")
		defer gd.variant_destroy(&r)
		got, _ := gd.from_variant(string, &r)
		return mine == "outer 12345" && got == "hello inner"
	})
	gd.bind_method(c, "call_counts", proc(t: ^Tester) -> gd.Vector2i {
		return {i32(gd.call_counts.variant), i32(gd.call_counts.ptrcall)}
	})
	gd.bind_method(c, "instances", proc(t: ^Tester) -> i64 {return i64(tester.instances)})
}
