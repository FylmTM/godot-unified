// Network simulator: wraps a link and impairs both directions (latency, jitter, loss, duplication, reordering) with
// a seeded RNG. Applied on the client side, so one wrapper shapes the whole client <-> relay path. With a
// Virtual_Clock it runs on test time instead of real time. A live one (netsim_live) changes its profiles while it runs
// (the dev UI's Conditions panel); a direction that is ideal with nothing queued passes datagrams straight through.
package netcode

Profile :: struct {
	name:      string,
	latency:   i64, // one way, µs
	jitter:    i64, // ± µs, uniform
	loss:      u32, // per mille
	duplicate: u32,
	reorder:   u32, // per mille of packets held back an extra 1-3 ticks
}

// The built-in network profiles (PROFILES), by the name the headless `--profile` option takes.
Network :: enum u8 {
	Ideal,
	Wan, // 100 ms round trip ± 15 ms, 2% loss: the common case
	Bad, // 240 ms round trip ± 40 ms, 8% loss, duplicates and reordering: a stress profile
}

PROFILES := [Network]Profile {
	.Ideal = {name = "ideal"},
	.Wan = {name = "wan", latency = 50_000, jitter = 15_000, loss = 20, duplicate = 10, reorder = 10},
	.Bad = {name = "bad", latency = 120_000, jitter = 40_000, loss = 80, duplicate = 30, reorder = 50},
}

// A profile that changes nothing (netsim_wrap returns the link it is given).
profile_is_ideal :: proc(profile: Profile) -> bool {
	return(
		profile.latency == 0 &&
		profile.jitter == 0 &&
		profile.loss == 0 &&
		profile.duplicate == 0 &&
		profile.reorder == 0 \
	)
}

// Looks up a built-in profile by name (ideal, wan, bad), for the headless `--profile` option.
profile_by_name :: proc(name: string) -> (Profile, bool) {
	for profile in PROFILES {
		if profile.name == name {
			return profile, true
		}
	}
	return {}, false
}

Net_Sim :: struct {
	inner:    Link,
	up:       Profile, // datagrams we send
	down:     Profile, // datagrams we receive
	rng:      u32,
	outgoing: [dynamic]Sim_Packet,
	incoming: [dynamic]Sim_Packet,
	scratch:  [MAX_DATAGRAM]u8,
	pool:     Slot_Pool, // the queued datagrams' bytes
	clock:    ^Virtual_Clock,
}

// Test time (µs) shared by netsims and the code that steps sessions on a virtual clock.
Virtual_Clock :: struct {
	now: i64,
}

@(private)
clock_now :: proc(clock: ^Virtual_Clock) -> i64 {
	return clock.now if clock != nil else now_us()
}

@(private)
xorshift32 :: proc(state: ^u32) -> u32 {
	value := state^
	value ~= value << 13
	value ~= value >> 17
	value ~= value << 5
	state^ = value
	return value
}

Sim_Packet :: struct {
	at:    i64,
	peer:  Peer,
	bytes: Pooled,
}

// Wraps `inner` with `profile` both ways; the result owns it. An ideal profile returns `inner` unchanged.
netsim_wrap :: proc(inner: Link, profile: Profile, seed: u32, clock: ^Virtual_Clock = nil) -> Link {
	if profile_is_ideal(profile) {
		return inner
	}
	link, netsim := netsim_live(inner, seed, clock)
	netsim_set(netsim, profile, profile)
	return link
}

// Wraps `inner` in a netsim whose profiles change while it runs (netsim_set), ideal both ways to begin with: an ideal
// direction with nothing queued costs nothing. The link owns `inner` and the Net_Sim (closing it frees both).
netsim_live :: proc(inner: Link, seed: u32, clock: ^Virtual_Clock = nil) -> (Link, ^Net_Sim) {
	netsim := new(Net_Sim)
	netsim.inner = inner
	netsim.rng = seed == 0 ? 0x9E3779B9 : seed
	netsim.clock = clock
	pool_reserve(&netsim.pool, POOL_RESERVE)
	return {
			data    = netsim,
			send    = netsim_send,
			recv    = netsim_recv,
			close   = netsim_close,
			event   = inner.event == nil ? nil : netsim_event,
			forget  = inner.forget == nil ? nil : proc(data: rawptr, peer: Peer) {link_forget(&(^Net_Sim)(data).inner, peer)},
			account = inner.account == nil ? nil : proc(data: rawptr, peer: Peer) -> (Account, bool) {
				return link_account(&(^Net_Sim)(data).inner, peer)
			},
		}, netsim
}

