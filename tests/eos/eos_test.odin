// The network-free parts of unified:eos: lobby codes, datagram framing, credentials loading. The
// SDK bindings' struct layouts are checked against the headers in layout_test.odin.
package test_eos

import "core:math/rand"
import "core:os"
import "core:testing"

import "unified:eos"
import "unified:netcode"

@(test)
codes_use_the_alphabet_and_parse_back :: proc(t: ^testing.T) {
	seen := make(map[string]bool, context.temp_allocator)
	for _ in 0 ..< 2000 {
		code := eos.code_new()
		text := eos.code_string(&code)
		testing.expect_value(t, len(text), eos.CODE_LEN)
		for i in 0 ..< len(text) {
			testing.expectf(t, eos.code_char_ok(text[i]), "code %q has %q", text, text[i])
		}
		back, ok := eos.code_parse(text)
		testing.expect(t, ok && back == code)
		seen[text] = true
	}
	// 2000 draws from 31^6 codes: a collision would mean the generator is broken.
	testing.expect_value(t, len(seen), 2000)
}

@(test)
codes_are_unbiased :: proc(t: ^testing.T) {
	// A generator whose n-th call fills the buffer with byte n % 256: 248 calls in a row produce
	// every accepted byte value once. Rejection must keep each symbol equally likely (256 % 31 !=
	// 0, so plain `% 31` would favour the first 8 symbols).
	counter :: proc(buf: []u8) {
		@(static) next: u8
		for &value in buf {
			value = next
		}
		next += 1
	}
	counts: [len(eos.CODE_ALPHABET)]int
	alphabet := eos.CODE_ALPHABET
	for _ in 0 ..< 248 * 10 {
		code := eos.code_new(counter)
		for char in code {
			for letter, i in transmute([]u8)alphabet {
				if letter == char {
					counts[i] += 1
				}
			}
		}
	}
	for symbol_count in counts[1:] {
		testing.expect_value(t, symbol_count, counts[0])
	}
}

@(test)
code_parse_is_forgiving_but_strict :: proc(t: ^testing.T) {
	code, ok := eos.code_parse("ab3-x9k")
	testing.expect(t, ok)
	testing.expect_value(t, eos.code_string(&code), "AB3X9K")
	_, ok = eos.code_parse(" AB3 X9K ")
	testing.expect(t, ok)
	for bad in ([]string{"", "AB3X9", "AB3X9KK", "AB0X9K", "ABOX9K", "AB1X9K", "ABIX9K", "ABLX9K", "AB3X9!"}) {
		_, ok = eos.code_parse(bad)
		testing.expectf(t, !ok, "%q parsed", bad)
	}
}

BIG :: eos.MAX_PARTS * eos.PART_MAX

Wire :: struct {
	pkts: [dynamic][]u8,
}

collect :: proc(user: rawptr, pkt: []u8) {
	wire := (^Wire)(user)
	testing_expect_size(len(pkt))
	packet := make([]u8, len(pkt), context.temp_allocator)
	copy(packet, pkt)
	append(&wire.pkts, packet)
}

testing_expect_size :: proc(size: int) {
	assert(size <= eos.P2P_MAX_PACKET)
}

@(test)
framing_round_trips_every_size :: proc(t: ^testing.T) {
	id: u16
	src: [BIG]u8
	for &value, i in src {
		value = u8(i * 7 + 3)
	}
	out: [BIG]u8
	reasm: eos.Reasm
	testing.expect(t, netcode.MAX_DATAGRAM + 1 <= eos.P2P_MAX_PACKET) // netcode datagrams go whole
	for size in 0 ..= BIG {
		wire := Wire {
			pkts = make([dynamic][]u8, context.temp_allocator),
		}
		testing.expect(t, eos.frame_split(src[:size], &id, collect, &wire))
		testing.expect_value(
			t,
			len(wire.pkts),
			size + 1 <= eos.P2P_MAX_PACKET ? 1 : (size + eos.PART_MAX - 1) / eos.PART_MAX,
		)
		got := -1
		for packet, i in wire.pkts {
			length, ok := eos.frame_join(&reasm, packet, out[:])
			testing.expect_value(t, ok, i == len(wire.pkts) - 1)
			if ok {
				got = length
			}
		}
		if !testing.expect_value(t, got, size) {
			return
		}
		testing.expect(t, string(out[:size]) == string(src[:size]))
	}
}

