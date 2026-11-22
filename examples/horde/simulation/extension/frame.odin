// The view contract's views (examples/horde/README.md, View contract): scene views for the few (heroes, bombs in
// the air, blasts) and MultiMesh views for the crowds (enemies, their HP bars, bolts, gems), filled from a published
// tick's state. The host writes each MultiMesh's instances in one buffer per frame; the game's shaders draw them
// (game/multi/).
package horde_extension

import "unified:dmath"
import "unified:godot"
import "unified:sim"

import g "../horde"

// The frame fill_frame fills.
Frame :: godot.Frame(g.Game, View, MultiView)

UNIT_PX :: 32 // view pixels per sim unit
FLASH_TICKS :: 6 // an enemy flashes this long after a hit
ENEMY_QUAD_RADII :: 1.6 // an enemy's quad reaches this many of its radii each way (room for its shadow and wobble)
BAR_LIFT :: 0.25 // an HP bar floats this far (sim units) above its enemy's top

// The scene views: only the few. The crowds are MultiMesh views.
View :: union {
	View_Hero,
	View_Bomb,
	View_Blast,
}

// The crowds, one MultiMesh each (custom data is the shader's: game/multi/).
MultiView :: enum u8 {
	Enemy, // custom = {kind, hit flash, HP share, radius in px}; rotation: its heading; scale: its quad
	Bar, // a damaged enemy's HP bar: custom.x = HP share
	Bolt, // custom.x = the shooter's slot; rotation: its heading
	Gem, // custom = {value, bob phase 0..1}
}

// A hero (keyed by its player): its slot (its colour), whether it stands, whether it was just hurt, its HP share.
View_Hero :: struct {
	slot:     u8,
	alive:    bool,
	hurt:     bool,
	_pad:     u8,
	hp_share: f32,
}

// A bomb in the air, posed along its flight: who threw it and how far along it is (0..1).
View_Bomb :: struct {
	slot:     u8,
	_pad:     [3]u8,
	progress: f32,
}

// A blast where a bomb landed: who threw it, its radius in view pixels and how far along its showing it is (0..1).
View_Blast :: struct {
	slot:     u8,
	_pad:     [3]u8,
	radius:   f32,
	progress: f32,
}

// The views and the HUD's data of a published tick, from its state: reads the state, never writes it.
fill_frame :: proc(f: ^Frame) {
	fill_heroes(f)
	fill_enemies(f)
	fill_bolts(f)
	fill_gems(f)
	fill_bombs(f)
	fill_blasts(f)
	godot.push_data(f, hud_of(f))
}

// Every present hero, downed ones too (they stand up where they fell); a respawn bumps its warp, so the view snaps.
fill_heroes :: proc(f: ^Frame) {
	players := sim.iterate_present(&f.state.players)
	for hero, player in sim.next(&players) {
		slot, _ := sim.player_slot(&f.state.players, player)
		godot.push_view(f, player, {pos = sim.position_2d(hero.pos), warp = hero.warp}, View_Hero {
			slot     = u8(slot),
			alive    = hero.alive,
			hurt     = sim.timer_running_at(f.time, hero.hurt),
			hp_share = f32(hero.hp) / f32(dmath.max(hero.hp_max, 1)),
		})
	}
}

// Every enemy, facing its velocity, and an HP bar over each damaged one (keyed alike: one key space per kind).
fill_enemies :: proc(f: ^Frame) {
	enemies := sim.iterate(&f.state.enemies)
	for enemy, handle in sim.next(&enemies) {
		stats := g.ENEMY_STATS[enemy.kind]
		radius_px := stats.radius * UNIT_PX
		flash: f32 = enemy.hit_tick != 0 && f.time - enemy.hit_tick < FLASH_TICKS ? 1 : 0
		hp_share := f32(enemy.hp) / f32(dmath.max(enemy.hp_max, 1))
		key := sim.handle_key(handle)
		pos := sim.position_2d(enemy.pos)
		godot.push_multi_view(f, {
			key    = key,
			kind   = .Enemy,
			pos    = pos,
			rot    = godot.quat_turns_2d(dmath.atan2_turns(enemy.vel.y, enemy.vel.x)),
			scale  = {radius_px * ENEMY_QUAD_RADII, radius_px * ENEMY_QUAD_RADII, 1},
			custom = {f32(enemy.kind), flash, hp_share, radius_px},
		})
		if hp_share < 1 {
			godot.push_multi_view(f, {
				key    = key,
				kind   = .Bar,
				pos    = pos + {0, -stats.radius - BAR_LIFT, 0},
				custom = {hp_share, 0, 0, 0},
			})
		}
	}
}

// Every bolt in flight, facing its velocity.
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

// Every gem; its bob phase comes from its table index, so neighbours bob out of step.
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

// Every bomb in the air, posed where its flight has carried it from the thrower towards its target.
fill_bombs :: proc(f: ^Frame) {
	bombs := sim.iterate(&f.state.bombs)
	for bomb, handle in sim.next(&bombs) {
		progress := sim.timer_fraction_at(f.time, bomb.flight)
		pos := bomb.from + (bomb.to - bomb.from) * progress
		godot.push_view(f, handle, {pos = sim.position_2d(pos)}, View_Bomb{slot = bomb.slot, progress = progress})
	}
}

// Every blast still shown.
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
