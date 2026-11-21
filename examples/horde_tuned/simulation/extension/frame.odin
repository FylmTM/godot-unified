package horde_tuned_extension

import "unified:dmath"
import "unified:godot"
import "unified:sim"

import g "../../../horde/simulation/horde"

Frame :: godot.Frame(g.Game, View, MultiView)

UNIT_PX :: 32 // view pixels per sim unit

FLASH_TICKS :: 6 // an enemy flashes this long after a hit

// The scene views: only the few (heroes, bombs, blasts). The crowds are MultiMesh views.
View :: union {
	View_Hero,
	View_Bomb,
	View_Blast,
}

// The crowds, one MultiMesh each: the host writes their buffers in one call per frame.
MultiView :: enum u8 {
	Enemy, // custom = {kind, flash, hp share, radius in px}; rotation: heading
	Bar, // a damaged enemy's HP bar: custom.x = HP share
	Bolt, // custom.x = slot; scale.x stretches it into a streak along its heading
	Gem, // custom.x = value
}

// A hero: its slot (its colour), whether it stands, whether it was just hurt, its HP share.
View_Hero :: struct {
	slot:  u8,
	alive: bool,
	hurt:  bool,
	_pad:  u8,
	hp_k:  f32,
}

// A bomb in the air: who threw it and how far along its flight (0..1).
View_Bomb :: struct {
	slot:     u8,
	_pad:     [3]u8,
	progress: f32,
}

// A blast: its radius in view pixels and how far along it is (0..1).
View_Blast :: struct {
	slot:     u8,
	_pad:     [3]u8,
	radius:   f32,
	progress: f32,
}

// The session data.
Data :: union {
	Data_Hud,
}

// The HUD: the match and the local hero.
Data_Hud :: struct {
	wave:    u32,
	enemies: u32,
	kills:   u32,
	time_s:  f32,
	hp:      i32,
	hp_max:  i32,
	xp:      i32,
	xp_next: i32,
	level:   i32,
	pending: i32,
	offers:  [3]g.Upgrade,
	phase:   g.Phase,
	alive:   bool,
	_pad:    [3]u8,
}

// The views of a published tick, from its state: reads the state, never writes it.
fill_frame :: proc(f: ^Frame) {
	fill_heroes(f)
	fill_enemies(f)
	fill_bolts(f)
	fill_gems(f)
	fill_bombs(f)
	fill_blasts(f)
	fill_hud(f)
}

fill_heroes :: proc(f: ^Frame) {
	players := sim.iterate_present(&f.state.players)
	for hero, player in sim.next(&players) {
		slot, _ := sim.player_slot(&f.state.players, player)
		godot.push_view(f, player, {pos = sim.position_2d(hero.pos), warp = hero.warp}, View_Hero {
			slot  = u8(slot),
			alive = hero.alive,
			hurt  = sim.timer_running_at(f.time, hero.hurt),
			hp_k  = f32(hero.hp) / f32(dmath.max(hero.hp_max, 1)),
		})
	}
}

fill_enemies :: proc(f: ^Frame) {
	enemies := sim.iterate(&f.state.enemies)
	for enemy, handle in sim.next(&enemies) {
		radius := g.ENEMY_STATS[enemy.kind].radius * UNIT_PX
		flash: f32 = enemy.hit_tick != 0 && f.time - enemy.hit_tick < FLASH_TICKS ? 1 : 0
		hp_k := f32(enemy.hp) / f32(dmath.max(enemy.hp_max, 1))
		key := sim.handle_key(handle)
		pos := sim.position_2d(enemy.pos)
		godot.push_multi_view(f, {
			key    = key,
			kind   = .Enemy,
			pos    = pos,
			rot    = godot.quat_turns_2d(dmath.atan2_turns(enemy.vel.y, enemy.vel.x)),
			scale  = {radius * 1.6, radius * 1.6, 1},
			custom = {f32(enemy.kind), flash, hp_k, radius},
		})
		if hp_k < 1 {
			godot.push_multi_view(f, {
				key    = key,
				kind   = .Bar,
				pos    = pos + {0, -g.ENEMY_STATS[enemy.kind].radius - 0.25, 0},
				custom = {hp_k, 0, 0, 0},
			})
		}
	}
}

fill_bolts :: proc(f: ^Frame) {
	bolts := sim.iterate(&f.state.bolts)
	for bolt, handle in sim.next(&bolts) {
		godot.push_multi_view(f, {
			key    = sim.handle_key(handle),
			kind   = .Bolt,
			pos    = sim.position_2d(bolt.pos),
			rot    = godot.quat_turns_2d(dmath.atan2_turns(bolt.vel.y, bolt.vel.x)),
			custom = {f32(bolt.slot), 0, 0, 0},
		})
	}
}

fill_gems :: proc(f: ^Frame) {
	gems := sim.iterate(&f.state.gems)
	for gem, handle in sim.next(&gems) {
		godot.push_multi_view(f, {
			key    = sim.handle_key(handle),
			kind   = .Gem,
			pos    = sim.position_2d(gem.pos),
			custom = {f32(gem.value), f32(handle.index % 64) / 64, 0, 0},
		})
	}
}

fill_bombs :: proc(f: ^Frame) {
	bombs := sim.iterate(&f.state.bombs)
	for bomb, handle in sim.next(&bombs) {
		progress := sim.timer_fraction_at(f.time, bomb.flight)
		pos := bomb.from + (bomb.to - bomb.from) * progress
		godot.push_view(f, handle, {pos = sim.position_2d(pos)}, View_Bomb{slot = bomb.slot, progress = progress})
	}
}

fill_blasts :: proc(f: ^Frame) {
	blasts := sim.iterate(&f.state.blasts)
	for blast, handle in sim.next(&blasts) {
		godot.push_view(f, handle, {pos = sim.position_2d(blast.pos)}, View_Blast {
			slot     = blast.slot,
			radius   = blast.radius * UNIT_PX,
			progress = sim.timer_fraction_at(f.time, blast.show),
		})
	}
}

fill_hud :: proc(f: ^Frame) {
	hud := Data_Hud {
		wave    = f.state.wave,
		enemies = u32(f.state.enemies.count),
		kills   = f.state.kills,
		time_s  = f32(f.time - f.state.match_tick) / f32(g.TICK_HZ),
		phase   = f.state.phase,
	}
	if hero := sim.player_data(&f.state.players, f.local_players[0]); hero != nil {
		hud.hp = hero.hp
		hud.hp_max = hero.hp_max
		hud.xp = hero.xp
		hud.xp_next = g.xp_to_next(hero.level)
		hud.level = hero.level
		hud.pending = hero.pending_levelups
		hud.alive = hero.alive
		if hero.pending_levelups > 0 {
			hud.offers = g.upgrade_offers(f.seed, f.local_players[0], g.oldest_pending_level(hero))
		}
	}
	godot.push_data(f, hud)
}
