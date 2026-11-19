// A client's own inputs on the wire (src/netcode/README.md, The window): each rides in a window of packets
// (netcode.inputs_window) whatever the round trip and however many one step generated, and what a step sends beyond
// its main message is bounded. Counted by a link that reads the client's datagrams.
package test_headless

@(require) import "core:fmt" // used only by the loss sweep, which builds with --long
@(require) import "core:strings"
import "core:testing"

import "unified:headless"
import "unified:headless/scenarios"
import "unified:netcode"
import "unified:sim"

// The widest Input at 3 players (a packet carries 12).
Plain_3x76 :: sim.Game(
	Plain_State(76, 3),
	Plain_Input(76),
	sim.No_World,
	Wide_Event,
	sim.No_Commands,
	sim.No_Setup,
	sim.No_Profile,
	3,
)

// A link that counts what a client sends: per own tick, how many Inputs messages carried it; the most Inputs
// messages sent at one clock value (one client step); the bytes.
Tap :: struct {
	inner:    netcode.Link,
	carried:  [8192]u16,
	messages: int,
	bytes:    int,
	most:     int,
	clock:    ^netcode.Virtual_Clock,
	at:       i64,
	at_count: int,
}

tap_link :: proc(tap: ^Tap, inner: netcode.Link, clock: ^netcode.Virtual_Clock) -> netcode.Link {
	tap.inner = inner
	tap.clock = clock
	return {
		data = tap,
		send = proc(data: rawptr, to: netcode.Peer, bytes: []u8) {
			tap := (^Tap)(data)
			tap.bytes += len(bytes)
			if tap.clock.now != tap.at {
				tap.at = tap.clock.now
				tap.at_count = 0
			}
			// The datagram's chunks (channel.odin's header); an Inputs message (proto.odin, Msg) starts with its
			// type, the finalized ack u32, the first tick u32 and the count u8.
			pos := netcode.HEADER_BYTES
			for pos + 3 <= len(bytes) {
				kind := bytes[pos]
				pos += 1
				if kind == 1 do pos += 4
				if pos + 2 > len(bytes) do break
				size := int(bytes[pos]) | int(bytes[pos + 1]) << 8
				pos += 2
				if pos + size > len(bytes) do break
				message := bytes[pos:pos + size]
				pos += size
				if kind == 0 && size >= netcode.INPUTS_HEAD && message[0] == u8(netcode.Msg.Inputs) {
					first := u32(message[5]) | u32(message[6]) << 8 | u32(message[7]) << 16 | u32(message[8]) << 24
					for tick in first ..< first + u32(message[9]) {
						if int(tick) < len(tap.carried) do tap.carried[tick] += 1
					}
					tap.messages += 1
					tap.at_count += 1
					tap.most = max(tap.most, tap.at_count)
				}
			}
			netcode.link_send(&tap.inner, to, bytes)
		},
		recv = proc(data: rawptr, buf: []u8) -> (int, netcode.Peer, bool) {
			return netcode.link_recv(&(^Tap)(data).inner, buf)
		},
		close = proc(data: rawptr) {
			netcode.link_close(&(^Tap)(data).inner)
		},
	}
}

// A client of the sweep's net behind its own up and down profiles (a live netsim), optionally tapped.
tapped_join :: proc(
	net: ^Sweep_Net($G),
	slot: int,
	up, down: netcode.Profile,
	seed: u32 = 0,
	tap: ^Tap = nil,
) -> (
	^netcode.Client(G),
	^netcode.Net_Sim,
) {
	endpoint := len(net.clients) + 1
	link, netsim := netcode.netsim_live(
		netcode.loopback_link(net.hub, netcode.Peer(endpoint)),
		u32(endpoint) * 7919 + seed * 104729,
		&net.clock,
	)
	netcode.netsim_set(netsim, up, down)
	if tap != nil do link = tap_link(tap, link, &net.clock)
	client := netcode.client_create(&net.game, {slot = slot}, link, headless.scripted_hooks(&net.scripted))
	append(&net.clients, client)
	return client, netsim
}

