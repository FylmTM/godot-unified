// Angles, deterministically: turns (1 is a full circle), so range reduction is exact in f32, and sin, cos and atan2
// as fixed polynomials of `+ − ×` in Horner order (src/dmath/README.md, Transcendentals). Box3D takes radians:
// `turns * TAU`.
package dmath

// Radians in a turn (2π, the nearest f32): what a turn is multiplied by for Box3D, which takes radians.
TAU :: 6.2831855

// The largest f32 with a fraction is below 2^23: from there up every f32 is whole.
@(private)
WHOLE_FROM :: 8388608

// x rounded to the nearest whole number, a half up (toward +infinity: 0.5 → 1, -0.5 → 0, -1.5 → -1).
// From 2^23 up (and a NaN or an infinity) x is returned as it is: it has no fraction.
round :: proc "contextless" (x: f32) -> f32 {
	if !(abs(x) < WHOLE_FROM) do return x
	whole := f32(i32(x)) // truncation of an in-range value: the same on every CPU
	frac := x - whole // exact
	if frac >= 0.5 do return whole + 1
	if frac < -0.5 do return whole - 1
	return whole
}

// The largest whole number not above x. From 2^23 up (and a NaN or an infinity) x is returned as it is.
floor :: proc "contextless" (x: f32) -> f32 {
	if !(abs(x) < WHOLE_FROM) do return x
	whole := f32(i32(x))
	return whole - 1 if whole > x else whole
}

// An angle in turns brought into (-0.5, 0.5], exactly (no rounding happens): the short way round to the same
// direction. 2^23 turns and more are whole turns: 0; a NaN or an infinity gives 0 too. Wrap an angle kept in the
// block whenever it is advanced, so it never grows and loses precision.
wrap_angle :: proc "contextless" (turns: f32) -> f32 {
	if !(abs(turns) < WHOLE_FROM) do return 0
	r := turns - f32(i32(turns)) // (-1, 1), exact
	if r > 0.5 do return r - 1 // exact (Sterbenz)
	if r <= -0.5 do return r + 1
	return r
}

// The signed turn from `from` to `to` the short way round, in (-0.5, 0.5]: wrap_angle(to - from).
angle_diff :: proc "contextless" (from, to: f32) -> f32 {
	return wrap_angle(to - from)
}

// sin(2π f) = f · S(f²) and cos(2π f) = 1 + f² · C(f²) on |f| <= 1/8 (minimax fits; each literal is an exact f32).
@(private)
S0 :: 6.2831855
@(private)
S1 :: -41.341663
@(private)
S2 :: 81.59255
@(private)
S3 :: -75.40207
@(private)
C1 :: -19.739208
@(private)
C2 :: 64.93937
@(private)
C3 :: -85.44882
@(private)
C4 :: 59.424343
// sin and cos of an eighth of a turn: DIR8's value, which the polynomials miss by an ulp.
@(private)
EIGHTH :: 0.70710677

// The sine and cosine of an angle in turns, within 9e-8 of the true values (2 ulp). Exact at every eighth of a turn:
// `sin_cos(k / 8)` is DIR8[k] bit for bit (zeros are +0 there). A NaN or an infinity gives (0, 1).
sin_cos :: proc "contextless" (turns: f32) -> (sin, cos: f32) {
	r := wrap_angle(turns) // (-0.5, 0.5]
	quarter := round(r * 4) // -2..2, exact
	f := r - quarter * 0.25 // [-1/8, 1/8], exact
	s, c: f32
	if abs(f) == 0.125 {
		s, c = EIGHTH if f > 0 else -EIGHTH, EIGHTH
	} else {
		u := f * f
		s = f * (S0 + u * (S1 + u * (S2 + u * S3)))
		c = 1 + u * (C1 + u * (C2 + u * (C3 + u * C4)))
	}
	// Negation as 0 - x, so a quarter turn's zero is +0 as in DIR8.
	switch i32(quarter) & 3 {
	case 0:
		return s, c
	case 1:
		return c, 0 - s
	case 2:
		return 0 - s, 0 - c
	}
	return 0 - c, s
}

// The unit vector at an angle in turns, {cos, sin}: physics' 2D rotation and DIR8's convention (0 is +x, a quarter
// turn +y). `angle_vec(k / 8)` is DIR8[k] bit for bit.
angle_vec :: proc "contextless" (turns: f32) -> [2]f32 {
	sin, cos := sin_cos(turns)
	return {cos, sin}
}

// v turned by an angle in turns, counter-clockwise (+x toward +y): {x·cos − y·sin, x·sin + y·cos}. A quarter turn is
// exact.
rotate2 :: proc "contextless" (v: [2]f32, turns: f32) -> [2]f32 {
	sin, cos := sin_cos(turns)
	return {v.x * cos - v.y * sin, v.x * sin + v.y * cos}
}

// atan(a) / 2π = a · A(a²) on 0 <= a <= 1 (minimax, 9 terms; each literal an exact f32).
@(private)
A0 :: 0.15915494
@(private)
A1 :: -0.053051267
@(private)
A2 :: 0.031819932
@(private)
A3 :: -0.022611355
@(private)
A4 :: 0.016957447
@(private)
A5 :: -0.011990219
@(private)
A6 :: 0.00684993
@(private)
A7 :: -0.0025915224
@(private)
A8 :: 0.00046211507

// The angle of the point (x, y) in turns, in (-0.5, 0.5], within 4e-8 turns: atan2(y, x) / 2π. Exact on the axes and
// the diagonals; (0, 0) gives 0 and y = -0 counts as +0 (so (−0, −1) is 0.5), and a point just below the -x axis
// whose angle rounds to a half turn gives 0.5, never -0.5. Any bits in give a finite answer: an infinity over an
// infinity, or a NaN y beside a non-zero x, counts as a diagonal; a NaN x gives 0.
atan2_turns :: proc "contextless" (y, x: f32) -> f32 {
	ax, ay := abs(x), abs(y)
	steep := ay > ax
	num, den := ay, ax
	if steep do num, den = ax, ay
	a: f32 = 0
	if den > 0 do a = num / den
	if !(a <= 1) do a = 1 // inf / inf, a NaN
	p: f32
	if a == 1 {
		p = 0.125
	} else {
		w := a * a
		p = a * (A0 + w * (A1 + w * (A2 + w * (A3 + w * (A4 + w * (A5 + w * (A6 + w * (A7 + w * A8))))))))
	}
	if steep do p = 0.25 - p
	if x < 0 do p = 0.5 - p
	if y < 0 && p < 0.5 do p = 0 - p // a half turn stays 0.5: the range is (-0.5, 0.5]
	return p
}

// The angle of a vector in turns, (-0.5, 0.5]: atan2_turns(v.y, v.x). The inverse of angle_vec.
angle_of :: proc "contextless" (v: [2]f32) -> f32 {
	return atan2_turns(v.y, v.x)
}
