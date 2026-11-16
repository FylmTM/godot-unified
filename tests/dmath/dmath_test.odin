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
	ARRAY :: "%s = %v, want 0 (unfused): the compiler fused a multiply and an add (FMA contraction) in array arithmetic, which breaks the determinism rule"
	testing.expectf(t, vgot == {}, ARRAY, "Vec3 a*b + c", vgot)
	// The other widths tick code uses, and the shape games write most: vector + vector * scalar.
	a2, b2, c2: [2]f32 = A, A, C
	got2 := mul_add2(intrinsics.volatile_load(&a2), intrinsics.volatile_load(&b2), intrinsics.volatile_load(&c2))
	testing.expectf(t, got2 == {}, ARRAY, "[2]f32 a*b + c", got2)
	a4, b4, c4: [4]f32 = A, A, C
	got4 := mul_add4(intrinsics.volatile_load(&a4), intrinsics.volatile_load(&b4), intrinsics.volatile_load(&c4))
	testing.expectf(t, got4 == {}, ARRAY, "[4]f32 a*b + c", got4)
	scaled := add_scaled3(intrinsics.volatile_load(&vc), intrinsics.volatile_load(&va), intrinsics.volatile_load(&b))
	testing.expectf(t, scaled == {}, ARRAY, "Vec3 c + a*s", scaled)
}

mul_add2 :: proc "contextless" (a, b, c: [2]f32) -> [2]f32 {
	return a * b + c
}

mul_add4 :: proc "contextless" (a, b, c: [4]f32) -> [4]f32 {
	return a * b + c
}

add_scaled3 :: proc "contextless" (c, a: dmath.Vec3, scale: f32) -> dmath.Vec3 {
	return c + a * scale
}

mul_add :: proc "contextless" (a, b, c: f32) -> f32 {
	return a * b + c
}

mul_add3 :: proc "contextless" (a, b, c: dmath.Vec3) -> dmath.Vec3 {
	return a * b + c
}

// Input encodings (src/dmath/input.odin): axes clamp, a stick is at most 1 long, directions round-trip within a
// hundredth of a degree, zero is "none", and any bits decode to a unit vector or none.
@(test)
input_encodings :: proc(t: ^testing.T) {
	testing.expect_value(t, dmath.axis(127), 1)
	testing.expect_value(t, dmath.axis(-128), -1)
	testing.expect_value(t, dmath.axis_i8(1), 127)
	testing.expect_value(t, dmath.axis_i8(-2), -127)
	testing.expect_value(t, dmath.axis_i8(0.5), 64)
	testing.expect(t, dmath.length2(dmath.stick(127, 127)) <= 1)
	testing.expect_value(t, dmath.stick(127, 0), dmath.Vec2{1, 0})
	testing.expect_value(t, dmath.dir2({}), 0)
	testing.expect_value(t, dmath.dir2_vec(0), dmath.Vec2{})
	testing.expect_value(t, dmath.dir3({}), dmath.Dir3{})
	testing.expect_value(t, dmath.dir3_vec({}), dmath.Vec3{})
	MAX_ERROR :: 0.0002 // radians: ~0.01°
	for i in 0 ..< 720 {
		// directions on a spiral over the sphere (sqrt-only construction: no trig in tests either)
		u := f32(i) / 720 * 2 - 1
		ring := dmath.sqrt(1 - u * u)
		k := f32(i % 37) / 37 * 2 - 1
		w := dmath.sqrt(max(1 - k * k, 0))
		want3 := dmath.normalize3({ring * k, u, ring * w * (1 if i % 2 == 0 else -1)})
		got3 := dmath.dir3_vec(dmath.dir3(want3))
		testing.expectf(t, dmath.length3(got3 - want3) < MAX_ERROR, "dir3 %v -> %v", want3, got3)
		want2 := dmath.normalize2({k, w * (1 if i % 3 == 0 else -1)})
		got2 := dmath.dir2_vec(dmath.dir2(want2))
		testing.expectf(t, dmath.length2(got2 - want2) < MAX_ERROR, "dir2 %v -> %v", want2, got2)
	}
	// the axes (the diamond's corners)
	testing.expect(t, dmath.length2(dmath.dir2_vec(dmath.dir2({1, 0})) - {1, 0}) < MAX_ERROR)
	testing.expect(t, dmath.length2(dmath.dir2_vec(dmath.dir2({0, -3})) - {0, -1}) < MAX_ERROR)
	testing.expect(t, dmath.length2(dmath.dir2_vec(dmath.dir2({-1, 0})) - {-1, 0}) < MAX_ERROR)
	testing.expect(t, dmath.length3(dmath.dir3_vec(dmath.dir3({0, 0, -2})) - {0, 0, -1}) < MAX_ERROR)
	testing.expect(t, dmath.length3(dmath.dir3_vec(dmath.dir3({0, 1, 0})) - {0, 1, 0}) < MAX_ERROR)
	// any bits: a unit vector
	for raw in ([]u16{1, 2, 32767, 32768, 40000, 65535}) {
		testing.expect(t, abs(dmath.length2(dmath.dir2_vec(dmath.Dir2(raw))) - 1) < 0.00001)
		testing.expect(t, abs(dmath.length3(dmath.dir3_vec({raw, 65535 - raw})) - 1) < 0.00001)
	}
}