// Start players' own inputs at 128 Hz on lossless round trips longer than the window (no ack ends an input's packets
// early): every tick rode in at least the window's packets. With an input delay at or just under the window (2 x 116
// B at 270 ms, 3 x 76 B at 310 ms) the clock's first step generated no more than the main message carries, so its
// first inputs rode in 1 to 3 packets (lost at the network's loss rate).
packets_per_input :: proc(t: ^testing.T, $G: typeid, name: string, window: int, latencies: []i64) {
	PLAYERS :: sim.part(G, sim.GAME_PLAYERS)
	for latency in latencies {
		net := new(Sweep_Net(G))
		defer free(net)
		sweep_make(net, 0, 128, PLAYERS)
		defer sweep_destroy(net)
		profile := netcode.Profile {
			name    = "lossless",
			latency = latency,
		}
		taps := new([PLAYERS]Tap)
		defer free(taps)
		for slot in 0 ..< PLAYERS do tapped_join(net, slot, profile, profile, 0, &taps[slot])
		sweep_run(net, 3)
		client := net.clients[0]
		fewest, fewest_tick, short := 1000, u32(0), 0
		for tick in 1 ..= client.own_last - 64 {
			carried := int(taps[0].carried[tick])
			if carried < fewest do fewest, fewest_tick = carried, tick
			if carried < window do short += 1
		}
		testing.expectf(
			t,
			fewest >= window,
			"%s at 128 Hz, %d ms round trip (input delay %d, window %d): tick %d rode in %d packets; %d ticks in fewer than the window; first ticks: %v",
			name,
			2 * latency / 1000,
			client.delay,
			window,
			fewest_tick,
			fewest,
			short,
			taps[0].carried[1:16],
		)
	}
}

@(test)
each_input_rides_in_a_window_of_packets :: proc(t: ^testing.T) {
	// the round trips at which the first inputs rode in the fewest packets (the long sweep runs the rest)
	packets_per_input(t, Plain_2x116, "2 x 116 B", 7, {125_000, 135_000})
	packets_per_input(t, Plain_3x76, "3 x 76 B", 12, {155_000})
	packets_per_input(t, Plain_2x8, "2 x 8 B", 32, {180_000})
}

// What a burst costs: a client that steps rarely (every `step_ms`) generates more inputs per step than a packet
// carries, every step; with the relay silent nothing is acked. A burst used to carry every unacked input older than
// the main message, every step (145 messages in a step, 0.7 to 1.2 MB/s up): now only those still in time that rode in
// fewer than the window's packets.
bounded_bursts :: proc(t: ^testing.T, step_ms: int, silent: bool) {
	net := new(Sweep_Net(Plain_2x116))
	defer free(net)
	sweep_make(net, 0, 128, 2)
	defer sweep_destroy(net)
	profile := netcode.Profile {
		name    = "100 ms",
		latency = 50_000,
	}
	tap: Tap
	tapped_join(net, 0, profile, profile)
	_, netsim := tapped_join(net, 1, profile, profile, 0, &tap)
	sweep_run(net, 2)
	before := tap.bytes
	tap.most = 0
	if silent {
		// nothing from the relay reaches the client any more (its acks stop); the client keeps sending
		netcode.netsim_set(netsim, profile, {name = "dead", latency = 50_000, loss = 1000})
	}
	seconds := 4.0
	end := net.clock.now + i64(seconds * 1e6)
	next_step := net.clock.now
	for net.clock.now < end {
		now := net.clock.now
		wake := netcode.relay_step(net.relay, now)
		wake = min(wake, netcode.client_step(net.clients[0], now))
		if now >= next_step && !netcode.client_finished(net.clients[1]) {
			netcode.client_step(net.clients[1], now)
			next_step = now + i64(step_ms) * 1000
		}
		net.clock.now = clamp(min(wake, next_step), now + 1, end)
	}
	up := f64(tap.bytes - before) / seconds / 1000
	testing.expectf(
		t,
		tap.most <= 8 && up < 150, // a client stepped every millisecond sends 123 kB/s
		"client stepped every %d ms, relay silent %v: %d Inputs messages in one step, %.0f kB/s up",
		step_ms,
		silent,
		tap.most,
		up,
	)
}

