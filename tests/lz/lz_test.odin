// unified:lz black-box: round trips over a real snapshot and random, structured and adversarial inputs; malformed
// streams refused without a read or write outside the buffers (the tests build with bounds checks, so a stray index
// panics, and decode writes into the middle of a guarded buffer); fixed vectors pin the encoded bytes, so a platform
// or compiler that encodes differently fails here.
package test_lz

import "core:fmt"
import "core:hash/xxhash"
import "core:testing"

import "../toy"
import "unified:headless"
import "unified:lz"

// A fixed integer generator (xorshift64*): the same bytes on every platform and Odin version.
Rng :: struct {
	state: u64,
}

next :: proc(rng: ^Rng) -> u64 {
	rng.state ~= rng.state >> 12
	rng.state ~= rng.state << 25
	rng.state ~= rng.state >> 27
	return rng.state * 0x2545F4914F6CDD1D
}

random_bytes :: proc(count: int, seed: u64) -> []u8 {
	rng := Rng{seed | 1}
	bytes := make([]u8, count, context.temp_allocator)
	for &value in bytes do value = u8(next(&rng) >> 56)
	return bytes
}

// Plain-data records the way a state block holds them: mostly zeros, small integers and f32s, some of it changing.
structured_bytes :: proc(count: int, seed: u64) -> []u8 {
	rng := Rng{seed | 1}
	bytes := make([]u8, count, context.temp_allocator)
	for i := 0; i + 32 <= count; i += 32 {
		if next(&rng) % 3 == 0 do continue // an empty record
		value := f32(next(&rng) % 1000) * 0.25
		position := transmute([4]u8)value
		copy(bytes[i:], position[:])
		bytes[i + 8] = u8(i / 32)
		bytes[i + 12] = 1
		if next(&rng) % 5 == 0 do bytes[i + 20] = u8(next(&rng))
	}
	return bytes
}

// Encodes and decodes `src`, decoding into the middle of a guarded buffer: the bytes must come back and the guards
// stay untouched.
round_trip :: proc(t: ^testing.T, src: []u8, what: string, loc := #caller_location) -> (encoded_size: int) {
	out: [dynamic]u8
	defer delete(out)
	encoded := lz.encode(src, &out)
	testing.expectf(
		t,
		len(encoded) <= lz.bound(len(src)),
		"%s: %d bytes past the bound",
		what,
		len(encoded),
		loc = loc,
	)
	size, ok := lz.decoded_size(encoded)
	testing.expectf(
		t,
		ok && size == len(src),
		"%s: decoded size %d (ok %v), want %d",
		what,
		size,
		ok,
		len(src),
		loc = loc,
	)
	GUARD :: 64
	buffer := make([]u8, len(src) + 2 * GUARD)
	defer delete(buffer)
	for &value in buffer do value = 0xA5
	testing.expectf(t, lz.decode(encoded, buffer[GUARD:][:len(src)]), "%s: does not decode", what, loc = loc)
	testing.expectf(t, string(buffer[GUARD:][:len(src)]) == string(src), "%s: decodes to other bytes", what, loc = loc)
	for value in buffer[:GUARD] do testing.expectf(t, value == 0xA5, "%s: wrote before its output", what, loc = loc)
	for value in buffer[GUARD + len(src):] do testing.expectf(t, value == 0xA5, "%s: wrote past its output", what, loc = loc)
	return len(encoded)
}

@(test)
round_trips_small_and_edge_inputs :: proc(t: ^testing.T) {
	round_trip(t, nil, "empty")
	for length in 1 ..= 40 {
		round_trip(t, random_bytes(length, u64(length)), fmt.tprintf("%d random bytes", length))
		zeros := make([]u8, length, context.temp_allocator)
		round_trip(t, zeros, fmt.tprintf("%d zeros", length))
	}
	// Lengths around the nibble and the 255-byte steps, for literals and matches.
	for length in ([]int{14, 15, 16, 17, 18, 19, 20, 268, 269, 270, 273, 274, 275, 524, 529, 530, 531}) {
		round_trip(t, random_bytes(length, 7), fmt.tprintf("%d literals", length))
		run := make([]u8, length + 1, context.temp_allocator)
		for &value in run do value = 'x'
		round_trip(t, run, fmt.tprintf("a run of %d", length + 1))
	}
}

@(test)
round_trips_large_inputs :: proc(t: ^testing.T) {
	zeros := make([]u8, 1 << 20, context.temp_allocator)
	size := round_trip(t, zeros, "1 MiB of zeros")
	testing.expectf(t, size < (1 << 20) / 200, "1 MiB of zeros encodes to %d bytes", size)
	random := random_bytes(300_000, 99)
	size = round_trip(t, random, "random bytes")
	testing.expectf(t, size <= lz.bound(len(random)), "random: %d bytes", size)
	structured := structured_bytes(400_000, 5)
	size = round_trip(t, structured, "structured records")
	testing.expectf(
		t,
		size < len(structured) / 3,
		"structured records encode to %d of %d bytes",
		size,
		len(structured),
	)
}