// Sets the profiles of datagrams sent (`up`) and received (`down`) from now on; the datagrams already queued keep
// their delivery times.
netsim_set :: proc(netsim: ^Net_Sim, up, down: Profile) {
	netsim.up, netsim.down = up, down
}

@(private)
roll :: proc(netsim: ^Net_Sim, per_mille: u32) -> bool {
	return per_mille > 0 && xorshift32(&netsim.rng) % 1000 < per_mille
}

// Queues zero, one or two copies of the datagram with their delivery times.
@(private)
impair :: proc(netsim: ^Net_Sim, queue: ^[dynamic]Sim_Packet, peer: Peer, bytes: []u8, profile: ^Profile) {
	if roll(netsim, profile.loss) {
		return
	}
	copies := 1
	if roll(netsim, profile.duplicate) {
		copies = 2
	}
	now := clock_now(netsim.clock)
	for _ in 0 ..< copies {
		delay := profile.latency
		if profile.jitter > 0 {
			delay += i64(xorshift32(&netsim.rng) % u32(2 * profile.jitter + 1)) - profile.jitter
		}
		if roll(netsim, profile.reorder) {
			delay += 16_000 * i64(1 + xorshift32(&netsim.rng) % 3)
		}
		append(queue, Sim_Packet {
			at    = now + max(delay, 0),
			peer  = peer,
			bytes = pool_put(&netsim.pool, bytes),
		})
	}
}

// Removes and returns the earliest packet that is due, if any.
@(private)
pop_due :: proc(queue: ^[dynamic]Sim_Packet, now: i64) -> (packet: Sim_Packet, ok: bool) {
	best := -1
	for &queued, i in queue {
		if queued.at <= now && (best < 0 || queued.at < queue[best].at) {
			best = i
		}
	}
	if best < 0 {
		return
	}
	packet = queue[best]
	ordered_remove(queue, best)
	return packet, true
}

@(private)
pump :: proc(netsim: ^Net_Sim) {
	now := clock_now(netsim.clock)
	for {
		packet, ok := pop_due(&netsim.outgoing, now)
		if !ok {
			break
		}
		link_send(&netsim.inner, packet.peer, pool_bytes(&netsim.pool, packet.bytes))
		pool_release(&netsim.pool, packet.bytes)
	}
	if profile_is_ideal(netsim.down) && len(netsim.incoming) == 0 {
		return // netsim_recv reads the inner link straight
	}
	for {
		size, from, ok := link_recv(&netsim.inner, netsim.scratch[:])
		if !ok {
			break
		}
		impair(netsim, &netsim.incoming, from, netsim.scratch[:size], &netsim.down)
	}
}

@(private)
netsim_send :: proc(data: rawptr, to: Peer, bytes: []u8) {
	netsim := (^Net_Sim)(data)
	if profile_is_ideal(netsim.up) && len(netsim.outgoing) == 0 {
		link_send(&netsim.inner, to, bytes)
		return
	}
	impair(netsim, &netsim.outgoing, to, bytes, &netsim.up)
	pump(netsim)
}

@(private)
netsim_recv :: proc(data: rawptr, buf: []u8) -> (size: int, from: Peer, ok: bool) {
	netsim := (^Net_Sim)(data)
	pump(netsim)
	if profile_is_ideal(netsim.down) && len(netsim.incoming) == 0 {
		return link_recv(&netsim.inner, buf)
	}
	packet := pop_due(&netsim.incoming, clock_now(netsim.clock)) or_return
	defer pool_release(&netsim.pool, packet.bytes)
	return copy(buf, pool_bytes(&netsim.pool, packet.bytes)), packet.peer, true
}

@(private)
netsim_event :: proc(data: rawptr) -> (peer: Peer, kind: Link_Event_Kind, ok: bool) {
	netsim := (^Net_Sim)(data)
	return netsim.inner.event(netsim.inner.data)
}

// The datagrams still queued to go out are sent now, not dropped: like datagrams already on the wire, they outlive
// their sender. A client that leaves just after acking the relay's End would otherwise take the ack with it, and the
// relay would wait its 3 s for it.
@(private)
netsim_close :: proc(data: rawptr) {
	netsim := (^Net_Sim)(data)
	for packet in netsim.outgoing {
		link_send(&netsim.inner, packet.peer, pool_bytes(&netsim.pool, packet.bytes))
	}
	delete(netsim.outgoing)
	delete(netsim.incoming)
	pool_destroy(&netsim.pool)
	link_close(&netsim.inner)
	free(netsim)
}
