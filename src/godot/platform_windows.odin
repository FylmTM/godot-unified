#+build windows
package godot

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
	throttling := Power_Throttling_State{1, control, 0}
	_ = SetProcessInformation(win.GetCurrentProcess(), PROCESS_POWER_THROTTLING, &throttling, size_of(throttling)) // Windows 8+; best effort
}

// Nothing on Windows: the session thread keeps its class; the 1 ms timer resolution session_power_begin asks for
// is what makes its sleeps wake on time.
set_realtime_thread :: proc(tick_hz: int) {}

// Starts a session's power requests (session thread): 1 ms timer resolution and no power throttling, so a game
// hosting in the background keeps its tick rate. Paired with session_power_end; a second call does nothing.
session_power_begin :: proc() {
	if power_on do return
	power_on = true
	if win.timeBeginPeriod(1) != 0 do fmt.eprintln("unified: timeBeginPeriod(1) failed")
	set_power_throttling(0x1 | 0x4)
}

// Hands the timer resolution and power throttling back to the system when the session ends; does nothing unless
// session_power_begin ran.
session_power_end :: proc() {
	if !power_on do return
	power_on = false
	set_power_throttling(0)
	win.timeEndPeriod(1)
}

// Whether a process with this id runs (any process, not only a child).
process_alive :: proc(pid: int) -> bool {
	if pid <= 0 do return false
	SYNCHRONIZE :: 0x0010_0000
	handle := win.OpenProcess(SYNCHRONIZE, false, win.DWORD(pid))
	if handle == nil do return false
	defer win.CloseHandle(handle)
	return win.WaitForSingleObject(handle, 0) == win.WAIT_TIMEOUT
}
