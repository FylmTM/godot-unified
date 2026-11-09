package test_dmath

import "core:testing"

import "unified:dmath"

@(test)
helpers :: proc(t: ^testing.T) {
	testing.expect_value(t, dmath.length2({3, 4}), 5)
	testing.expect_value(t, dmath.normalize2({0, 0}), dmath.Vec2{})
	testing.expect_value(t, dmath.normalize3({0, 0, 2}), dmath.Vec3{0, 0, 1})
	testing.expect_value(t, dmath.clamp_length2({6, 8}, 5), dmath.Vec2{3, 4})
	testing.expect_value(t, dmath.clamp_length2({0.6, 0.8}, 5), dmath.Vec2{0.6, 0.8})
	testing.expect_value(t, dmath.dist_sq2({1, 1}, {4, 5}), 25)
	for k in 0 ..< 8 {
		l := dmath.length2({dmath.DIR8_C[k], dmath.DIR8_S[k]})
		testing.expect(t, l > 0.99999 && l < 1.00001)
	}
}

@(test)
clamped_conversion :: proc(t: ^testing.T) {
	testing.expect_value(t, dmath.to_i32_clamped(3.9, 0, 29), 3)
	testing.expect_value(t, dmath.to_i32_clamped(-0.5, 0, 29), 0)
	testing.expect_value(t, dmath.to_i32_clamped(1e30, 0, 29), 29)
	testing.expect_value(t, dmath.to_i32_clamped(-1e30, -5, 29), -5)
	testing.expect_value(t, dmath.to_i32_clamped(transmute(f32)u32(0x7FC0_0000), 0, 29), 0) // NaN
	inf := transmute(f32)u32(0x7F80_0000)
	testing.expect_value(t, dmath.to_i32_clamped(inf, 0, 29), 29)
	testing.expect_value(t, dmath.to_i32_clamped(-2.5, -10, 10), -2) // truncation toward zero
}
