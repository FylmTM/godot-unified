package horde_extension

import "unified:dmath"
import "unified:godot"
import "unified:sim"

import g "../horde"

Frame :: godot.Frame(g.Game, View, MultiView)

UNIT_PX :: 32 // view pixels per sim unit

FLASH_TICKS :: 6 // an enemy flashes this long after a hit

// The scene views, a struct per kind: what its view's script reads as `data` (ViewEnemy). The naive way: a scene per
// hero, enemy, bolt, gem, bomb and blast.
View :: union {
	View_Hero,
	View_Enemy,
	View_Bolt,
	View_Gem,
	View_Bomb,
	View_Blast,
}

// The naive example shows no MultiMesh (one kind, never pushed: the enum can't be empty).
MultiView :: enum u8 {
	Unused,
}

// A hero: its slot (its colour), whether it stands, whether it was just hurt, its HP share.
View_Hero :: struct {
	slot:  u8,
	alive: bool,
	hurt:  bool,
	_pad:  u8,
	hp_k:  f32,
}

// An enemy: its kind, its hit flash, its HP share.
View_Enemy :: struct {
	kind:  g.Enemy_Kind,
	flash: bool,
	_pad:  [2]u8,
	hp_k:  f32,
}

// A bolt: who fired it (its colour). Its rotation is its heading.
View_Bolt :: struct {
	slot: u8,
	_pad: [3]u8,
}

// A gem: its value (a bigger gem for more XP).
View_Gem :: struct {
	value: i32,
}

// A bomb in the air: who threw it and how far along its flight (0..1: its arc's height comes from it).
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
	pending: i32, // level-ups waiting for a pick
	offers:  [3]g.Upgrade, // the oldest pending level-up's offers (when pending > 0)
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
		flash := enemy.hit_tick != 0 && f.time - enemy.hit_tick < FLASH_TICKS
		godot.push_view(f, handle, {pos = sim.position_2d(enemy.pos)}, View_Enemy {
			kind  = enemy.kind,
			flash = flash,
			hp_k  = f32(enemy.hp) / f32(dmath.max(enemy.hp_max, 1)),
		})
	}
}

fill_bolts :: proc(f: ^Frame) {
	bolts := sim.iterate(&f.state.bolts)
	for bolt, handle in sim.next(&bolts) {
		turns := dmath.atan2_turns(bolt.vel.y, bolt.vel.x)
		godot.push_view(
			f,
			handle,
			{pos = sim.position_2d(bolt.pos), rot = godot.quat_turns_2d(turns)},
			View_Bolt{slot = bolt.slot},
		)
	}
}

fill_gems :: proc(f: ^Frame) {
	gems := sim.iterate(&f.state.gems)
	for gem, handle in sim.next(&gems) {
		godot.push_view(f, handle, {pos = sim.position_2d(gem.pos)}, View_Gem{value = gem.value})
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