// Repeats at and past the farthest offset, overlapping runs, and inputs whose matches start or end at the edges.
@(test)
round_trips_adversarial_inputs :: proc(t: ^testing.T) {
	block := random_bytes(1000, 3)
	for gap in ([]int{lz.MAX_OFFSET - 1000, lz.MAX_OFFSET - 999, lz.MAX_OFFSET - 998, lz.MAX_OFFSET, 70_000}) {
		src := make([]u8, 1000 + gap + 1000, context.temp_allocator)
		copy(src, block)
		filler := random_bytes(gap, u64(gap))
		copy(src[1000:], filler)
		copy(src[1000 + gap:], block)
		round_trip(t, src, fmt.tprintf("a repeat %d bytes later", 1000 + gap))
	}
	for period in 1 ..= 9 {
		src := make([]u8, 5000, context.temp_allocator)
		for &value, i in src do value = u8(i % period)
		round_trip(t, src, fmt.tprintf("period %d", period))
	}
	// A match up to the last byte, then one ending a byte short; alternating literals and short matches.
	tail := make([]u8, 200, context.temp_allocator)
	copy(tail, block[:100])
	copy(tail[100:], block[:100])
	round_trip(t, tail, "a match to the end")
	round_trip(t, tail[:199], "a match a byte short of the end")
	choppy := make([]u8, 20_000, context.temp_allocator)
	rng := Rng{11}
	for i := 0; i < len(choppy); i += 1 {
		choppy[i] = next(&rng) % 4 == 0 ? u8(next(&rng)) : (i >= 5 ? choppy[i - 5] : 0)
	}
	round_trip(t, choppy, "choppy")
}

// A real portable snapshot (the toy's, after a scripted run) comes back byte for byte, and compresses.
@(test)
round_trips_a_real_snapshot :: proc(t: ^testing.T) {
	snapshot, _ := headless.run_snapshot(&toy.GAME, 600, 21, 4)
	defer delete(snapshot)
	size := round_trip(t, snapshot, "the toy's snapshot")
	testing.expectf(t, size < len(snapshot) / 2, "the toy's snapshot: %d of %d bytes", size, len(snapshot))
}

// Encoding into a buffer that held a longer stream replaces it: the same bytes as into a fresh one.
@(test)
encoding_again_reuses_the_buffer :: proc(t: ^testing.T) {
	out: [dynamic]u8
	defer delete(out)
	_ = lz.encode(random_bytes(50_000, 1), &out)
	capacity := cap(out)
	src := structured_bytes(10_000, 2)
	again := lz.encode(src, &out)
	fresh: [dynamic]u8
	defer delete(fresh)
	testing.expect(t, string(again) == string(lz.encode(src, &fresh)))
	testing.expect_value(t, cap(out), capacity)
}

// The encoded bytes are pinned: another platform, compiler or a change to the encoder that moves them fails here (a
// format change bumps netcode.PROTOCOL_VERSION).
@(test)
encoded_bytes_are_pinned :: proc(t: ^testing.T) {
	out: [dynamic]u8
	defer delete(out)
	small := lz.encode(transmute([]u8)string("abcabcabcabc, zero zero zero zero zero zero: done"), &out)
	testing.expectf(t, hex(small) == SMALL_VECTOR, "small vector: %s", hex(small))
	mixed := make([dynamic]u8, context.temp_allocator)
	append(&mixed, ..structured_bytes(100_000, 42))
	append(&mixed, ..random_bytes(20_000, 43))
	append(&mixed, ..make([]u8, 70_000, context.temp_allocator))
	append(&mixed, ..structured_bytes(30_000, 42))
	encoded := lz.encode(mixed[:], &out)
	digest := xxhash.XXH3_64_default(encoded)
	testing.expectf(
		t,
		len(encoded) == MIXED_SIZE && digest == MIXED_DIGEST,
		"mixed vector: %d bytes, digest %x",
		len(encoded),
		digest,
	)
}

// "abc" and a match 3 back for 9 bytes; ", zero" and a match 5 back for 25 (a length byte); ": done" (the last).
SMALL_VECTOR :: "31000000" + "35" + "616263" + "0300" + "6f" + "2c207a65726f" + "0500" + "06" + "60" + "3a20646f6e65"
MIXED_SIZE :: 44756
MIXED_DIGEST :: u64(0x2674abcc8656e97e)

hex :: proc(bytes: []u8) -> string {
	digits := "0123456789abcdef"
	text := make([]u8, 2 * len(bytes), context.temp_allocator)
	for value, i in bytes {
		text[2 * i] = digits[value >> 4]
		text[2 * i + 1] = digits[value & 15]
	}
	return string(text)
}

