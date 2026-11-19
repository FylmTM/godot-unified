package test_dmath

import "core:log"
import "core:math"
import "core:testing"

import "unified:dmath"

// The sweep: a fixed, integer-generated set of inputs per function, the same on every platform. Dense small angles
// (every 1/4096 turn over ±24 turns), then pseudo-random finite bit patterns over every magnitude.
SWEEP_DENSE :: 196608
SWEEP_RANDOM :: 65536

@(private = "file")
sweep_input :: proc(i: int) -> f32 {
	if i < SWEEP_DENSE do return f32(i - SWEEP_DENSE / 2) / 4096
	state := u32(i) * 2654435761 + 12345
	state ~= state >> 15
	state *= 2246822519
	state ~= state >> 13
	bits := state & 0x7FFF_FFFF
	if bits >= 0x7F80_0000 do bits &= 0x4FFF_FFFF // keep it finite
	if state & 0x8000_0000 != 0 do bits |= 0x8000_0000
	return transmute(f32)bits
}

@(private = "file")
hash_mix :: proc(hash: ^u64, bits: u32) {
	hash^ = (hash^ ~ u64(bits)) * 0x100000001B3
}

// The results' bits over the sweep, hashed, are pinned: every platform must compute these exact values. A failure
// here with trig_matches_its_strict_twin passing means the polynomials changed; with it failing, the compiler fused
// or reordered an operation.
SIN_COS_HASH :: u64(0xf8abe088f9284591)
ATAN2_HASH :: u64(0xd8f340e9fffa60ed)
EXP_HASH :: u64(0xe43dc0539a986ba9)

@(test)
trig_bits_are_pinned :: proc(t: ^testing.T) {
	sin_cos_hash, atan2_hash, exp_hash := u64(0xCBF29CE484222325), u64(0xCBF29CE484222325), u64(0xCBF29CE484222325)
	for i in 0 ..< SWEEP_DENSE + SWEEP_RANDOM {
		x := sweep_input(i)
		s, c := dmath.sin_cos(x)
		hash_mix(&sin_cos_hash, transmute(u32)s)
		hash_mix(&sin_cos_hash, transmute(u32)c)
		y := sweep_input((i * 7919 + 17) % (SWEEP_DENSE + SWEEP_RANDOM))
		hash_mix(&atan2_hash, transmute(u32)dmath.atan2_turns(y, x))
		hash_mix(&exp_hash, transmute(u32)dmath.exp(x / 1024 if i >= SWEEP_DENSE else x * 4))
	}
	log.infof("%v: sin_cos %016x, atan2_turns %016x, exp %016x", ODIN_ARCH, sin_cos_hash, atan2_hash, exp_hash)
	testing.expectf(
		t,
		sin_cos_hash == SIN_COS_HASH,
		"sin_cos sweep hash %016x, pinned %016x",
		sin_cos_hash,
		SIN_COS_HASH,
	)
	testing.expectf(t, atan2_hash == ATAN2_HASH, "atan2_turns sweep hash %016x, pinned %016x", atan2_hash, ATAN2_HASH)
	testing.expectf(t, exp_hash == EXP_HASH, "exp sweep hash %016x, pinned %016x", exp_hash, EXP_HASH)
}

