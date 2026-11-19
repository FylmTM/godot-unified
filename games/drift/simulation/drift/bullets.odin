package drift

import "unified:dmath"
import "unified:physics"
import "unified:sim"

// What a bullet's ray hits: the level, rocks and the station.
BULLET_QUERY :: physics.Filter {
	category = CAT_BULLET,
	mask     = CAT_STATIC | CAT_ROCK | CAT_STATION,
}

// Moves every bullet one tick along a ray: a hit ends it (a rock it hits loses 1 HP and is pushed; the station takes
// no damage from it), otherwise it expires when its lifetime runs out.
move_bullets :: proc(t: ^Tick) {
	bullets := sim.iterate(&t.state.bullets)
	for bullet, handle in sim.next(&bullets) {
		step := bullet.vel * t.dt
		if hit, ok := physics.world_cast_ray_closest_2d(t.world.phys, bullet.pos, step, BULLET_QUERY); ok {
			if hit.category & CAT_ROCK != 0 do hit_rock(t, bullet, sim.handle_of_key(Rock, hit.tag), hit.point)
			sim.despawn(&t.state.bullets, handle)
			continue
		}
		bullet.pos += step
		bullet.ttl -= 1
		if bullet.ttl == 0 do sim.despawn(&t.state.bullets, handle)
	}
}

// A bullet hit a rock at `point`: it loses 1 HP (break_rocks breaks it at 0) and is pushed along the bullet.
hit_rock :: proc(t: ^Tick, bullet: ^Bullet, handle: sim.Handle(Rock), point: [3]f32) {
	rock := sim.get(&t.state.rocks, handle)
	if rock == nil || rock.hp == 0 do return
	rock.hp -= 1
	rock.hit_tick = t.time
	physics.body_apply_linear_impulse_to_center_2d(t.world.phys, rock.body, dmath.normalize(bullet.vel) * BULLET_PUSH)
	sim.emit(t, Event_Rock_Hit{rock = handle, position = sim.Position(point), player = bullet.owner, size = rock.size})
}
