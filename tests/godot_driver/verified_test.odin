// The verified-timeline sampler (godot.Verified_Sampler) on a real session: two toy clients behind a relay on
// loopback links with WAN latency and loss, every participant stepped from one thread on a virtual clock. Each
// client's frame and verified hooks feed its sampler the way the driver does; every sample it queues must be the final
// state's pose of that view at that tick.
package test_godot_driver

import "core:testing"

import "unified:godot"
import "unified:netcode"
import "unified:sim"

import "../toy"

@(private = "file")
SAMPLED :: 0 // the view kind whose policy is .Verified
@(private = "file")
PREDICTED :: 1 // a kind that stays on the prediction: never sampled

@(private = "file")
Sample_Key :: struct {
	tick: u32,
	key:  u64,
}

// One client and its sampler, as the driver wires them.
@(private = "file")
Sampling :: struct {
	sampler:   ^godot.Verified_Sampler,
	out:       godot.Frame_Data, // the frame hook's fill
	final:     godot.Frame_Data, // a final tick's fill
	shadow:    ^toy.Sim, // the verified inputs stepped apart: the final timeline
	finals:    map[Sample_Key][3]f32, // each verified tick's players, on the shadow
	samples:   map[Sample_Key][3]f32, // what the sampler queued
	from_fill: int, // samples queued from a kept predicted fill
	from_step: int, // samples queued from a tick stepped as final
	wrong:     int, // samples whose pose isn't the final state's (or of a tick never verified, or another kind)
}

// The toy's fill: each present player's view of both kinds.
@(private = "file")
sampling_fill :: proc(out: ^godot.Frame_Data, state: ^toy.State) {
	out.n_views = 0
	players := sim.iterate_present(&state.players)
	for data, player in sim.next(&players) {
		key := sim.player_key(player)
		for kind in ([]u8{SAMPLED, PREDICTED}) {
			out.views[out.n_views] = {
				key    = key,
				kind   = kind,
				player = key,
				pos    = {data.pos.x, 0, data.pos.y},
				rot    = {0, 0, 0, 1},
			}
			out.n_views += 1
		}
	}
}

@(private = "file")
sampling_hooks :: proc(sampling: ^Sampling) -> netcode.Hooks(toy.Game) {
	return {
		user = sampling,
		sample = proc(user: rawptr, local, slot: int, tick: u32, state: ^toy.State) -> toy.Input {
			return toy.scripted_input(11, slot, tick) // changes every 8 ticks: the other client mispredicts it
		},
		frame = proc(user: rawptr, simulation: ^toy.Sim, info: netcode.Frame_Info) {
			sampling := (^Sampling)(user)
			sampling_fill(&sampling.out, &simulation.state)
			godot.verified_sampler_fill(sampling.sampler, &sampling.out, info)
		},
		verified = proc(
			user: rawptr,
			simulation: ^toy.Sim,
			tick: u32,
			inputs: ^sim.Inputs(toy.Game),
			events: []sim.Raw_Event,
		) {
			sampling := (^Sampling)(user)
			stepped := simulation.tick == tick
			// the final timeline, stepped apart with the verified inputs
			if sampling.shadow == nil do sampling.shadow = sim.create(&toy.GAME, simulation.seed, simulation.setup)
			sim.step(sampling.shadow, inputs, save = false)
			assert(sampling.shadow.tick == tick)
			players := sim.iterate_present(&sampling.shadow.state.players)
			for data, player in sim.next(&players) {
				sampling.finals[{tick, sim.player_key(player)}] = {data.pos.x, 0, data.pos.y}
			}
			queue := &sampling.sampler.queue
			queued := queue.tail
			if stepped {
				sampling_fill(&sampling.final, &simulation.state)
				godot.verified_sampler_verified(sampling.sampler, tick, &sampling.final)
			} else {
				godot.verified_sampler_verified(sampling.sampler, tick, nil)
			}
			if stepped do sampling.from_step += int(queue.tail - queued)
			else do sampling.from_fill += int(queue.tail - queued)
		},
	}
}

// Takes the sampler's queue (the main thread's side) and checks each sample against the final state.
@(private = "file")
sampling_drain :: proc(sampling: ^Sampling) {
	for {
		sample := godot.queue_pop(&sampling.sampler.queue) or_break
		at := Sample_Key{sample.tick, sample.key}
		final, verified := sampling.finals[at]
		if !verified || sample.kind != SAMPLED || sample.pose.pos != final do sampling.wrong += 1
		sampling.samples[at] = sample.pose.pos
	}
}

@(test)
verified_sampler_on_a_session :: proc(t: ^testing.T) {
	clock := netcode.Virtual_Clock {
		now = 1_000_000,
	}
	hub := netcode.hub_create(3)
	defer netcode.hub_destroy(hub)
	relay := netcode.relay_create(&toy.GAME, {seed = 11, ticks = 6 * toy.HZ, start_players = 2})
	defer netcode.relay_destroy(relay)
	netcode.relay_add_link(relay, netcode.loopback_link(hub, 0))

	samplings: [2]Sampling
	clients: [2]^netcode.Client(toy.Game)
	for &sampling, i in samplings {
		sampling.sampler = godot.verified_sampler_new({SAMPLED})
		for out in ([]^godot.Frame_Data{&sampling.out, &sampling.final}) do out.views = make([]godot.View_Out, 2 * toy.PLAYERS)
		link := netcode.netsim_wrap(
			netcode.loopback_link(hub, netcode.Peer(i + 1)),
			netcode.PROFILES[.Wan],
			u32(i + 1) * 7919,
			&clock,
		)
		clients[i] = netcode.client_create(&toy.GAME, {slot = -1, player_name = "p"}, link, sampling_hooks(&sampling))
	}
	defer for &sampling, i in samplings {
		netcode.client_destroy(clients[i])
		godot.verified_sampler_free(sampling.sampler)
		delete(sampling.out.views)
		delete(sampling.final.views)
		delete(sampling.finals)
		if sampling.shadow != nil do sim.destroy(sampling.shadow)
		delete(sampling.samples)
	}

	end := clock.now + 10_000_000
	for clock.now < end {
		now := clock.now
		wake := netcode.relay_step(relay, now)
		for client in clients do wake = min(wake, netcode.client_step(client, now))
		for &sampling in samplings do sampling_drain(&sampling)
		finished := netcode.relay_finished(relay)
		for client in clients do finished &&= netcode.client_finished(client)
		if finished do break
		clock.now = clamp(wake, now + 1, end)
	}

	for &sampling, i in samplings {
		stats := netcode.client_stats(clients[i])
		testing.expectf(t, stats.rollbacks > 0, "client %d never rolled back: nothing mispredicted", i)
		testing.expectf(t, sampling.from_fill > 0, "client %d: no sample from a kept fill", i)
		testing.expectf(t, sampling.from_step > 0, "client %d: no sample from a tick stepped as final", i)
		testing.expectf(t, sampling.wrong == 0, "client %d: %d samples aren't the final state's", i, sampling.wrong)
		// a good share of the verified ticks have a sample (the rest were re-simulated and never filled: playback
		// interpolates across them)
		testing.expectf(
			t,
			len(sampling.samples) * 4 > len(sampling.finals),
			"client %d: %d samples of %d verified poses",
			i,
			len(sampling.samples),
			len(sampling.finals),
		)
	}
	// both clients sampled the same final timeline
	agreed := 0
	for at, pos in samplings[0].samples {
		other := samplings[1].samples[at] or_continue
		testing.expectf(t, other == pos, "the clients' samples differ at tick %d", at.tick)
		agreed += 1
	}
	testing.expect(t, agreed > 0)
}