// Every prefix of a valid stream, a stream with a byte appended and random byte changes are refused or decode to
// something, never a read or write outside the buffers.
@(test)
malformed_streams_are_refused :: proc(t: ^testing.T) {
	src := make([dynamic]u8, context.temp_allocator)
	append(&src, ..structured_bytes(3000, 8))
	append(&src, ..random_bytes(300, 9))
	append(&src, ..make([]u8, 600, context.temp_allocator))
	out: [dynamic]u8
	defer delete(out)
	encoded := lz.encode(src[:], &out)
	dst := make([]u8, len(src) + 64, context.temp_allocator)
	for cut in 0 ..< len(encoded) {
		if lz.decode(encoded[:cut], dst[:len(src)]) {
			testing.expectf(t, false, "a stream cut to %d of %d bytes decodes", cut, len(encoded))
			break
		}
	}
	longer := make([]u8, len(encoded) + 1, context.temp_allocator)
	copy(longer, encoded)
	testing.expect(t, !lz.decode(longer, dst[:len(src)]))
	testing.expect(t, !lz.decode(encoded, dst[:len(src) - 1])) // a buffer of another size
	testing.expect(t, !lz.decode(encoded, dst[:len(src) + 1]))
	rng := Rng{77}
	changed := make([]u8, len(encoded), context.temp_allocator)
	for _ in 0 ..< 20_000 {
		copy(changed, encoded)
		for _ in 0 ..< 1 + next(&rng) % 4 {
			changed[4 + int(next(&rng) % u64(len(changed) - 4))] = u8(next(&rng))
		}
		guarded_decode(t, changed)
	}
	for length in 0 ..< 2000 {
		garbage := random_bytes(length % 200, u64(length))
		guarded_decode(t, garbage)
	}
}

// Decodes `data` into the middle of a guarded buffer of its claimed size: whatever it returns, nothing outside the
// output changed.
guarded_decode :: proc(t: ^testing.T, data: []u8, loc := #caller_location) {
	size, ok := lz.decoded_size(data)
	if !ok do return
	GUARD :: 16
	buffer := make([]u8, size + 2 * GUARD, context.temp_allocator)
	for &value in buffer[:GUARD] do value = 0x5A
	for &value in buffer[GUARD + size:] do value = 0x5A
	_ = lz.decode(data, buffer[GUARD:][:size])
	for value in buffer[:GUARD] do testing.expect(t, value == 0x5A, "wrote before its output", loc = loc)
	for value in buffer[GUARD + size:] do testing.expect(t, value == 0x5A, "wrote past its output", loc = loc)
}

// Hand-made streams, each with one fault.
@(test)
crafted_faults_are_refused :: proc(t: ^testing.T) {
	dst: [64]u8
	Case :: struct {
		what:   string,
		stream: []u8,
		size:   int,
	}
	cases := []Case {
		{"no last sequence", {4, 0, 0, 0}, 4},
		{"a header only, short", {0, 0, 0}, 0},
		{"an offset of 0", {8, 0, 0, 0, 0x10, 'a', 0, 0, 0x00}, 8},
		{"an offset before the output", {8, 0, 0, 0, 0x10, 'a', 2, 0, 0x00}, 8},
		{"a match past the output", {4, 0, 0, 0, 0x10, 'a', 1, 0, 0x00}, 4},
		{"literals past the input", {3, 0, 0, 0, 0x30, 'a', 'b'}, 3},
		{"literals past the output", {2, 0, 0, 0, 0x30, 'a', 'b', 'c'}, 2},
		{"a last sequence naming a match", {1, 0, 0, 0, 0x11, 'a'}, 1},
		{"a length cut short", {20, 0, 0, 0, 0xF0, 255}, 20},
		{"an offset cut short", {8, 0, 0, 0, 0x10, 'a', 1}, 8},
		{"a sequence after the output is full", {1, 0, 0, 0, 0x10, 'a', 1, 0, 0x00}, 1},
	}
	for test_case in cases {
		size, ok := lz.decoded_size(test_case.stream)
		testing.expectf(
			t,
			!ok || !lz.decode(test_case.stream, dst[:test_case.size]),
			"%s: decodes (size %d, ok %v)",
			test_case.what,
			size,
			ok,
		)
	}
	// The one valid stream among them, so the faults above are the only reason they fail: 'a', then 7 of it again.
	testing.expect(t, lz.decode({8, 0, 0, 0, 0x13, 'a', 1, 0, 0x00}, dst[:8]))
	testing.expect(t, string(dst[:8]) == "aaaaaaaa")
	// A header claiming more than its bytes can stand for.
	_, claims_ok := lz.decoded_size({0, 0, 0, 1, 0x00})
	testing.expect(t, !claims_ok)
	_, most_ok := lz.decoded_size({255, 0, 0, 0, 0x00})
	testing.expect(t, most_ok)
	_, past_ok := lz.decoded_size({0, 1, 0, 0, 0x00})
	testing.expect(t, !past_ok)
}