// The exact cases a game can rely on.
@(test)
trig_exact_values :: proc(t: ^testing.T) {
	for k in -16 ..= 16 {
		want := dmath.DIR8[(k % 8 + 8) % 8]
		got := dmath.angle_vec(f32(k) / 8)
		testing.expectf(
			t,
			transmute(u32)got.x == transmute(u32)want.x && transmute(u32)got.y == transmute(u32)want.y,
			"angle_vec(%v/8) = %08x %08x, want DIR8's %08x %08x",
			k,
			transmute(u32)got.x,
			transmute(u32)got.y,
			transmute(u32)want.x,
			transmute(u32)want.y,
		)
	}
	testing.expect_value(t, dmath.rotate2({2, 3}, 0.25), [2]f32{-3, 2})
	testing.expect_value(t, dmath.rotate2({2, 3}, -0.5), [2]f32{-2, -3})
	// atan2 on the axes and the diagonals
	Pair :: struct {
		y, x, want: f32,
	}
	axes := []Pair {
		{0, 1, 0},
		{1, 0, 0.25},
		{0, -1, 0.5},
		{-1, 0, -0.25},
		{1, 1, 0.125},
		{1, -1, 0.375},
		{-1, -1, -0.375},
		{-1, 1, -0.125},
		{0, 0, 0},
		{transmute(f32)u32(0x8000_0000), -1, 0.5},
		{5, 5, 0.125},
		{-1e-20, -1, 0.5}, // just below the -x axis, a half turn when rounded: 0.5, never -0.5
		{-1e-9, -3, 0.5},
	}
	for pair in axes {
		testing.expectf(
			t,
			dmath.atan2_turns(pair.y, pair.x) == pair.want,
			"atan2_turns(%v, %v) = %v, want %v",
			pair.y,
			pair.x,
			dmath.atan2_turns(pair.y, pair.x),
			pair.want,
		)
	}
	for k in -3 ..= 4 {
		testing.expect_value(t, dmath.angle_of(dmath.DIR8[(k + 8) % 8]), f32(k) / 8)
	}
	// wrap_angle: (-0.5, 0.5], exact
	testing.expect_value(t, dmath.wrap_angle(0.5), 0.5)
	testing.expect_value(t, dmath.wrap_angle(-0.5), 0.5)
	testing.expect_value(t, dmath.wrap_angle(1.25), 0.25)
	testing.expect_value(t, dmath.wrap_angle(-3.75), 0.25)
	testing.expect_value(t, dmath.wrap_angle(0.75), -0.25)
	testing.expect_value(t, dmath.wrap_angle(1e9), 0)
	testing.expect_value(t, dmath.angle_diff(0.375, -0.375), 0.25)
	testing.expect_value(t, dmath.round(0.5), 1)
	testing.expect_value(t, dmath.round(-0.5), 0)
	testing.expect_value(t, dmath.round(-1.5), -1)
	testing.expect_value(t, dmath.round(2.4999998), 2)
	testing.expect_value(t, dmath.floor(-0.25), -1)
	testing.expect_value(t, dmath.floor(3), 3)
	testing.expect_value(t, dmath.floor(1e10), 1e10)
	// exp
	testing.expect_value(t, dmath.exp(0), 1)
	testing.expect_value(t, transmute(u32)dmath.exp(1), 0x402df854)
	testing.expect_value(t, dmath.exp(-100), 0)
	testing.expect_value(t, dmath.exp(100), 1.6516363e+38)
	testing.expect_value(t, dmath.exp_decay(0, 1), 1)
	testing.expect_value(t, dmath.exp_decay(-2, 1), 1)
	testing.expect_value(t, dmath.exp_decay(1000, 1), 0)
	testing.expect_value(t, dmath.exp_decay(2, 0.5), dmath.exp(-1))
	// Bits that aren't numbers still give finite, defined answers.
	nan, inf := transmute(f32)u32(0x7FC0_0000), transmute(f32)u32(0x7F80_0000)
	for bad in ([]f32{nan, inf, -inf, transmute(f32)u32(0xFFC0_0000)}) {
		s, c := dmath.sin_cos(bad)
		testing.expect(t, s == 0 && c == 1, "sin_cos of a NaN or an infinity is (0, 1)")
		testing.expect_value(t, dmath.wrap_angle(bad), 0)
		testing.expect(t, dmath.atan2_turns(bad, 1) == dmath.atan2_turns(bad, 1), "atan2_turns of a NaN is a number")
		testing.expect(t, dmath.exp(bad) == dmath.exp(bad), "exp of a NaN is a number")
	}
	testing.expect_value(t, dmath.atan2_turns(inf, inf), 0.125)
	testing.expect_value(t, dmath.atan2_turns(nan, 1), 0.125) // a NaN y beside a non-zero x: a diagonal
	testing.expect_value(t, dmath.atan2_turns(1, nan), 0) // a NaN x: 0
	testing.expect_value(t, dmath.atan2_turns(-1, nan), 0)
	testing.expect_value(t, dmath.exp(nan), 0)
	// smoothstep, lerp
	testing.expect_value(t, dmath.smoothstep(0, 1, 0.5), 0.5)
	testing.expect_value(t, dmath.smoothstep(2, 4, 1), 0)
	testing.expect_value(t, dmath.smoothstep(2, 4, 5), 1)
	testing.expect_value(t, dmath.smoothstep(2, 2, 2), 0)
	testing.expect_value(t, dmath.smoothstep(2, 2, 2.5), 1)
	testing.expect_value(t, dmath.smoothstep(0, 1, nan), 0)
	testing.expect_value(t, dmath.lerp(f32(2), 4, 0.25), 2.5)
	a, b := [3]f32{1, 2, 3}, [3]f32{5, -2, 3.5}
	testing.expect_value(
		t,
		dmath.lerp(a, b, 0.3),
		[3]f32{a.x + (b.x - a.x) * 0.3, a.y + (b.y - a.y) * 0.3, a.z + (b.z - a.z) * 0.3},
	)
}

