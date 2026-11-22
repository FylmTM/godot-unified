package horde

import "unified:dmath"
import "unified:sim"

// Someone new starts at level 1 near the centre, HERO_SPAWN_SPACING apart by slot; someone who comes back keeps their
// hero (a downed one stays down until the respawn). In the bench every hero starts with every weapon high.
place_new_heroes :: proc(t: ^Tick) {
	for player in t.player_changes.joined {
		hero := sim.player_data(t, player)
		if hero.started do continue
		slot := sim.player_slot(t, player)
		hero_start(t, hero, slot)
	}
}

// A hero at level 1 (the bench's: at its level), alive at its slot's start spot.
hero_start :: proc(t: ^Tick, hero: ^Hero, slot: int) {
	warp := hero.warp
	hero^ = {
		pos           = {(f32(slot) - 1.5) * HERO_SPAWN_SPACING, 0},
		hp            = HERO_HP,
		hp_max        = HERO_HP,
		speed         = HERO_SPEED,
		level         = 1,
		bolt_interval = sim.ticks(BOLT_INTERVAL_S, TICK_HZ),
		blast_radius  = BLAST_RADIUS,
		bolt_count    = 1,
		bolt_pierce   = 1,
		chains        = LIGHTNING_CHAINS,
		alive         = true,
		started       = true,
		warp          = warp + 1,
	}
	if t.state.bench_hold > 0 {
		hero.bolt_count = 5
		hero.bolt_pierce = 3
		hero.bolt_interval = BOLT_INTERVAL_MIN_TICKS * 2
		hero.chains = 8
		hero.blast_radius = BLAST_RADIUS + 4 * BLAST_RADIUS_LEVELUP
	}
	// Each hero's weapons start out of step with each other and with the other heroes'.
	sim.timer_start_ticks(t, &hero.bolt_ready, 1 + u32(slot) * 3)
	sim.timer_start_ticks(t, &hero.lightning_ready, 10 + u32(slot) * 7)
	sim.timer_start_ticks(t, &hero.bomb_ready, 20 + u32(slot) * 11)
}

// The players' commands: level-up picks and the dev spawns (a build without the dev UI never gets one).
apply_commands :: proc(t: ^Tick) {
	players := sim.iterate_present(t)
	for hero, player in sim.next(&players) {
		for sent in sim.commands(t, player) {
			switch command in sent {
			case Command_Pick:
				pick_upgrade(t, hero, player, command.upgrade)
			case Command_Dev_Spawn:
				for i in 0 ..< int(command.count) {
					if !spawn_enemy(t, command.kind, dmath.DIR8[i % 8] * SPAWN_RING) do break
				}
			}
		}
	}
}

// The three upgrades a hero's level-up to `level` offers: a keyed roll naming no tick (tick 0), only the player and
// the level, so a HUD computes the same offer from the state it shows, whenever it asks.
upgrade_offers :: proc(seed: u64, player: sim.Player, level: i32) -> [3]Upgrade {
	key := sim.player_key(player)
	first := sim.roll_below_at(seed, 0, len(Upgrade), Roll.Upgrade_Offer, key, int(level) * 3)
	second := sim.roll_below_at(seed, 0, len(Upgrade) - 1, Roll.Upgrade_Offer, key, int(level) * 3 + 1)
	third := sim.roll_below_at(seed, 0, len(Upgrade) - 2, Roll.Upgrade_Offer, key, int(level) * 3 + 2)
	// Three distinct of the seven: the second skips the first, the third is the third-th of those left.
	a := int(first)
	b := (a + 1 + int(second)) % len(Upgrade)
	c, left := 0, int(third)
	for upgrade in 0 ..< len(Upgrade) {
		if upgrade == a || upgrade == b do continue
		if left == 0 {
			c = upgrade
			break
		}
		left -= 1
	}
	return {Upgrade(a), Upgrade(b), Upgrade(c)}
}

// The level the oldest of a hero's pending level-ups reached: the one a pick goes to.
oldest_pending_level :: proc(hero: ^Hero) -> i32 {
	return hero.level - hero.pending_levelups + 1
}

// A pick takes the oldest pending level-up when it is one of its offers.
pick_upgrade :: proc(t: ^Tick, hero: ^Hero, player: sim.Player, upgrade: Upgrade) {
	if hero.pending_levelups <= 0 do return
	offers := upgrade_offers(t.seed, player, oldest_pending_level(hero))
	if upgrade != offers[0] && upgrade != offers[1] && upgrade != offers[2] do return
	switch upgrade {
	case .Bolt_Count:
		hero.bolt_count += 1
	case .Bolt_Pierce:
		hero.bolt_pierce += 1
	case .Fire_Rate:
		hero.bolt_interval = dmath.max(hero.bolt_interval - BOLT_INTERVAL_LEVELUP_TICKS, BOLT_INTERVAL_MIN_TICKS)
	case .Chains:
		hero.chains = dmath.min(hero.chains + 1, CHAIN_MAX - 1)
	case .Bomb_Radius:
		hero.blast_radius += BLAST_RADIUS_LEVELUP
	case .Move_Speed:
		hero.speed += HERO_SPEED_LEVELUP
	case .Max_Hp:
		hero.hp_max += HERO_HP_LEVELUP
		hero.hp = dmath.min(hero.hp + HERO_HP_LEVELUP, hero.hp_max)
	}
	hero.pending_levelups -= 1
}

