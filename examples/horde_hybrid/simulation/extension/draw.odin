// The world, drawn in Odin every frame from the State (godot.Draw: the shown tick, the tick before and how far the
// screen is between them), through the immediate layer's layers and quad batches. The crowds (enemies, HP bars,
// bolts, gems, sparks, damage digits) are quad batches drawn by the shaders in shaders/; the few (heroes, bombs,
// blasts, arcs, the floor) are canvas primitives. Effects are cosmetic state of their own (fx.odin), made by events.
package horde_hybrid_extension

import "core:math"
import "core:math/rand"
import "unified:godot"
import "unified:sim"

import g "../../../horde/simulation/horde"

Draw :: godot.Draw(g.Game)

SLOT_COLORS := [4]godot.Color{{0.35, 0.75, 1.0, 1}, {1.0, 0.55, 0.35, 1}, {0.55, 1.0, 0.45, 1}, {1.0, 0.85, 0.3, 1}}
ENEMY_COLORS := [3]godot.Color{{0.55, 0.8, 0.35, 1}, {0.95, 0.7, 0.25, 1}, {0.7, 0.35, 0.9, 1}}
SOURCE_COLORS := [3]godot.Color{{1, 1, 1, 1}, {0.6, 0.85, 1.0, 1}, {1.0, 0.6, 0.25, 1}}
FLOOR :: godot.Color{0.09, 0.1, 0.12, 1}
GRID :: godot.Color{0.14, 0.15, 0.18, 1}
WALL :: godot.Color{0.4, 0.42, 0.5, 1}

FLASH_TICKS :: 6 // an enemy flashes this long after a hit
BOMB_ARC_PX :: f32(60)

// The layers and batches, made on the first draw (they live for the process).
Canvas :: struct {
	made:    bool,
	floor:   godot.Layer,
	ground:  godot.Layer, // gems
	bodies:  godot.Layer, // enemies, bars, heroes
	air:     godot.Layer, // bolts, bombs, blasts, sparks, arcs
	text:    godot.Layer, // damage digits
	gems:    godot.Batch,
	enemies: godot.Batch,
	bars:    godot.Batch,
	bolts:   godot.Batch,
	sparks:  godot.Batch,
	digits:  godot.Batch,
}

canvas: Canvas

// Glue.draw: the camera, the floor, the State's things, then the effects.
draw :: proc(d: ^Draw) {
	if !canvas.made do canvas_make()
	follow_camera(d)
	draw_floor(d)
	draw_gems(d)
	draw_enemies(d)
	draw_bolts(d)
	draw_heroes(d)
	draw_bombs_and_blasts(d)
	draw_effects(d)
}

