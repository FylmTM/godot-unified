// The session's steady state allocates nothing, on the heap or the temp allocator: queued messages, loopback
// datagrams, the netsim's delayed datagrams and early reliable messages live in reused buffers, the kept desync
// images reuse theirs.
package test_netcode

import "base:runtime"
import "core:testing"

import "unified:netcode"

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

// Both a fixed-length session and an endless one (how a game is played: its client keeps only its last checksums).
@(test)
the_steady_state_allocates_nothing :: proc(t: ^testing.T) {
	for ticks in ([]u32{1600, 0}) {
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
		// reports (every client keeps a snapshot of every checksum tick). No recording: an in-memory log grows by
		// design.
		net_make(&session, ticks, 2, record = false)
		defer net_destroy(&session)
		net_run(&session, 8) // everyone in, every buffer at its size
		testing.expect(t, len(session.clients) == 2 && session.clients[1].status == .Connected)
		counting.allocs, counting.frees = 0, 0
		temp.allocs, temp.frees = 0, 0
		from := session.host.relay.finalized
		// The endless one runs past the checksums its clients keep.
		net_run(&session, ticks == 0 ? 16 : 8)
		ran := session.host.relay.finalized - from
		testing.expectf(t, ran > 400, "ticks %d: only %d ticks", ticks, ran)
		testing.expectf(t, counting.allocs == 0, "ticks %d: %d allocations", ticks, counting.allocs)
		testing.expectf(t, counting.frees == 0, "ticks %d: %d frees", ticks, counting.frees)
		testing.expectf(t, temp.allocs == 0, "ticks %d: %d temp allocations", ticks, temp.allocs)
		if ticks == 0 {
			kept := session.clients[0].checksums[:]
			testing.expect_value(t, len(kept), netcode.CHECKSUMS_KEPT)
			testing.expect_value(
				t,
				kept[len(kept) - 1][0] - kept[0][0],
				u64(netcode.CHECKSUM_EVERY * (netcode.CHECKSUMS_KEPT - 1)),
			)
		}
	}
}

// A burst of queued messages (a large world's snapshot: thousands of chunks queued at once) grows the slot pool
// geometrically: a few allocations, not one per slot (each copying every slot before it).
@(test)
the_slot_pool_grows_geometrically :: proc(t: ^testing.T) {
	counting := Counting {
		inner = context.allocator,
	}
	context.allocator = {counting_proc, &counting}
	pool: netcode.Slot_Pool
	defer netcode.pool_destroy(&pool)
	bytes: [netcode.MAX_DATAGRAM]u8
	for _ in 0 ..< 8000 {
		netcode.pool_put(&pool, bytes[:])
	}
	testing.expectf(t, counting.allocs < 16, "%d allocations for 8000 slots", counting.allocs)
}
