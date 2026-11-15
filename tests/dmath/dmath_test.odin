package test_dmath

import "base:intrinsics"
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
	testing.expect_value(t, dmath.dot3({1, 2, 3}, {4, -5, 6}), 12)
	// quat_rotate: identity; half turns about each axis (exact); a quarter turn about +Z, +x to +y
	testing.expect_value(t, dmath.quat_rotate({0, 0, 0, 1}, {1, 2, 3}), dmath.Vec3{1, 2, 3})
	testing.expect_value(t, dmath.quat_rotate({1, 0, 0, 0}, {1, 2, 3}), dmath.Vec3{1, -2, -3})
	testing.expect_value(t, dmath.quat_rotate({0, 1, 0, 0}, {1, 2, 3}), dmath.Vec3{-1, 2, -3})
	testing.expect_value(t, dmath.quat_rotate({0, 0, 1, 0}, {1, 2, 3}), dmath.Vec3{-1, -2, 3})
	turned := dmath.quat_rotate({0, 0, 0.70710677, 0.70710677}, {1, 0, 0})
	testing.expect(t, abs(turned.x) < 1e-6 && abs(turned.y - 1) < 1e-6 && turned.z == 0)
	for k in 0 ..< 8 {
		length := dmath.length2({dmath.DIR8_C[k], dmath.DIR8_S[k]})
		testing.expect(t, length > 0.99999 && length < 1.00001)
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

// The no-FMA rule's canary: if the compiler starts fusing `a*b + c` into one fused multiply-add
// (one rounding instead of two), results change in the last bit and the cross-platform reference
// runs would only show an unexplained "trace differs at tick N". Here a*b = 1 + 2^-11 + 2^-24
// exactly: rounded to f32 it loses the 2^-24, so unfused a*b + c is 0 and fused it is 2^-24. The
// inputs go through volatile loads, so the optimizer can't fold them; the expression is compiled
// with the test build's flags (the CLI's TEST_FLAGS, src/cli/odin.odin).
@(test)
no_fma_contraction :: proc(t: ^testing.T) {
	A :: 1 + 1.0 / 4096
	C :: -(1 + 1.0 / 2048)
	FUSED :: 1.0 / 16777216
	a, b, c: f32 = A, A, C
	got := mul_add(intrinsics.volatile_load(&a), intrinsics.volatile_load(&b), intrinsics.volatile_load(&c))
	testing.expectf(
		t,
		got == 0,
		"a*b + c = %v, want 0 (unfused)%s: the compiler fused a multiply and an add (FMA contraction), which breaks the determinism rule; find the Odin/LLVM change or flag that enables contraction",
		got,
		got == FUSED ? " but got the fused result 2^-24" : "",
	)
	va, vb, vc: dmath.Vec3 = {A, A, A}, {A, A, A}, {C, C, C}
	vgot := mul_add3(intrinsics.volatile_load(&va), intrinsics.volatile_load(&vb), intrinsics.volatile_load(&vc))
	testing.expectf(
		t,
		vgot == {},
		"Vec3 a*b + c = %v, want 0 (unfused): the compiler fused a multiply and an add (FMA contraction) in array arithmetic, which breaks the determinism rule",
		vgot,
	)
}

mul_add :: proc "contextless" (a, b, c: f32) -> f32 {
	return a * b + c
}

mul_add3 :: proc "contextless" (a, b, c: dmath.Vec3) -> dmath.Vec3 {
	return a * b + c
}
