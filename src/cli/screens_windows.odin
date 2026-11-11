package cli

import "base:runtime"
import win "core:sys/windows"

// The monitors in the system's order, which is Godot's screen order on Windows.
@(private)
os_screens :: proc() -> []Screen {
	list := make([dynamic]Screen, context.temp_allocator)
	win.EnumDisplayMonitors(nil, nil, on_monitor, transmute(win.LPARAM)&list)
	return list[:]
}

@(private)
on_monitor :: proc "system" (m: win.HMONITOR, _: win.HDC, _: win.LPRECT, data: win.LPARAM) -> win.BOOL {
	context = runtime.default_context()
	list := (^[dynamic]Screen)(uintptr(data))
	info := win.MONITORINFO {
		cbSize = size_of(win.MONITORINFO),
	}
	if win.GetMonitorInfoW(m, &info) {
		append(list, Screen{info.rcMonitor.left, info.rcMonitor.right, info.dwFlags & 1 != 0}) // MONITORINFOF_PRIMARY
	}
	return true
}
