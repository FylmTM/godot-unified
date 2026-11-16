package cli

import "core:dynlib"

// The displays in Godot's screen order on macOS, NSScreen's: the main display (the menu bar's) first, then the other
// active displays in CoreGraphics' order, one per mirror set (a display mirroring another is no screen of its own).
// CoreGraphics is loaded only here, when --screen names a side: no other command pays for the framework.
os_screens :: proc() -> []Screen {
	library, loaded := dynlib.load_library("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")
	if !loaded {
		return nil
	}
	defer dynlib.unload_library(library)
	Rect :: struct {
		x, y, width, height: f64, // CGRect: origin and size, in global points (x grows to the right)
	}
	Get_Active_Display_List :: proc "c" (max_displays: u32, displays: [^]u32, count: ^u32) -> i32
	Display_Bounds :: proc "c" (display: u32) -> Rect
	Main_Display_ID :: proc "c" () -> u32
	Display_Mirrors_Display :: proc "c" (display: u32) -> u32
	get_list_ptr, has_list := dynlib.symbol_address(library, "CGGetActiveDisplayList")
	bounds_ptr, has_bounds := dynlib.symbol_address(library, "CGDisplayBounds")
	main_ptr, has_main := dynlib.symbol_address(library, "CGMainDisplayID")
	mirrors_ptr, has_mirrors := dynlib.symbol_address(library, "CGDisplayMirrorsDisplay")
	if !has_list || !has_bounds || !has_main || !has_mirrors {
		return nil
	}
	get_list := cast(Get_Active_Display_List)get_list_ptr
	bounds := cast(Display_Bounds)bounds_ptr
	main_id := cast(Main_Display_ID)main_ptr
	mirrors := cast(Display_Mirrors_Display)mirrors_ptr
	displays: [32]u32
	count: u32
	if get_list(len(displays), &displays[0], &count) != 0 {
		return nil
	}
	main := main_id()
	list := make([dynamic]Screen, context.temp_allocator)
	for display in displays[:count] {
		if display != main && mirrors(display) != 0 {
			continue
		}
		rect := bounds(display)
		screen := Screen{i32(rect.x), i32(rect.x + rect.width), display == main}
		if screen.primary {
			inject_at(&list, 0, screen)
		} else {
			append(&list, screen)
		}
	}
	return list[:]
}