// The procs written again with every operation as f32(f64(a) op f64(b)): one rounding each, which no compiler can
// fuse or reorder. Equal bits over the sweep say the compiled procs do exactly the operations they are written as.
@(private = "file")
add :: proc(a, b: f32) -> f32 {return f32(f64(a) + f64(b))}
@(private = "file")
sub :: proc(a, b: f32) -> f32 {return f32(f64(a) - f64(b))}
@(private = "file")
mul :: proc(a, b: f32) -> f32 {return f32(f64(a) * f64(b))}
@(private = "file")
div :: proc(a, b: f32) -> f32 {return f32(f64(a) / f64(b))}

@(private = "file")
strict_sin_cos :: proc(turns: f32) -> (f32, f32) {
	r := dmath.wrap_angle(turns) // exact by construction
	quarter := dmath.round(mul(r, 4))
	f := sub(r, mul(quarter, 0.25))
	s, c: f32
	if abs(f) == 0.125 {
		s, c = 0.70710677 if f > 0 else -0.70710677, 0.70710677
	} else {
		u := mul(f, f)
		s = mul(f, add(6.2831855, mul(u, add(-41.341663, mul(u, add(81.59255, mul(u, -75.40207)))))))
		c = add(1, mul(u, add(-19.739208, mul(u, add(64.93937, mul(u, add(-85.44882, mul(u, 59.424343))))))))
	}
	switch i32(quarter) & 3 {
	case 0:
		return s, c
	case 1:
		return c, sub(0, s)
	case 2:
		return sub(0, s), sub(0, c)
	}
	return sub(0, c), s
}

@(private = "file")
strict_atan2 :: proc(y, x: f32) -> f32 {
	ax, ay := abs(x), abs(y)
	steep := ay > ax
	num, den := ay, ax
	if steep do num, den = ax, ay
	a: f32 = 0
	if den > 0 do a = div(num, den)
	if !(a <= 1) do a = 1
	p: f32 = 0.125
	if a != 1 {
		w := mul(a, a)
		inner := mul(w, 0.00046211507)
		inner = mul(w, add(-0.0025915224, inner))
		inner = mul(w, add(0.00684993, inner))
		inner = mul(w, add(-0.011990219, inner))
		inner = mul(w, add(0.016957447, inner))
		inner = mul(w, add(-0.022611355, inner))
		inner = mul(w, add(0.031819932, inner))
		inner = mul(w, add(-0.053051267, inner))
		p = mul(a, add(0.15915494, inner))
	}
	if steep do p = sub(0.25, p)
	if x < 0 do p = sub(0.5, p)
	if y < 0 && p < 0.5 do p = sub(0, p)
	return p
}

@(private = "file")
strict_exp :: proc(x: f32) -> f32 {
	if !(x > -87) do return 0
	if x > 88 do return 1.6516363e+38
	k := dmath.round(mul(x, 1.442695))
	r := sub(sub(x, mul(k, 0.69314575)), mul(k, 1.4286068e-06))
	inner := mul(r, 0.0013941113)
	inner = mul(r, add(0.008363175, inner))
	inner = mul(r, add(0.041666374, inner))
	inner = mul(r, add(0.16666576, inner))
	inner = add(0.5, inner)
	p := add(1, add(r, mul(mul(r, r), inner)))
	return mul(p, transmute(f32)(u32(i32(k) + 127) << 23))
}

@(test)
trig_matches_its_strict_twin :: proc(t: ^testing.T) {
	failures := 0
	for i in 0 ..< SWEEP_DENSE + SWEEP_RANDOM {
		x := sweep_input(i)
		y := sweep_input((i * 7919 + 17) % (SWEEP_DENSE + SWEEP_RANDOM))
		s, c := dmath.sin_cos(x)
		ss, sc := strict_sin_cos(x)
		e := x / 1024 if i >= SWEEP_DENSE else x * 4
		same :=
			transmute(u32)s == transmute(u32)ss &&
			transmute(u32)c == transmute(u32)sc &&
			transmute(u32)dmath.atan2_turns(y, x) == transmute(u32)strict_atan2(y, x) &&
			transmute(u32)dmath.exp(e) == transmute(u32)strict_exp(e)
		if !same {
			failures += 1
			if failures <= 5 do log.errorf("at %08x (y %08x): the compiled dmath differs from one rounding per operation", transmute(u32)x, transmute(u32)y)
		}
	}
	testing.expectf(
		t,
		failures == 0,
		"%v inputs differ: the compiler fused or reordered an operation in dmath",
		failures,
	)
}

