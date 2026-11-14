// `uni test --crash` (-define:UNIFIED_TEST_CRASH=true): one test crashes while it holds a lock the other waits for,
// the way a test that crashes inside a library holding its lock does. Odin's runner freezes the crashed test's
// thread, so the lock is never released, the waiter never ends and neither does the binary: uni's watchdog must kill
// it within seconds and name both (src/cli/testrun.odin). Built in every run (so vetted); idle without the define.
package test_cli

import "core:sync"
import "core:testing"
import "core:time"

CRASH :: #config(UNIFIED_TEST_CRASH, false)

@(private = "file")
crash_lock: sync.Mutex
@(private = "file")
crash_locked: bool

@(test)
crash_holding_a_lock :: proc(t: ^testing.T) {
	if !CRASH {
		return
	}
	sync.lock(&crash_lock)
	sync.atomic_store(&crash_locked, true)
	time.sleep(50 * time.Millisecond) // the waiter is blocked on the lock by now
	bad := (^int)(rawptr(uintptr(8)))
	bad^ = 1
}

@(test)
crash_waits_for_the_lock :: proc(t: ^testing.T) {
	if !CRASH {
		return
	}
	for !sync.atomic_load(&crash_locked) {
		time.sleep(time.Millisecond)
	}
	sync.lock(&crash_lock) // never returns: the crashed test holds it
	sync.unlock(&crash_lock)
}
