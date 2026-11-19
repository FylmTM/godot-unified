package drift

import "unified:dmath"
import "unified:physics"
import "unified:sim"

// A rock out of HP: a large or medium one splits into two of the next size, ROCK_SPLIT_GAP of their radii either side
// of it across its velocity, moving apart at ROCK_SPLIT_SPEED, each with ROCK_SPLIT_SPIN of its spin, the second the
// other way and the next shape; a small one is destroyed, and one in GEM_DROP_EVERY drops a gem at GEM_THROW of its
// velocity.
break_rocks :: proc(t: ^Tick) {
	// a split's halves that reuse a free slot ahead of the walk are visited this tick, the ones in fresh slots the next
	rocks := sim.iterate(&t.state.rocks)
	for rock, handle in sim.next(&rocks) {
		if rock.hp > 0 do continue
		size, variant := rock.size, int(rock.variant)
		pos := physics.body_position_2d(t.world.phys, rock.body)
		vel := physics.body_linear_velocity_2d(t.world.phys, rock.body)
		spin := physics.body_angular_velocity_2d(t.world.phys, rock.body)
		physics.despawn(t.world.phys, &t.state.rocks, handle)
		if size == .Small {
			sim.emit(t, Event_Rock_Destroyed{rock = handle, position = sim.position_2d(pos), size = size})
			t.state.gems_dropped += 1
			if t.state.gems_dropped % GEM_DROP_EVERY == 1 {
				if gem, _, ok := sim.spawn(&t.state.gems); ok {
					gem^ = {
						pos        = pos,
						vel        = vel * GEM_THROW,
						spawn_tick = t.time,
					}
				}
			}
			continue
		}
		sim.emit(t, Event_Rock_Split{rock = handle, position = sim.position_2d(pos), size = size})
		half := Rock_Size(u8(size) - 1)
		direction := dmath.normalize(vel)
		if direction == {} do direction = {1, 0} // a rock at rest splits along x
		across := [2]f32{-direction.y, direction.x}
		offset := across * (ROCK_STATS[half].radius * ROCK_SPLIT_GAP)
		apart := across * ROCK_SPLIT_SPEED
		create_rock(t, half, variant, pos + offset, vel + apart, spin * ROCK_SPLIT_SPIN)
		create_rock(t, half, (variant + 1) % ROCK_VARIANTS, pos - offset, vel - apart, -spin * ROCK_SPLIT_SPIN)
	}
}

// During a match: wave k (0, 1, ...) every WAVE_EVERY_TICKS brings WAVE_ROCKS + WAVE_ROCKS_MORE * k large rocks, one
// every ROCK_EVERY_TICKS from the rock_spawn markers in turn, at ROCK_SPEED + ROCK_SPEED_PER_WAVE * k along the
// marker's direction turned up to ROCK_SPREAD_TURNS (dmath.rotate2); the turn, the spin (up to ROCK_SPIN_MAX) and the
// shape are keyed rolls.
spawn_waves :: proc(t: ^Tick) {
	if t.state.phase != .Match do return
	if t.time >= t.state.next_wave_tick {
		t.state.rocks_left += WAVE_ROCKS + WAVE_ROCKS_MORE * u32(t.state.waves)
		t.state.waves += 1
		t.state.next_wave_tick = t.time + WAVE_EVERY_TICKS
		t.state.next_rock_tick = t.time
		sim.emit(t, Event_Wave{wave = t.state.waves})
	}
	if t.state.rocks_left == 0 || t.time < t.state.next_rock_tick do return
	spawner := &sim.slice(&t.world.spawners)[t.state.spawner % t.world.spawners.count]
	speed := ROCK_SPEED + ROCK_SPEED_PER_WAVE * f32(t.state.waves - 1)
	// the drift direction turned by up to ROCK_SPREAD_TURNS either way
	turn := (sim.roll_f32(t, Roll.Rock_Turn) * 2 - 1) * ROCK_SPREAD_TURNS
	direction := dmath.rotate2(spawner.dir, turn)
	spin := (sim.roll_f32(t, Roll.Rock_Spin) * 2 - 1) * ROCK_SPIN_MAX
	variant := int(sim.roll_below(t, ROCK_VARIANTS, Roll.Rock_Variant))
	if _, ok := create_rock(t, .Large, variant, spawner.pos, direction * speed, spin); ok {
		t.state.spawner += 1
		t.state.rocks_left -= 1
	}
	t.state.next_rock_tick = t.time + ROCK_EVERY_TICKS
}
