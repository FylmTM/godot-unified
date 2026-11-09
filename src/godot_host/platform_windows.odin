#+build windows
package godot_host

import "core:c"
import "core:fmt"
import win "core:sys/windows"

foreign import kernel32 "system:Kernel32.lib"

@(default_calling_convention = "system")
foreign kernel32 {
	SetProcessInformation :: proc(process: win.HANDLE, class: c.int, info: rawptr, size: u32) -> win.BOOL ---
}

@(private)
Power_Throttling_State :: struct {
	version, control_mask, state_mask: u32,
}
@(private)
power_on: bool

@(private)
set_power_throttling :: proc(control: u32) {
	PROCESS_POWER_THROTTLING :: 4 // PROCESS_INFORMATION_CLASS.ProcessPowerThrottling
	// control: the policies we decide (EXECUTION_SPEED 0x1, IGNORE_TIMER_RESOLUTION 0x4); state 0 = not
	// throttled. control 0 hands both back to the system.
	st := Power_Throttling_State{1, control, 0}
	_ = SetProcessInformation(win.GetCurrentProcess(), PROCESS_POWER_THROTTLING, &st, size_of(st)) // Windows 8+; best effort
}

set_thread_class :: proc(k: Thread_Class, tick_hz: int) {}

session_power_begin :: proc() {
	if power_on do return
	power_on = true
	if win.timeBeginPeriod(1) != 0 do fmt.eprintln("unified: timeBeginPeriod(1) failed")
	set_power_throttling(0x1 | 0x4)
}

session_power_end :: proc() {
	if !power_on do return
	power_on = false
	set_power_throttling(0)
	win.timeEndPeriod(1)
}