canvas_make :: proc() {
	canvas.floor = godot.layer(0)
	canvas.ground = godot.layer(1)
	canvas.bodies = godot.layer(2)
	canvas.air = godot.layer(3)
	canvas.text = godot.layer(4)
	canvas.gems = godot.batch_create(canvas.ground, #load("shaders/gem.gdshader", string), {9, 11})
	canvas.enemies = godot.batch_create(canvas.bodies, #load("shaders/enemy.gdshader", string), {1, 1})
	godot.batch_colors(canvas.enemies, "kinds", ENEMY_COLORS[:])
	canvas.bars = godot.batch_create(canvas.bodies, #load("shaders/bar.gdshader", string), {12, 2})
	canvas.bolts = godot.batch_create(canvas.air, #load("shaders/bolt.gdshader", string), {18, 5})
	godot.batch_colors(canvas.bolts, "palette", SLOT_COLORS[:])
	canvas.sparks = godot.batch_create(canvas.air, #load("shaders/spark.gdshader", string), {1, 1})
	canvas.digits = godot.batch_create(canvas.text, #load("shaders/digit.gdshader", string), {5, 8})
	canvas.made = true
}

// A point of the arena in view pixels.
px :: proc(d: ^Draw, pos: [2]f32) -> [2]f32 {
	return pos * d.view_scale
}

// A table item's position between the tick before and the shown one (the shown one when it is new).
lerp_pos :: proc(d: ^Draw, now, before: [2]f32, alive_before: bool) -> [2]f32 {
	return alive_before ? before + (now - before) * d.alpha : now
}

// The camera follows the local hero, with the shake the blasts add.
follow_camera :: proc(d: ^Draw) {
	player := d.local_players[0]
	if hero := sim.player_data(&d.state.players, player); hero != nil {
		before := d.prev.players.data[player.index].pos
		target := px(d, lerp_pos(d, hero.pos, before, true))
		fx.camera = fx.camera + (target - fx.camera) * (1 - math.exp(-8 * d.dt))
	}
	fx.shake = max(fx.shake - d.dt * 30, 0)
	offset := [2]f32{rand.float32_range(-1, 1), rand.float32_range(-1, 1)} * fx.shake
	godot.camera(fx.camera, 1, offset)
}

draw_floor :: proc(d: ^Draw) {
	half := g.ARENA_HALF * d.view_scale
	godot.rect(canvas.floor, {-half, -half}, {half * 2, half * 2}, FLOOR)
	step := d.view_scale * 2
	for x := -half; x <= half; x += step {
		godot.line(canvas.floor, {x, -half}, {x, half}, GRID)
		godot.line(canvas.floor, {-half, x}, {half, x}, GRID)
	}
	godot.polyline(canvas.floor, {{-half, -half}, {half, -half}, {half, half}, {-half, half}, {-half, -half}}, WALL, 4)
}

draw_gems :: proc(d: ^Draw) {
	gems := sim.iterate(&d.state.gems)
	for gem, handle in sim.next(&gems) {
		before := d.prev.gems.slots[handle.index]
		pos := lerp_pos(
			d,
			gem.pos,
			d.prev.gems.items[handle.index].pos,
			before.alive && before.generation == handle.generation,
		)
		godot.quad(canvas.gems, px(d, pos), custom = {f32(gem.value), f32(handle.index % 64) / 64, 0, 0})
	}
}

draw_enemies :: proc(d: ^Draw) {
	enemies := sim.iterate(&d.state.enemies)
	for enemy, handle in sim.next(&enemies) {
		before := d.prev.enemies.slots[handle.index]
		pos := px(
			d,
			lerp_pos(
				d,
				enemy.pos,
				d.prev.enemies.items[handle.index].pos,
				before.alive && before.generation == handle.generation,
			),
		)
		radius := g.ENEMY_STATS[enemy.kind].radius * d.view_scale
		flash: f32 = enemy.hit_tick != 0 && sim.game_time(d.state, d.tick) - enemy.hit_tick < FLASH_TICKS ? 1 : 0
		hp_k := f32(enemy.hp) / f32(max(enemy.hp_max, 1))
		godot.quad(
			canvas.enemies,
			pos,
			math.atan2(enemy.vel.y, enemy.vel.x) / math.TAU,
			{radius * 1.6, radius * 1.6},
			custom = {f32(enemy.kind), flash, hp_k, radius},
		)
		if hp_k < 1 do godot.quad(canvas.bars, pos - {0, radius + 8}, custom = {hp_k, 0, 0, 0})
	}
}

draw_bolts :: proc(d: ^Draw) {
	bolts := sim.iterate(&d.state.bolts)
	for bolt, handle in sim.next(&bolts) {
		before := d.prev.bolts.slots[handle.index]
		pos := lerp_pos(
			d,
			bolt.pos,
			d.prev.bolts.items[handle.index].pos,
			before.alive && before.generation == handle.generation,
		)
		godot.quad(
			canvas.bolts,
			px(d, pos),
			math.atan2(bolt.vel.y, bolt.vel.x) / math.TAU,
			custom = {f32(bolt.slot), 0, 0, 0},
		)
	}
}

draw_heroes :: proc(d: ^Draw) {
	players := sim.iterate_present(&d.state.players)
	for hero, player in sim.next(&players) {
		slot, _ := sim.player_slot(&d.state.players, player)
		color := SLOT_COLORS[slot % len(SLOT_COLORS)]
		before := d.prev.players.data[player.index]
		pos := px(d, lerp_pos(d, hero.pos, before.pos, before.warp == hero.warp))
		r := g.HERO_RADIUS * d.view_scale
		if !hero.alive {
			ring(canvas.bodies, pos, r, color * {0.5, 0.5, 0.5, 1}, 2)
			continue
		}
		pulse := f32(0.5 + 0.5 * math.sin(d.time_s * 4))
		ring(canvas.bodies, pos, r * (1.6 + 0.15 * pulse), {color.r, color.g, color.b, 0.35}, 2)
		hurt := sim.timer_running_at(sim.game_time(d.state, d.tick), hero.hurt) && int(d.time_s * 20) % 2 == 0
		body := hurt ? godot.Color{1, 1, 1, 1} : color
		godot.circle(canvas.bodies, pos, r, body * {0.6, 0.6, 0.6, 1})
		godot.circle(canvas.bodies, pos, r * 0.8, body)
		look: [2]f32 =
			hero.vel == {} ? {0, 1} : hero.vel / math.sqrt(hero.vel.x * hero.vel.x + hero.vel.y * hero.vel.y)
		godot.circle(canvas.bodies, pos + look * r * 0.7, r * 0.25, {1, 1, 1, 1})
		hp_k := f32(hero.hp) / f32(max(hero.hp_max, 1))
		godot.rect(canvas.bodies, pos + {-r, r + 5}, {r * 2, 4}, {0, 0, 0, 0.6})
		godot.rect(canvas.bodies, pos + {-r, r + 5}, {r * 2 * hp_k, 4}, {0.3, 0.95, 0.4, 1})
	}
}

draw_bombs_and_blasts :: proc(d: ^Draw) {
	time := sim.game_time(d.state, d.tick)
	bombs := sim.iterate(&d.state.bombs)
	for bomb, _ in sim.next(&bombs) {
		progress := sim.timer_fraction_at(time, bomb.flight)
		pos := px(d, bomb.from + (bomb.to - bomb.from) * progress)
		lift := math.sin(progress * math.PI) * BOMB_ARC_PX
		godot.circle(canvas.air, pos, 6 * (1 - progress * 0.3), {0, 0, 0, 0.35})
		godot.circle(canvas.air, pos - {0, lift}, 7, {0.2, 0.2, 0.22, 1})
		godot.circle(canvas.air, pos - {2, lift + 2}, 2.5, {1.0, 0.6, 0.25, 1})
	}
	blasts := sim.iterate(&d.state.blasts)
	for blast, _ in sim.next(&blasts) {
		t := sim.timer_fraction_at(time, blast.show)
		pos := px(d, blast.pos)
		radius := blast.radius * d.view_scale
		godot.circle(canvas.air, pos, radius * (0.4 + 0.6 * t), {1.0, 0.65, 0.3, 0.35 * (1 - t)})
		ring(canvas.air, pos, radius * (0.5 + 0.6 * t), {1, 0.9, 0.7, 1 - t}, 6 * (1 - t) + 1)
	}
}

RING_SEGMENTS :: 32

// A circle's outline, `width` wide.
ring :: proc(layer: godot.Layer, center: [2]f32, radius: f32, color: godot.Color, width: f32) {
	points: [RING_SEGMENTS + 1][2]f32
	for i in 0 ..= RING_SEGMENTS {
		angle := f32(i) / RING_SEGMENTS * math.TAU
		points[i] = center + {math.cos(angle), math.sin(angle)} * radius
	}
	godot.polyline(layer, points[:], color, width)
}
