package test_dmath

import "core:log"
import "core:testing"

import "unified:dmath"

// One Aim step in turns.
@(private = "file")
STEP :: f32(1) / 65536

@(private = "file")
bits3 :: proc(v: [3]f32) -> [3]u32 {
	return {transmute(u32)v.x, transmute(u32)v.y, transmute(u32)v.z}
}

@(private = "file")
near3 :: proc(a, b: [3]f32, eps: f32) -> bool {
	return dmath.length(a - b) < eps
}

// The aim's bits over a sweep, hashed, are pinned: every platform must decode (and, for scripts, encode) these exact
// values. Every yaw with a pitch that walks the i16 range, then every pitch (past the limit too) with a yaw.
AIM_HASH :: u64(0xf7db32805bf6c01d)

@(test)
aim_bits_are_pinned :: proc(t: ^testing.T) {
	hash := u64(0xCBF29CE484222325)
	mix :: proc(hash: ^u64, bits: u32) {
		hash^ = (hash^ ~ u64(bits)) * 0x100000001B3
	}
	for i in 0 ..< 2 * 65536 {
		look := dmath.Aim{u16(i), i16(u16(i * 7919))} if i < 65536 else dmath.Aim{u16(i * 40503), i16(u16(i))}
		dir := dmath.aim_vec(look)
		forward, right := dmath.aim_flat(look)
		quat, model := dmath.aim_quat(look), dmath.aim_quat_model(look)
		back := dmath.aim_toward(dir * 3)
		for f in ([?]f32{dir.x, dir.y, dir.z, forward.x, forward.z, right.x, right.z}) {
			mix(&hash, transmute(u32)f)
		}
		for f in ([?]f32{quat.x, quat.y, quat.z, quat.w, model.x, model.y, model.z, model.w}) {
			mix(&hash, transmute(u32)f)
		}
		mix(&hash, u32(back.yaw) | u32(u16(back.pitch)) << 16)
	}
	log.infof("%v: aim %016x", ODIN_ARCH, hash)
	testing.expectf(t, hash == AIM_HASH, "aim sweep hash %016x, pinned %016x", hash, AIM_HASH)
}

// Encoding and decoding: a round trip within half a step, the wrap, the clamp, and defined values for bad floats.
@(test)
aim_encoding :: proc(t: ^testing.T) {
	testing.expect_value(t, dmath.aim(0, 0), dmath.Aim{})
	testing.expect_value(t, dmath.aim(0.25, 0), dmath.Aim{16384, 0})
	testing.expect_value(t, dmath.aim(-0.25, 0), dmath.Aim{49152, 0})
	testing.expect_value(t, dmath.aim(3.5, 0), dmath.Aim{32768, 0})
	testing.expect_value(t, dmath.aim(1, 0), dmath.Aim{})
	testing.expect_value(t, dmath.aim(-1e-10, 0), dmath.Aim{}) // wraps up to a whole turn: 0
	testing.expect_value(t, dmath.aim(1 - STEP / 4, 0), dmath.Aim{}) // rounds up to a whole turn: 0
	testing.expect_value(t, dmath.aim(0, 0.125), dmath.Aim{0, 8192})
	testing.expect_value(t, dmath.aim(0, -0.125), dmath.Aim{0, -8192})
	// the clamp: in the encoding and in every decode
	testing.expect_value(t, dmath.aim(0, 0.25).pitch, 16128)
	testing.expect_value(t, dmath.aim(0, -3).pitch, -16128)
	testing.expect_value(t, dmath.aim_pitch(dmath.aim(0, 1)), dmath.AIM_PITCH_LIMIT)
	testing.expect_value(t, dmath.aim_pitch({0, max(i16)}), dmath.AIM_PITCH_LIMIT)
	testing.expect_value(t, dmath.aim_pitch({0, min(i16)}), -dmath.AIM_PITCH_LIMIT)
	testing.expect_value(t, dmath.aim_vec({0, max(i16)}), dmath.aim_vec({0, 16128}))
	// bad floats read as 0
	nan, inf := transmute(f32)u32(0x7FC0_0000), transmute(f32)u32(0x7F80_0000)
	for bad in ([]f32{nan, inf, -inf, 1e30}) {
		testing.expect_value(t, dmath.aim(bad, 0.1).yaw, 0)
	}
	testing.expect_value(t, dmath.aim(0.1, nan).pitch, 0)
	testing.expect_value(t, dmath.aim(0.1, inf).pitch, 16128)
	testing.expect_value(t, dmath.aim_toward({}), dmath.Aim{})
	testing.expect_value(t, dmath.aim_toward({nan, 0, 1}), dmath.Aim{})
	// the round trip, within half a step (the short way round for yaw)
	for i in 0 ..< 20000 {
		yaw := f32(i) * 0.000137 - 1.3
		pitch := f32(i % 997) / 997 * 0.6 - 0.3
		look := dmath.aim(yaw, pitch)
		yaw_error := abs(dmath.angle_diff(yaw, dmath.aim_yaw(look)))
		want_pitch := dmath.clamp(pitch, -dmath.AIM_PITCH_LIMIT, dmath.AIM_PITCH_LIMIT)
		testing.expectf(t, yaw_error <= STEP / 2, "aim(%v, _): yaw %v off by %v", yaw, dmath.aim_yaw(look), yaw_error)
		testing.expectf(
			t,
			abs(dmath.aim_pitch(look) - want_pitch) <= STEP / 2,
			"aim(_, %v): pitch %v",
			pitch,
			look.pitch,
		)
		testing.expect(t, dmath.aim_yaw(look) >= 0 && dmath.aim_yaw(look) < 1, "yaw in [0, 1)")
	}
}