@(test)
a_slow_stepping_client_sends_bounded_bursts :: proc(t: ^testing.T) {
	bounded_bursts(t, 100, true)
}

// The ticks of slot `slot` the relay replaced among its first `upto` ticks.
replaced_among :: proc(net: ^Sweep_Net($G), slot: int, upto: u32) -> (count: int, list: string) {
	out := strings.builder_make(context.temp_allocator)
	for tick in 1 ..= min(upto, net.relay.finalized) {
		inputs := netcode.relay_tick(net.relay, tick)
		if inputs != nil && slot in inputs.replaced {
			count += 1
			fmt.sbprintf(&out, " %d", tick)
		}
	}
	return count, strings.to_string(out)
}

// With loss upstream only (the Welcome and everything else the relay sends arrives), over seeds: no start player's
// first inputs are replaced, also when the input delay is at or just under the window (the first inputs used to
// ride in 1 to 3 packets: tick 1 replaced for 6 to 8% of players under 8% loss).
first_inputs_under_loss :: proc(t: ^testing.T, $G: typeid, name: string, latencies: []i64, sessions: int) {
	PLAYERS :: sim.part(G, sim.GAME_PLAYERS)
	for latency in latencies {
		hit, delay := 0, u32(0)
		example := ""
		for seed in 0 ..< sessions {
			net := new(Sweep_Net(G))
			sweep_make(net, 0, 128, PLAYERS)
			up := netcode.Profile {
				name    = "8% loss up",
				latency = latency,
				loss    = 80,
			}
			down := netcode.Profile {
				name    = "lossless down",
				latency = latency,
			}
			for slot in 0 ..< PLAYERS do tapped_join(net, slot, up, down, u32(seed))
			sweep_run(net, 2)
			for slot in 0 ..< PLAYERS {
				count, list := replaced_among(net, slot, 40)
				if count > 0 {
					hit += 1
					if example == "" do example = fmt.tprintf("seed %d slot %d ticks%s", seed, slot, list)
				}
			}
			delay = net.clients[0].delay
			sweep_destroy(net)
			free(net)
		}
		testing.expectf(
			t,
			hit == 0,
			"%s at 128 Hz, %d ms round trip, 8%% loss upstream only (input delay %d): %d of %d players had first inputs replaced (%s)",
			name,
			2 * latency / 1000,
			delay,
			hit,
			sessions * PLAYERS,
			example,
		)
	}
}

when scenarios.LONG {
	@(test)
	sweep_packets_per_input :: proc(t: ^testing.T) {
		packets_per_input(
			t,
			Plain_2x116,
			"2 x 116 B",
			7,
			{60_000, 110_000, 120_000, 125_000, 130_000, 135_000, 150_000},
		)
		packets_per_input(
			t,
			Plain_3x76,
			"3 x 76 B",
			12,
			{60_000, 130_000, 140_000, 145_000, 150_000, 155_000, 170_000},
		)
		packets_per_input(t, Plain_2x8, "2 x 8 B", 32, {150_000, 180_000})
	}
	@(test)
	sweep_first_inputs_under_loss :: proc(t: ^testing.T) {
		// where the delay is at or just under the window (the rest of the band lost none even before)
		first_inputs_under_loss(t, Plain_2x116, "2 x 116 B", {130_000, 135_000}, 24)
		first_inputs_under_loss(t, Plain_3x76, "3 x 76 B", {150_000, 155_000}, 24)
	}
	@(test)
	sweep_bounded_bursts :: proc(t: ^testing.T) {
		for step_ms in ([]int{1, 60, 100}) {
			for silent in ([]bool{false, true}) do bounded_bursts(t, step_ms, silent)
		}
	}
}
