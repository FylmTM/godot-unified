// #262: the session's steady state allocates nothing, on the heap or the temp allocator: queued messages, loopback
// datagrams, the netsim's delayed datagrams and early reliable messages live in reused buffers, the kept desync
// images reuse theirs.
package test_netcode

import "base:runtime"
import "core:testing"

// Counts what goes through it to the allocator it wraps.
Counting :: struct {
	inner:  runtime.Allocator,
	allocs: int, // allocations and resizes
	frees:  int,
}

counting_proc :: proc(
	data: rawptr,
	mode: runtime.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	location := #caller_location,
) -> (
	[]byte,
	runtime.Allocator_Error,
) {
	counting := (^Counting)(data)
	#partial switch mode {
	case .Alloc, .Alloc_Non_Zeroed, .Resize, .Resize_Non_Zeroed:
		counting.allocs += 1
	case .Free:
		counting.frees += 1
	}
	return counting.inner.procedure(counting.inner.data, mode, size, alignment, old_memory, old_size, location)
}

@(test)
the_steady_state_allocates_nothing :: proc(t: ^testing.T) {
	// Everything the session makes holds this allocator, so a buffer that keeps growing is counted too.
	counting := Counting {
		inner = context.allocator,
	}
	context.allocator = {counting_proc, &counting}
	temp := Counting {
		inner = context.temp_allocator,
	}
	context.temp_allocator = {counting_proc, &temp}
	session: Net
	// A host and two remote clients under `wan` (loss, duplicates, reordering), the toy's commands, typed desync
	// reports (every client keeps a snapshot of every checksum tick). No recording: an in-memory log grows by design.
	net_make(&session, 1600, 2, record = false)
	defer net_destroy(&session)
	net_run(&session, 8) // everyone in, every buffer at its size
	testing.expect(t, len(session.clients) == 2 && session.clients[1].status == .Connected)
	counting.allocs, counting.frees = 0, 0
	temp.allocs, temp.frees = 0, 0
	from := session.host.relay.finalized
	net_run(&session, 8)
	testing.expectf(t, session.host.relay.finalized - from > 400, "only %d ticks", session.host.relay.finalized - from)
	testing.expect_value(t, counting.allocs, 0)
	testing.expect_value(t, counting.frees, 0)
	testing.expect_value(t, temp.allocs, 0)
}