// The directions: exact at the eighths, unit length for any bits, and aim_flat, aim_quat and aim_toward agreeing
// with aim_vec.
@(test)
aim_directions :: proc(t: ^testing.T) {
	// the eighths of yaw, level: exact, zeros +0, -Z at zero, -X at a quarter turn
	for k in 0 ..< 8 {
		c, s := dmath.DIR8[k].x, dmath.DIR8[k].y
		look := dmath.Aim{u16(k * 8192), 0}
		want := [3]f32{0 - s, 0, 0 - c}
		testing.expectf(
			t,
			bits3(dmath.aim_vec(look)) == bits3(want),
			"aim_vec yaw %v/8: %v, want %v",
			k,
			dmath.aim_vec(look),
			want,
		)
		forward, right := dmath.aim_flat(look)
		testing.expect(t, bits3(forward) == bits3(want), "aim_flat's forward is aim_vec, level")
		testing.expect(t, bits3(right) == bits3([3]f32{c, 0, 0 - s}), "aim_flat's right")
	}
	testing.expect_value(t, dmath.aim_vec({}), [3]f32{0, 0, -1})
	testing.expect_value(t, dmath.aim_vec({16384, 0}), [3]f32{-1, 0, 0})
	testing.expect_value(t, dmath.aim_vec({0, 8192}), [3]f32{0, 0.70710677, -0.70710677})
	_, right := dmath.aim_flat({})
	testing.expect_value(t, right, [3]f32{1, 0, 0})
	testing.expect_value(t, dmath.aim_quat({}), [4]f32{0, 0, 0, 1})
	testing.expect_value(t, dmath.aim_quat_model({}), dmath.quat_yaw({0, -1})) // a model at zero faces -Z
	// every yaw and every pitch decodes to a finite unit vector; the quaternion turns -Z onto it and +X onto right
	check :: proc(t: ^testing.T, look: dmath.Aim) -> bool {
		dir := dmath.aim_vec(look)
		forward, right := dmath.aim_flat(look)
		quat, model := dmath.aim_quat(look), dmath.aim_quat_model(look)
		ok :=
			dmath.dot(dir, dir) == dmath.dot(dir, dir) &&
			abs(dmath.length(dir) - 1) < 1e-6 &&
			abs(dmath.length(forward) - 1) < 1e-6
		ok &&= dot4(quat) == dot4(quat) // finite: no NaN
		ok &&= abs(dot4(quat) - 1) < 1e-6
		ok &&= near3(dmath.quat_rotate(quat, {0, 0, -1}), dir, 2e-6)
		ok &&= near3(dmath.quat_rotate(quat, {1, 0, 0}), right, 2e-6)
		// the model's: +Z onto the aim, -X (MODEL_RIGHT) onto right, and level, quat_yaw's rotation of the forward
		ok &&= abs(dot4(model) - 1) < 1e-6
		ok &&= near3(dmath.quat_rotate(model, {0, 0, 1}), dir, 2e-6)
		ok &&= near3(dmath.quat_rotate(model, {-1, 0, 0}), right, 2e-6)
		// (within quat_yaw's own error: its half angle comes from the cosine, so facing nearly -Z it turns a vector a few 1e-4 of its length off)
		yawed := dmath.quat_yaw(forward.xz)
		ok &&= near3(
			dmath.quat_rotate(dmath.aim_quat_model({look.yaw, 0}), {1, 2, 3}),
			dmath.quat_rotate(yawed, {1, 2, 3}),
			1e-3,
		)
		ok &&= dmath.dot(forward, right) == 0 && dmath.dot(forward, {dir.x, 0, dir.z}) >= 0
		// a script's aim_toward finds the same aim (within a step: atan2 is not exact everywhere)
		back := dmath.aim_toward(dir)
		ok &&= abs(i32(i16(back.yaw - look.yaw))) <= 1
		ok &&= abs(i32(back.pitch) - dmath.clamp(i32(look.pitch), -16128, 16128)) <= 1
		return ok
	}
	failures, first_failure := 0, dmath.Aim{}
	for i in 0 ..< 2 * 65536 {
		look := dmath.Aim{u16(i), i16(u16(i * 7919))} if i < 65536 else dmath.Aim{u16(i * 40503), i16(u16(i))}
		if check(t, look) do continue
		if failures == 0 do first_failure = look
		failures += 1
	}
	testing.expectf(
		t,
		failures == 0,
		"%v aims failed the unit-length or agreement checks, the first %v",
		failures,
		first_failure,
	)
}

@(private = "file")
dot4 :: proc(quat: [4]f32) -> f32 {
	return quat.x * quat.x + quat.y * quat.y + quat.z * quat.z + quat.w * quat.w
}
