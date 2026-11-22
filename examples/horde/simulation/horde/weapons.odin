package horde

import "unified:dmath"
import "unified:sim"

// Each alive present hero's weapons fire on their own timers while the match runs: a fan of bolts at the nearest enemy
// within BOLT_RANGE, a lightning strike from the nearest within LIGHTNING_RANGE, a bomb at the nearest within
// BOMB_RANGE. A weapon with no target waits for one (its timer stays run out).
fire_weapons :: proc(t: ^Tick) {
	if t.state.phase != .Match do return
	players := sim.iterate_present(t)
	for hero, player in sim.next(&players) {
		if !hero.alive do continue
		slot := u8(sim.player_slot(t, player))
		if sim.timer_done(t, hero.bolt_ready) do fire_bolts(t, hero, player, slot)
		if sim.timer_done(t, hero.lightning_ready) do strike_lightning(t, hero, player)
		if sim.timer_done(t, hero.bomb_ready) do throw_bomb(t, hero, slot)
	}
}

// A fan of `bolt_count` bolts centred on the nearest enemy, BOLT_SPREAD_TURNS apart.
fire_bolts :: proc(t: ^Tick, hero: ^Hero, player: sim.Player, slot: u8) {
	target := nearest_enemy(t, hero.pos, BOLT_RANGE)
	if target < 0 do return
	aim := dmath.normalize(t.state.enemies.items[target].pos - hero.pos)
	for i in 0 ..< int(hero.bolt_count) {
		bolt, _ := sim.spawn(&t.state.bolts) or_break
		offset := (f32(i) - f32(hero.bolt_count - 1) / 2) * BOLT_SPREAD_TURNS
		bolt^ = {
			pos      = hero.pos,
			vel      = dmath.rotate2(aim, offset) * BOLT_SPEED,
			life     = sim.ticks(BOLT_LIFE_S, TICK_HZ),
			last_hit = -1,
			pierce   = hero.bolt_pierce,
			slot     = slot,
		}
	}
	sim.timer_start_ticks(t, &hero.bolt_ready, hero.bolt_interval)
	sim.emit(t, Event_Bolt_Fired{player = player, position = sim.position_2d(hero.pos), count = hero.bolt_count})
}

// From the hero to the nearest enemy in range, then on to the nearest not yet struck within LIGHTNING_CHAIN_RANGE, up
// to `chains` enemies: each takes LIGHTNING_DAMAGE, each link is an Event_Arc.
strike_lightning :: proc(t: ^Tick, hero: ^Hero, player: sim.Player) {
	from := hero.pos
	range := LIGHTNING_RANGE
	struck := 0
	for struck < int(hero.chains) {
		target := nearest_enemy(t, from, range, t.world.struck[:struck])
		if target < 0 do break
		to := t.state.enemies.items[target].pos
		sim.emit(
			t,
			Event_Arc{player = player, from = sim.position_2d(from), to = sim.position_2d(to), link = u8(struck)},
		)
		hit_enemy(t, target, LIGHTNING_DAMAGE, .Lightning)
		t.world.struck[struck] = target
		struck += 1
		from = to
		range = LIGHTNING_CHAIN_RANGE
	}
	if struck > 0 do sim.timer_start(t, &hero.lightning_ready, LIGHTNING_INTERVAL_S)
}

// A bomb lobbed at the nearest enemy's spot, landing after BOMB_FLIGHT_S.
throw_bomb :: proc(t: ^Tick, hero: ^Hero, slot: u8) {
	target := nearest_enemy(t, hero.pos, BOMB_RANGE)
	if target < 0 do return
	bomb, _, ok := sim.spawn(&t.state.bombs)
	if !ok do return
	bomb^ = {
		from   = hero.pos,
		to     = t.state.enemies.items[target].pos,
		radius = hero.blast_radius,
		slot   = slot,
	}
	sim.timer_start(t, &bomb.flight, BOMB_FLIGHT_S)
	sim.timer_start(t, &hero.bomb_ready, BOMB_INTERVAL_S)
}

// Each bolt moves, then hits the first enemy (grid order) it overlaps that it did not hit last: BOLT_DAMAGE, one
// pierce spent. A bolt out of pierces or life, or out of the arena, is gone.
move_bolts :: proc(t: ^Tick) {
	bolts := sim.iterate(&t.state.bolts)
	for bolt, handle in sim.next(&bolts) {
		bolt.pos += bolt.vel * t.dt
		bolt.life -= 1
		hit := bolt_hit(t, bolt)
		if hit >= 0 {
			hit_enemy(t, hit, BOLT_DAMAGE, .Bolt)
			bolt.last_hit = hit
			bolt.pierce -= 1
		}
		outside := abs(bolt.pos.x) > ARENA_HALF || abs(bolt.pos.y) > ARENA_HALF
		if bolt.life == 0 || bolt.pierce == 0 || outside do sim.despawn(&t.state.bolts, handle)
	}
}

// The first alive enemy (grid order) a bolt overlaps, other than the one it hit last (-1: none).
bolt_hit :: proc(t: ^Tick, bolt: ^Bolt) -> i32 {
	for row in sim.grid_near(&t.world.grid, bolt.pos) {
		for index in row {
			enemy := &t.state.enemies.items[index]
			if index == bolt.last_hit || enemy.hp <= 0 do continue
			reach := BOLT_RADIUS + ENEMY_STATS[enemy.kind].radius
			if dmath.length_sq(enemy.pos - bolt.pos) < reach * reach do return index
		}
	}
	return -1
}

// A bomb whose flight ran out lands: a blast that deals BLAST_DAMAGE to every alive enemy within its radius, at once.
fly_bombs :: proc(t: ^Tick) {
	bombs := sim.iterate(&t.state.bombs)
	for bomb, handle in sim.next(&bombs) {
		if !sim.timer_done(t, bomb.flight) do continue
		pos, radius, slot := bomb.to, bomb.radius, bomb.slot
		sim.despawn(&t.state.bombs, handle)
		walk := sim.grid_box(&t.world.grid, pos - radius, pos + radius)
		for ids in sim.grid_box_next(&walk) {
			for index in ids {
				enemy := &t.state.enemies.items[index]
				reach := radius + ENEMY_STATS[enemy.kind].radius
				if dmath.length_sq(enemy.pos - pos) < reach * reach do hit_enemy(t, index, BLAST_DAMAGE, .Blast)
			}
		}
		sim.emit(t, Event_Bomb_Landed{position = sim.position_2d(pos), radius = radius})
		if blast, _, ok := sim.spawn(&t.state.blasts); ok {
			blast^ = {
				pos    = pos,
				radius = radius,
				slot   = slot,
			}
			sim.timer_start(t, &blast.show, BLAST_SHOW_S)
		}
	}
}

// A blast is gone once it has been shown for BLAST_SHOW_S.
age_blasts :: proc(t: ^Tick) {
	blasts := sim.iterate(&t.state.blasts)
	for blast, handle in sim.next(&blasts) {
		if sim.timer_done(t, blast.show) do sim.despawn(&t.state.blasts, handle)
	}
}
