// Network simulator: wraps a link and impairs both directions (latency, jitter, loss,
// duplication, reordering; one profile, or one per direction) with a seeded RNG. Applied on the client side, so one wrapper shapes
// the whole client <-> relay path. With a Virtual_Clock it runs on test time instead of real time.
package netcode

Profile :: struct {
	name:      string,
	latency:   i64, // one way, µs
	jitter:    i64, // ± µs, uniform
	loss:      u32, // per mille
	duplicate: u32,
	reorder:   u32, // per mille of packets held back an extra 1-3 ticks
}

PROFILES := [?]Profile {
	{name = "ideal"},
	{name = "wan", latency = 50_000, jitter = 15_000, loss = 20, duplicate = 10, reorder = 10},
	{name = "bad", latency = 120_000, jitter = 40_000, loss = 80, duplicate = 30, reorder = 50},
}

profile_by_name :: proc(name: string) -> (Profile, bool) {
	for p in PROFILES {
		if p.name == name {
			return p, true
		}
	}
	return {}, false
}

Net_Sim :: struct {
	inner:      Link,
	profile:    Profile, // both directions, or only outgoing when `split`
	profile_in: Profile, // incoming, when `split`
	split:      bool,
	rng:        u32,
	outgoing:   [dynamic]Sim_Packet,
	incoming:   [dynamic]Sim_Packet,
	scratch:    [MAX_DATAGRAM]u8,
	stats:      Net_Sim_Stats,
	clock:      ^Virtual_Clock,
}

// Test time (µs) shared by netsims and the code that steps sessions on a virtual clock.
Virtual_Clock :: struct {
	now: i64,
}

@(private)
clock_now :: proc(c: ^Virtual_Clock) -> i64 {
	return c.now if c != nil else now_us()
}

@(private)
xorshift32 :: proc(x: ^u32) -> u32 {
	v := x^
	v ~= v << 13
	v ~= v >> 17
	v ~= v << 5
	x^ = v
	return v
}

Sim_Packet :: struct {
	at:    i64,
	peer:  Peer,
	bytes: []u8,
}

Net_Sim_Stats :: struct {
	sent, dropped, duplicated, reordered: int,
}

// Wraps `inner`; the result owns it. An ideal profile returns `inner` unchanged.
netsim_wrap :: proc(inner: Link, profile: Profile, seed: u32, clock: ^Virtual_Clock = nil) -> Link {
	if profile.latency == 0 && profile.loss == 0 && profile.duplicate == 0 && profile.reorder == 0 {
		return inner
	}
	ns := new(Net_Sim)
	ns.inner = inner
	ns.profile = profile
	ns.rng = seed == 0 ? 0x9E3779B9 : seed
	ns.clock = clock
	return {
		data = ns,
		send = netsim_send,
		recv = netsim_recv,
		close = netsim_close,
		event = inner.event == nil ? nil : netsim_event,
	}
}

@(private)
roll :: proc(ns: ^Net_Sim, per_mille: u32) -> bool {
	return per_mille > 0 && xorshift32(&ns.rng) % 1000 < per_mille
}

// Queues zero, one or two copies of the datagram with their delivery times.
@(private)
impair :: proc(ns: ^Net_Sim, q: ^[dynamic]Sim_Packet, peer: Peer, bytes: []u8, incoming: bool) {
	prof := incoming && ns.split ? &ns.profile_in : &ns.profile
	ns.stats.sent += 1
	if roll(ns, prof.loss) {
		ns.stats.dropped += 1
		return
	}
	copies := 1
	if roll(ns, prof.duplicate) {
		copies = 2
		ns.stats.duplicated += 1
	}
	now := clock_now(ns.clock)
	for _ in 0 ..< copies {
		delay := prof.latency
		if prof.jitter > 0 {
			delay += i64(xorshift32(&ns.rng) % u32(2 * prof.jitter + 1)) - prof.jitter
		}
		if roll(ns, prof.reorder) {
			delay += 16_000 * i64(1 + xorshift32(&ns.rng) % 3)
			ns.stats.reordered += 1
		}
		append(q, Sim_Packet{at = now + max(delay, 0), peer = peer, bytes = clone_bytes(bytes)})
	}
}

// Removes and returns the earliest packet that is due, if any.
@(private)
pop_due :: proc(q: ^[dynamic]Sim_Packet, now: i64) -> (p: Sim_Packet, ok: bool) {
	best := -1
	for &it, i in q {
		if it.at <= now && (best < 0 || it.at < q[best].at) {
			best = i
		}
	}
	if best < 0 {
		return
	}
	p = q[best]
	ordered_remove(q, best)
	return p, true
}

@(private)
pump :: proc(ns: ^Net_Sim) {
	now := clock_now(ns.clock)
	for {
		p, ok := pop_due(&ns.outgoing, now)
		if !ok {
			break
		}
		link_send(&ns.inner, p.peer, p.bytes)
		delete(p.bytes)
	}
	for {
		n, from, ok := link_recv(&ns.inner, ns.scratch[:])
		if !ok {
			break
		}
		impair(ns, &ns.incoming, from, ns.scratch[:n], true)
	}
}

@(private)
netsim_send :: proc(data: rawptr, to: Peer, bytes: []u8) {
	ns := (^Net_Sim)(data)
	impair(ns, &ns.outgoing, to, bytes, false)
	pump(ns)
}

@(private)
netsim_recv :: proc(data: rawptr, buf: []u8) -> (n: int, from: Peer, ok: bool) {
	ns := (^Net_Sim)(data)
	pump(ns)
	p := pop_due(&ns.incoming, clock_now(ns.clock)) or_return
	defer delete(p.bytes)
	return copy(buf, p.bytes), p.peer, true
}

@(private)
netsim_event :: proc(data: rawptr) -> (peer: Peer, kind: Link_Event_Kind, ok: bool) {
	ns := (^Net_Sim)(data)
	return ns.inner.event(ns.inner.data)
}

@(private)
netsim_close :: proc(data: rawptr) {
	ns := (^Net_Sim)(data)
	for p in ns.outgoing {
		delete(p.bytes)
	}
	for p in ns.incoming {
		delete(p.bytes)
	}
	delete(ns.outgoing)
	delete(ns.incoming)
	link_close(&ns.inner)
	free(ns)
}