// Each alive present hero moves at up to its speed in its stick's direction, kept inside the arena.
move_heroes :: proc(t: ^Tick) {
	players := sim.iterate_present(t)
	for hero, player in sim.next(&players) {
		if !hero.alive {
			hero.vel = {}
			continue
		}
		input := sim.input(t, player)
		hero.vel = dmath.stick(input.dx, input.dy) * hero.speed
		pos := hero.pos + hero.vel * t.dt
		limit := ARENA_HALF - HERO_RADIUS
		hero.pos = {dmath.clamp(pos.x, -limit, limit), dmath.clamp(pos.y, -limit, limit)}
	}
}

// An enemy touching an alive hero whose hurt cooldown is over deals its kind's damage (the first in grid order); at 0
// HP the hero goes down. The bench's heroes take no damage.
hurt_heroes :: proc(t: ^Tick) {
	if t.state.bench_hold > 0 || t.state.phase != .Match do return
	players := sim.iterate_present(t)
	for hero, player in sim.next(&players) {
		if !hero.alive || sim.timer_running(t, hero.hurt) do continue
		damage := touching_damage(t, hero.pos)
		if damage == 0 do continue
		hero.hp -= damage
		sim.timer_start(t, &hero.hurt, HERO_HURT_COOLDOWN_S)
		sim.emit(t, Event_Hero_Hurt{player = player, position = sim.position_2d(hero.pos), damage = damage})
		if hero.hp <= 0 {
			hero.hp = 0
			hero.alive = false
			sim.timer_start(t, &hero.respawn, HERO_RESPAWN_S)
			sim.emit(t, Event_Hero_Down{player = player, position = sim.position_2d(hero.pos)})
		}
	}
}

// The damage of the first enemy (grid order) touching a hero at `pos`, 0 when none does.
touching_damage :: proc(t: ^Tick, pos: [2]f32) -> i32 {
	for row in sim.grid_near(&t.world.grid, pos) {
		for index in row {
			enemy := &t.state.enemies.items[index]
			reach := HERO_RADIUS + ENEMY_STATS[enemy.kind].radius
			if dmath.length_sq(enemy.pos - pos) < reach * reach do return ENEMY_STATS[enemy.kind].damage
		}
	}
	return 0
}

// A downed hero stands up at full HP where they fell when their respawn runs out (while the match runs).
respawn_heroes :: proc(t: ^Tick) {
	if t.state.phase != .Match do return
	players := sim.iterate_present(t)
	for hero, _ in sim.next(&players) {
		if hero.alive || !hero.started || !sim.timer_fired(t, hero.respawn) do continue
		hero.alive = true
		hero.hp = hero.hp_max
		hero.warp += 1
	}
}

// The nearest alive present hero to `pos` (nil: none), the lowest slot on ties.
nearest_hero :: proc(t: ^Tick, pos: [2]f32) -> ^Hero {
	best: ^Hero
	best_sq: f32
	players := sim.iterate_present(t)
	for hero, _ in sim.next(&players) {
		if !hero.alive do continue
		distance_sq := dmath.length_sq(hero.pos - pos)
		if best == nil || distance_sq < best_sq {
			best, best_sq = hero, distance_sq
		}
	}
	return best
}

// Every present hero down while the match runs: over, and after OVER_HOLD_S the arena resets (the heroes start again
// at level 1, every table empties) and a new match begins.
advance_phase :: proc(t: ^Tick) {
	switch t.state.phase {
	case .Match:
		t.state.wave = u32(t.time - t.state.match_tick) / sim.ticks(WAVE_S, TICK_HZ)
		any_present, any_alive := false, false
		players := sim.iterate_present(t)
		for hero, _ in sim.next(&players) {
			any_present = true
			any_alive ||= hero.alive
		}
		if any_present && !any_alive {
			t.state.phase = .Over
			sim.timer_start(t, &t.state.over_hold, OVER_HOLD_S)
			sim.emit(t, Event_Match_Over {
				duration_s = f32(t.time - t.state.match_tick) * t.dt,
				wave       = t.state.wave,
				kills      = t.state.kills,
			})
		}
	case .Over:
		if !sim.timer_fired(t, t.state.over_hold) do return
		t.state.phase = .Match
		t.state.match_tick = t.time
		t.state.wave = 0
		t.state.kills = 0
		t.state.enemies = {}
		t.state.bolts = {}
		t.state.bombs = {}
		t.state.blasts = {}
		t.state.gems = {}
		players := sim.iterate_present(t)
		for hero, player in sim.next(&players) do hero_start(t, hero, sim.player_slot(t, player))
	}
}
