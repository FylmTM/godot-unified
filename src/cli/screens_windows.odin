package cli

import "base:runtime"
import win "core:sys/windows"

// The monitors in the system's order, which is Godot's screen order on Windows. Read per-monitor DPI aware, as Godot
// runs: in physical pixels, Godot's own, whatever each monitor's scale.
os_screens :: proc() -> []Screen {
	before := win.SetThreadDpiAwarenessContext(win.DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2)
	defer win.SetThreadDpiAwarenessContext(before)
	// The frame above a window's client area (title bar and border): Godot places the client area, so a window whose
	// title bar sits on the work area's top edge has its client area that much lower. Godot's frame keeps the system's
	// DPI on every monitor (it doesn't rescale it on a monitor of another scale).
	frame: win.RECT
	win.AdjustWindowRectExForDpi(&frame, win.WS_OVERLAPPEDWINDOW, false, 0, win.GetDpiForSystem())
	monitors := Monitors {
		list      = make([dynamic]Screen, context.temp_allocator),
		frame_top = -frame.top,
	}
	win.EnumDisplayMonitors(nil, nil, on_monitor, transmute(win.LPARAM)&monitors)
	return monitors.list[:]
}

// What on_monitor fills, and the frame height it places each corner by.
@(private)
Monitors :: struct {
	list:      [dynamic]Screen,
	frame_top: i32,
}

@(private)
on_monitor :: proc "system" (monitor: win.HMONITOR, _: win.HDC, _: win.LPRECT, data: win.LPARAM) -> win.BOOL {
	context = runtime.default_context()
	monitors := (^Monitors)(uintptr(data))
	info := win.MONITORINFO {
		cbSize = size_of(win.MONITORINFO),
	}
	if win.GetMonitorInfoW(monitor, &info) {
		append(
			&monitors.list,
			Screen {
				left    = info.rcMonitor.left,
				right   = info.rcMonitor.right,
				top     = info.rcMonitor.top,
				primary = info.dwFlags & 1 != 0, // MONITORINFOF_PRIMARY
				corner  = [2]i32{info.rcWork.left, info.rcWork.top + monitors.frame_top},
			},
		)
	}
	return true
}