@(test)
framing_survives_reorder_and_loss :: proc(t: ^testing.T) {
	id: u16
	src: [2000]u8
	out: [BIG]u8
	reasm: eos.Reasm
	wire := Wire {
		pkts = make([dynamic][]u8, context.temp_allocator),
	}
	// Four large datagrams, each a different fill; deliver the parts shuffled, drop one part of
	// datagram 2: the other three arrive whole and intact.
	for k in 0 ..< 4 {
		for &value in src {
			value = u8(k + 1)
		}
		testing.expect(t, eos.frame_split(src[:], &id, collect, &wire))
	}
	testing.expect_value(t, len(wire.pkts), 8)
	order := []int{7, 0, 3, 5, 1, 6, 2} // part 4 (datagram 2, first half) lost
	got := 0
	for i in order {
		length, ok := eos.frame_join(&reasm, wire.pkts[i], out[:])
		if ok {
			testing.expect_value(t, length, len(src))
			fill := int(out[0])
			testing.expect(t, fill != 3)
			for value in out[:length] {
				if value != u8(fill) {
					testing.expect(t, false, "mixed-up datagram")
					break
				}
			}
			got += 1
		}
	}
	testing.expect_value(t, got, 3)
	// Garbage is dropped, not crashed on.
	junk := make([]u8, 64, context.temp_allocator)
	for _ in 0 ..< 1000 {
		length := rand.int_max(64)
		for &value in junk[:length] {
			value = u8(rand.uint32())
		}
		if length > 0 {
			junk[0] = u8(rand.int_max(3))
		}
		_, _ = eos.frame_join(&reasm, junk[:length], out[:])
	}
}

@(test)
credentials_come_from_the_environment :: proc(t: ^testing.T) {
	names := eos.CREDENTIAL_NAMES
	values := [5]string{"p1", "s2", "d3", "c4", "x5"}
	saved: [5]string
	for name, i in names {
		saved[i] = os.get_env(name, context.temp_allocator)
		os.set_env(name, values[i])
	}
	defer for name, i in names {
		if saved[i] != "" do os.set_env(name, saved[i])
		else do os.unset_env(name)
	}
	credentials, source := eos.credentials_load(context.temp_allocator)
	testing.expect(t, eos.credentials_complete(credentials))
	testing.expect_value(t, source, "environment")
	testing.expect_value(t, credentials.product_id, "p1")
	testing.expect_value(t, credentials.sandbox_id, "s2")
	testing.expect_value(t, credentials.deployment_id, "d3")
	testing.expect_value(t, credentials.client_id, "c4")
	testing.expect_value(t, credentials.client_secret, "x5")
}

@(test)
framing_refuses_what_the_receiver_cannot_reassemble :: proc(t: ^testing.T) {
	id: u16
	src: [eos.MAX_PARTS * eos.PART_MAX + 1]u8
	wire := Wire {
		pkts = make([dynamic][]u8, context.temp_allocator),
	}
	testing.expect(t, eos.frame_split(src[:eos.MAX_PARTS * eos.PART_MAX], &id, collect, &wire))
	testing.expect_value(t, len(wire.pkts), eos.MAX_PARTS)
	clear(&wire.pkts)
	testing.expect(t, !eos.frame_split(src[:], &id, collect, &wire), "one part too many must be refused")
	testing.expect_value(t, len(wire.pkts), 0)
}
