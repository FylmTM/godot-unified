// exp, easing and designer curves: e^x as a fixed polynomial (src/dmath/README.md, Transcendentals), lerp and
// smoothstep, and a Curve sampled at bake time that tick code only looks up.
package dmath

// e^r = 1 + r + r² · E(r) on |r| <= ln 2 / 2 (minimax; each literal an exact f32).
@(private)
E2 :: 0.5
@(private)
E3 :: 0.16666576
@(private)
E4 :: 0.041666374
@(private)
E5 :: 0.008363175
@(private)
E6 :: 0.0013941113
@(private)
INV_LN2 :: 1.442695
// ln 2 split in two: LN2_HI's low bits are zero, so k · LN2_HI is exact for every k exp meets.
@(private)
LN2_HI :: 0.69314575
@(private)
LN2_LO :: 1.4286068e-06

// e^x within 1.4 ulp. Below -87 (and a NaN) it is 0, above 88 e^88: never an infinity, never a subnormal, so the
// result can always go into the block.
exp :: proc "contextless" (x: f32) -> f32 {
	if !(x > -87) do return 0
	if x > 88 do return 1.6516363e+38
	k := round(x * INV_LN2) // -126..127
	r := (x - k * LN2_HI) - k * LN2_LO // |r| <= ln 2 / 2
	p := 1 + (r + r * r * (E2 + r * (E3 + r * (E4 + r * (E5 + r * E6)))))
	return p * transmute(f32)(u32(i32(k) + 127) << 23) // times 2^k, exact
}

// What is left of a difference after dt seconds of exponential decay at `rate` per second: e^(-rate · dt), in
// [0, 1]. `value = lerp(target, value, exp_decay(RATE, t.dt))` approaches the target at the same speed at any tick
// rate. rate · dt <= 0 (or a NaN) gives 1.
exp_decay :: proc "contextless" (rate, dt: f32) -> f32 {
	v := rate * dt
	if !(v > 0) do return 1
	return exp(0 - v)
}

// a + (b - a) · t: a at t = 0, b at t = 1 (t is not clamped). For f32 and fixed arrays of f32 ([2]f32, [3]f32) alike.
lerp :: proc "contextless" (a, b: $T, t: f32) -> T {
	return a + (b - a) * t
}

// 0 at and below edge0, 1 at and above edge1, and the smooth step 3u² − 2u³ between (u = (x − edge0) / (edge1 −
// edge0), computed as u · u · (3 − 2u)). edge0 == edge1 is a step at that point; a NaN x gives 0.
smoothstep :: proc "contextless" (edge0, edge1, x: f32) -> f32 {
	if !(x > edge0) do return 0
	if x >= edge1 do return 1
	u := (x - edge0) / (edge1 - edge0)
	return u * u * (3 - 2 * u)
}

// The samples a Curve holds.
CURVE_SAMPLES :: 32

// A designer curve over x in 0..1, sampled at bake time (a Godot Curve on a level marker: level.prop_curve):
// samples[k] is its value at x = k / 31. Plain data, for a World or the block.
Curve :: struct {
	samples: [CURVE_SAMPLES]f32,
}

// The curve's value at x: x clamped to 0..1 (a NaN gives the first sample), linear between two samples and exact at
// each.
curve_sample :: proc "contextless" (curve: Curve, x: f32) -> f32 {
	at := x * (CURVE_SAMPLES - 1)
	if !(at > 0) do return curve.samples[0]
	if at >= CURVE_SAMPLES - 1 do return curve.samples[CURVE_SAMPLES - 1]
	index := i32(at)
	a, b := curve.samples[index], curve.samples[index + 1]
	return a + (b - a) * (at - f32(index))
}

// How much the curve moved from x0 to x1: curve_sample(x1) − curve_sample(x0). Add it each tick instead of setting a
// value from the curve, so a curve-driven motion composes with everything else that moves the same thing.
curve_delta :: proc "contextless" (curve: Curve, x0, x1: f32) -> f32 {
	return curve_sample(curve, x1) - curve_sample(curve, x0)
}

// A straight curve from `from` at 0 to `to` at 1: a default, and a test's.
curve_line :: proc "contextless" (from, to: f32) -> Curve {
	curve: Curve
	for k in 0 ..< CURVE_SAMPLES {
		curve.samples[k] = lerp(from, to, f32(k) / (CURVE_SAMPLES - 1))
	}
	return curve
}
