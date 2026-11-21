// The effects: cosmetic state of the view alone (never the sim's), made by events (Glue.event, the game's union) and
// moved and drawn every frame by draw_effects. Sparks and damage digits are quads; arcs are polylines. A cancelled
// event leaves its effect to play out.
package horde_hybrid_extension

import "core:math"
import "core:math/rand"
import "core:strconv"
import "unified:godot"
import "unified:sim"

import g "../../../horde/simulation/horde"

SPARKS_MAX :: 8192
NUMBERS_MAX :: 2048
ARCS_MAX :: 256
SPARK_GRAVITY :: f32(260)
SPARK_DRAG :: f32(2.5)
NUMBER_LIFE :: f32(0.7)
NUMBER_RISE :: f32(40)
DIGIT_ADVANCE :: f32(12)
ARC_LIFE :: f32(0.22)
ARC_SEGMENTS :: 9
ARC_JITTER :: f32(9)

Spark :: struct {
	pos, vel:  [2]f32,
	age, life: f32,
	size:      f32,
	color:     godot.Color,
}

Number :: struct {
	pos:   [2]f32,
	drift: f32,
	age:   f32,
	value: i32,
	color: godot.Color,
}

Arc :: struct {
	from, to: [2]f32,
	age:      f32,
}

// The view's cosmetic state (main thread).
Fx :: struct {
	sparks:  [dynamic]Spark,
	numbers: [dynamic]Number,
	arcs:    [dynamic]Arc,
	camera:  [2]f32,
	shake:   f32,
}

fx: Fx

// Glue.event: each event state; effects start on Emitted (at once, predicted).
on_event :: proc(event: g.Event, info: godot.Event_Info) {
	if info.state != .Emitted do return
	scale := f32(UNIT_PX)
	switch e in event {
	case g.Event_Enemy_Hit:
		at := e.position.xy * scale
		number_add(at, e.damage, SOURCE_COLORS[e.source])
		burst(at, 3, SOURCE_COLORS[e.source], 120, 2.5, 0.3)
	case g.Event_Enemy_Died:
		burst(e.position.xy * scale, 14, ENEMY_COLORS[e.enemy_kind], 220, 3.5, 0.6)
	case g.Event_Arc:
		if len(fx.arcs) < ARCS_MAX do append(&fx.arcs, Arc{from = e.from.xy * scale, to = e.to.xy * scale})
	case g.Event_Bomb_Landed:
		burst(e.position.xy * scale, 30, {1.0, 0.6, 0.25, 1}, 360, 4, 0.7)
		fx.shake = min(fx.shake + 4, 12)
	case g.Event_Gem_Collected:
		burst(e.position.xy * scale, 4, {0.4, 0.95, 1.0, 1}, 80, 2, 0.3)
	case g.Event_Level_Up:
		burst(e.position.xy * scale, 40, {1.0, 0.95, 0.5, 1}, 300, 3, 0.9)
	case g.Event_Bolt_Fired, g.Event_Hero_Hurt, g.Event_Hero_Down, g.Event_Match_Over:
	case sim.Event_Player_Joined, sim.Event_Player_Left:
	}
}

// `count` sparks from `at` (px) in `color`, up to `speed` px/s each way; past SPARKS_MAX the oldest give way.
burst :: proc(at: [2]f32, count: int, color: godot.Color, speed, size, life: f32) {
	for _ in 0 ..< count {
		angle := rand.float32() * math.TAU
		vel := [2]f32{math.cos(angle), math.sin(angle)} * speed * (0.3 + 0.7 * rand.float32()) - {0, speed * 0.3}
		spark := Spark {
			pos   = at,
			vel   = vel,
			life  = life * (0.6 + 0.4 * rand.float32()),
			size  = size * (0.6 + 0.4 * rand.float32()),
			color = color,
		}
		if len(fx.sparks) < SPARKS_MAX {
			append(&fx.sparks, spark)
		} else {
			fx.sparks[rand.int_max(SPARKS_MAX)] = spark
		}
	}
}

number_add :: proc(at: [2]f32, value: i32, color: godot.Color) {
	if len(fx.numbers) >= NUMBERS_MAX do unordered_remove(&fx.numbers, 0)
	append(&fx.numbers, Number{pos = at - {0, 24}, drift = rand.float32_range(-20, 20), value = value, color = color})
}

// Ages, moves and draws every effect.
draw_effects :: proc(d: ^Draw) {
	dt := d.dt
	drag := math.exp(-SPARK_DRAG * dt)
	keep := 0
	for &spark in fx.sparks {
		spark.age += dt
		if spark.age >= spark.life do continue
		spark.vel = spark.vel * drag + {0, SPARK_GRAVITY * dt}
		spark.pos += spark.vel * dt
		k := spark.age / spark.life
		r := spark.size * (1 - 0.6 * k)
		godot.quad(canvas.sparks, spark.pos, 0, {r, r}, {spark.color.r, spark.color.g, spark.color.b, 1 - k * k})
		fx.sparks[keep] = spark
		keep += 1
	}
	resize(&fx.sparks, keep)
	keep = 0
	digits: [12]u8
	for &number in fx.numbers {
		number.age += dt
		if number.age >= NUMBER_LIFE do continue
		number.pos += {number.drift, -NUMBER_RISE} * dt
		k := number.age / NUMBER_LIFE
		color := godot.Color{number.color.r, number.color.g, number.color.b, 1 - k * k}
		text := strconv.write_int(digits[:], i64(number.value), 10)
		left := number.pos.x - f32(len(text) - 1) * DIGIT_ADVANCE / 2
		for char, i in text {
			godot.quad(
				canvas.digits,
				{left + f32(i) * DIGIT_ADVANCE, number.pos.y},
				0,
				{1, 1},
				color,
				{f32(char - '0'), 0, 0, 0},
			)
		}
		fx.numbers[keep] = number
		keep += 1
	}
	resize(&fx.numbers, keep)
	keep = 0
	points: [ARC_SEGMENTS + 1][2]f32
	for &arc in fx.arcs {
		arc.age += dt
		if arc.age >= ARC_LIFE do continue
		along := arc.to - arc.from
		side := [2]f32{-along.y, along.x} / max(math.sqrt(along.x * along.x + along.y * along.y), 0.001)
		for i in 0 ..= ARC_SEGMENTS {
			offset: f32 = i == 0 || i == ARC_SEGMENTS ? 0 : rand.float32_range(-ARC_JITTER, ARC_JITTER)
			points[i] = arc.from + along * (f32(i) / ARC_SEGMENTS) + side * offset
		}
		godot.polyline(canvas.air, points[:], {0.7, 0.9, 1.0, 1 - arc.age / ARC_LIFE}, 3)
		fx.arcs[keep] = arc
		keep += 1
	}
	resize(&fx.arcs, keep)
}