// Accuracy against f64 references, over the dense sweep and a fine one.
@(test)
trig_accuracy :: proc(t: ^testing.T) {
	TAU :: 2 * math.PI
	worst_sin_cos, worst_unit, worst_atan2, worst_round_trip, worst_exp_ulp: f64
	for i in 0 ..< SWEEP_DENSE {
		x := sweep_input(i) + f32(i % 97) / 397312 // off the grid too
		s, c := dmath.sin_cos(x)
		worst_sin_cos = max(worst_sin_cos, abs(f64(s) - math.sin(f64(x) * TAU)), abs(f64(c) - math.cos(f64(x) * TAU)))
		worst_unit = max(worst_unit, abs(f64(s) * f64(s) + f64(c) * f64(c) - 1))
		vx, vy := f32(i % 1000) - 500, f32(i / 1000) - 98
		turns := dmath.atan2_turns(vy, vx)
		if vx != 0 || vy != 0 do worst_atan2 = max(worst_atan2, abs(f64(turns) - math.atan2(f64(vy), f64(vx)) / TAU))
		worst_round_trip = max(
			worst_round_trip,
			abs(f64(dmath.angle_diff(dmath.wrap_angle(x), dmath.angle_of({c, s})))),
		)
		e := f32(i - SWEEP_DENSE / 2) / 1100 // about -89..89
		got, want := f64(dmath.exp(e)), math.exp(f64(e))
		if e > -87 && e <= 88 {
			ulp := f64(transmute(f32)(transmute(u32)f32(want) & 0x7F80_0000)) / 8388608
			worst_exp_ulp = max(worst_exp_ulp, abs(got - want) / ulp)
		}
	}
	log.infof(
		"sin/cos within %.3g, s²+c²-1 within %.3g, atan2_turns within %.3g turns, angle_of(angle_vec) within %.3g turns, exp within %.3g ulp",
		worst_sin_cos,
		worst_unit,
		worst_atan2,
		worst_round_trip,
		worst_exp_ulp,
	)
	testing.expectf(t, worst_sin_cos <= 1.2e-7, "sin_cos is off by %v", worst_sin_cos)
	testing.expectf(t, worst_unit <= 3e-7, "s² + c² - 1 is %v", worst_unit)
	testing.expectf(t, worst_atan2 <= 5e-8, "atan2_turns is off by %v turns", worst_atan2)
	testing.expectf(t, worst_round_trip <= 1e-7, "angle_of(angle_vec(x)) is off by %v turns", worst_round_trip)
	testing.expectf(t, worst_exp_ulp <= 2, "exp is off by %v ulp", worst_exp_ulp)
}

@(test)
curve_sampling :: proc(t: ^testing.T) {
	curve: dmath.Curve
	for k in 0 ..< dmath.CURVE_SAMPLES do curve.samples[k] = f32(k * k) / 961
	for k in 0 ..< dmath.CURVE_SAMPLES {
		testing.expect_value(t, dmath.curve_sample(curve, f32(k) / 31), curve.samples[k]) // exact at each sample
	}
	testing.expect_value(t, dmath.curve_sample(curve, -1), 0)
	testing.expect_value(t, dmath.curve_sample(curve, 2), 1)
	testing.expect_value(t, dmath.curve_sample(curve, transmute(f32)u32(0x7FC0_0000)), 0)
	mid := dmath.curve_sample(curve, 0.5 / 31)
	testing.expect_value(t, mid, curve.samples[1] * 0.5) // linear between
	// curve_delta telescopes: the deltas over any partition sum to the whole
	total: f32
	x0: f32
	for step in 1 ..= 37 {
		x1 := f32(step) / 37
		total += dmath.curve_delta(curve, x0, x1)
		x0 = x1
	}
	testing.expectf(t, abs(total - 1) < 1e-6, "the deltas sum to %v, want 1", total)
	line := dmath.curve_line(2, 4)
	testing.expect_value(t, line.samples[0], 2)
	testing.expect_value(t, line.samples[31], 4)
	testing.expect_value(t, dmath.curve_sample(line, 0.5), 3)
}
