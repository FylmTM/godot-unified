// Thread classes and the process clock on macOS.
//
// A sleeping thread wakes late by its timer leeway (coalescing). Measured on Apple silicon (GDExtension spike): a
// sleep-until wakes 2.5-4 ms late at the default QoS and about 1 ms late inside Godot, but 10-25 µs late under
// THREAD_TIME_CONSTRAINT_POLICY (what audio threads use). So the session thread asks for a time-constraint policy:
// period one tick, ~1 ms of computation, 2 ms constraint.
//
// For a session's lifetime (`session_power_begin/end`, on the session thread) the process also asks not to be
// throttled while it is in the background, where a hosting player's game often is: App Nap (a hidden or occluded
// app's timers are coalesced and its priority lowered) is held off by a user-initiated, latency-critical
// NSProcessInfo activity. Godot holds no activity; its keep_screen_on display assertion and running audio may keep
// App Nap away, but a project can turn both off.
#+private
package godot

import "base:intrinsics"
import "core:c"
import "core:fmt"

foreign import libc "system:c"

@(default_calling_convention = "c")
foreign libc {
	mach_thread_self :: proc() -> u32 ---
	thread_policy_set :: proc(thread: u32, flavor: c.int, policy_info: rawptr, count: u32) -> c.int ---
	mach_timebase_info :: proc(info: ^[2]u32) -> c.int ---
}

// The session thread: a time-constraint policy, period one tick, ~1 ms of computation, 2 ms constraint.
set_realtime_thread :: proc(tick_hz: int) {
	timebase: [2]u32 // numer, denom: ns = units * numer / denom
	mach_timebase_info(&timebase)
	units :: proc(timebase: [2]u32, ns: u64) -> u32 {return u32(ns * u64(timebase[1]) / u64(timebase[0]))}
	Time_Constraint :: struct {
		period, computation, constraint, preemptible: u32,
	}
	period := u64(1_000_000_000 / max(tick_hz, 1))
	constraint := Time_Constraint {
		units(timebase, period),
		units(timebase, 1_000_000),
		units(timebase, 2_000_000),
		1,
	}
	if thread_policy_set(mach_thread_self(), 2, &constraint, 4) != 0 { 	// THREAD_TIME_CONSTRAINT_POLICY
		fmt.eprintln("unified: thread_policy_set(TIME_CONSTRAINT) failed")
	}
}

foreign import objc {"system:objc", "system:Foundation.framework"}

@(default_calling_convention = "c")
foreign objc {
	objc_autoreleasePoolPush :: proc() -> rawptr ---
	objc_autoreleasePoolPop :: proc(pool: rawptr) ---
}

@(objc_class = "NSObject")
Ns_Object :: struct {
	using _: intrinsics.objc_object,
}
@(objc_class = "NSProcessInfo")
Ns_Process_Info :: struct {
	using _: intrinsics.objc_object,
}
@(objc_class = "NSString")
Ns_String :: struct {
	using _: intrinsics.objc_object,
}
power_activity: ^Ns_Object // the NSProcessInfo activity token (retained)

session_power_begin :: proc() {
	if power_activity != nil do return
	pool := objc_autoreleasePoolPush() // the session thread has none
	defer objc_autoreleasePoolPop(pool)
	info := intrinsics.objc_send(^Ns_Process_Info, Ns_Process_Info, "processInfo")
	reason := intrinsics.objc_send(
		^Ns_String,
		Ns_String,
		"stringWithUTF8String:",
		cstring("unified: a game session is running"),
	)
	USER_INITIATED :: 0x00FF_FFFF // NSActivityUserInitiated: no App Nap, no idle system sleep
	LATENCY_CRITICAL :: 0xFF_0000_0000 // NSActivityLatencyCritical: timers are not coalesced
	token := intrinsics.objc_send(
		^Ns_Object,
		info,
		"beginActivityWithOptions:reason:",
		u64(USER_INITIATED | LATENCY_CRITICAL),
		reason,
	)
	if token == nil {
		fmt.eprintln("unified: beginActivityWithOptions failed")
		return
	}
	power_activity = intrinsics.objc_send(^Ns_Object, token, "retain")
}

session_power_end :: proc() {
	if power_activity == nil do return
	pool := objc_autoreleasePoolPush()
	defer objc_autoreleasePoolPop(pool)
	info := intrinsics.objc_send(^Ns_Process_Info, Ns_Process_Info, "processInfo")
	intrinsics.objc_send(nil, info, "endActivity:", power_activity)
	intrinsics.objc_send(nil, power_activity, "release")
	power_activity = nil
}
