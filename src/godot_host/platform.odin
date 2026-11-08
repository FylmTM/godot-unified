// Thread classes and the process clock.
//
// macOS: a sleeping thread wakes late by its timer leeway (coalescing). Measured on an M4 Pro (GDExtension
// spike): a sleep-until wakes 2.5-4 ms late at the default QoS and about 1 ms late inside Godot, but 10-25 µs
// late under THREAD_TIME_CONSTRAINT_POLICY (what audio threads use). So the session thread asks for a
// time-constraint policy: period one tick, ~1 ms of computation, 2 ms constraint. Elsewhere: no-op for now
// (Windows: netcode raises the timer resolution; Linux: plain sleeps, to be measured in CI).
package godot_host

import "core:c"
import "core:fmt"

Thread_Class :: enum {
	Default,
	Interactive, // QOS_CLASS_USER_INTERACTIVE
	Realtime, // THREAD_TIME_CONSTRAINT_POLICY
}

when ODIN_OS == .Darwin {
	foreign import libc "system:c"

	@(default_calling_convention = "c")
	foreign libc {
		pthread_set_qos_class_self_np :: proc(qos: c.uint, relative_priority: c.int) -> c.int ---
		mach_thread_self :: proc() -> u32 ---
		thread_policy_set :: proc(thread: u32, flavor: c.int, policy_info: rawptr, count: u32) -> c.int ---
		mach_timebase_info :: proc(info: ^[2]u32) -> c.int ---
	}

	set_thread_class :: proc(k: Thread_Class, tick_hz: int) {
		switch k {
		case .Default:
		case .Interactive:
			pthread_set_qos_class_self_np(0x21, 0)
		case .Realtime:
			tb: [2]u32 // numer, denom: ns = units * numer / denom
			mach_timebase_info(&tb)
			units :: proc(tb: [2]u32, ns: u64) -> u32 {return u32(ns * u64(tb[1]) / u64(tb[0]))}
			Time_Constraint :: struct {
				period, computation, constraint, preemptible: u32,
			}
			period := u64(1_000_000_000 / max(tick_hz, 1))
			tc := Time_Constraint{units(tb, period), units(tb, 1_000_000), units(tb, 2_000_000), 1}
			if thread_policy_set(mach_thread_self(), 2, &tc, 4) != 0 { 	// THREAD_TIME_CONSTRAINT_POLICY
				fmt.eprintln("unified: thread_policy_set(TIME_CONSTRAINT) failed")
			}
		}
	}
} else {
	_ :: c
	_ :: fmt
	set_thread_class :: proc(k: Thread_Class, tick_hz: int) {}
}
