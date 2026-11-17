// With UNIFIED_TEST_CRASH set (`uni selftest` runs `UNIFIED_TEST_CRASH=1 uni test --only <these two>`): one test
// crashes while it holds a lock the other waits for, the way a test that crashes inside a library holding its lock
// does. Odin's runner freezes the crashed test's thread, so the lock is never released, the waiter never ends and
// neither does the binary: uni's watchdog must kill it within seconds and name both (src/cli/testrun.odin). Built in
// every run (so vetted); idle without the variable.
package test_cli

import "core:os"
import "core:sync"
import "core:testing"
import "core:time"

// Whether the crash tests run (the variable is set).
crash_on :: proc() -> bool {
	return os.get_env("UNIFIED_TEST_CRASH", context.temp_allocator) != ""
}

@(private = "file")
crash_lock: sync.Mutex
@(private = "file")
crash_locked: bool

@(test)
crash_holding_a_lock :: proc(t: ^testing.T) {
	if !crash_on() {
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
	if !crash_on() {
		return
	}
	for !sync.atomic_load(&crash_locked) {
		time.sleep(time.Millisecond)
	}
	sync.lock(&crash_lock) // never returns: the crashed test holds it
	sync.unlock(&crash_lock)
}
