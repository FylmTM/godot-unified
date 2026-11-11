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
		c := eos.code_new()
		s := eos.code_string(&c)
		testing.expect_value(t, len(s), eos.CODE_LEN)
		for i in 0 ..< len(s) {
			testing.expectf(t, eos.code_char_ok(s[i]), "code %q has %q", s, s[i])
		}
		back, ok := eos.code_parse(s)
		testing.expect(t, ok && back == c)
		seen[s] = true
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
		for &b in buf {
			b = next
		}
		next += 1
	}
	counts: [len(eos.CODE_ALPHABET)]int
	alphabet := eos.CODE_ALPHABET
	for _ in 0 ..< 248 * 10 {
		c := eos.code_new(counter)
		for ch in c {
			for a, i in transmute([]u8)alphabet {
				if a == ch {
					counts[i] += 1
				}
			}
		}
	}
	for n in counts[1:] {
		testing.expect_value(t, n, counts[0])
	}
}

@(test)
code_parse_is_forgiving_but_strict :: proc(t: ^testing.T) {
	c, ok := eos.code_parse("ab3-x9k")
	testing.expect(t, ok)
	testing.expect_value(t, eos.code_string(&c), "AB3X9K")
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
	w := (^Wire)(user)
	testing_expect_size(len(pkt))
	b := make([]u8, len(pkt), context.temp_allocator)
	copy(b, pkt)
	append(&w.pkts, b)
}

testing_expect_size :: proc(n: int) {
	assert(n <= eos.P2P_MAX_PACKET)
}

@(test)
framing_round_trips_every_size :: proc(t: ^testing.T) {
	id: u16
	src: [BIG]u8
	for &b, i in src {
		b = u8(i * 7 + 3)
	}
	out: [BIG]u8
	r: eos.Reasm
	testing.expect(t, netcode.MAX_DATAGRAM + 1 <= eos.P2P_MAX_PACKET) // netcode datagrams go whole
	for size in 0 ..= BIG {
		w := Wire {
			pkts = make([dynamic][]u8, context.temp_allocator),
		}
		testing.expect(t, eos.frame_split(src[:size], &id, collect, &w))
		testing.expect_value(
			t,
			len(w.pkts),
			size + 1 <= eos.P2P_MAX_PACKET ? 1 : (size + eos.PART_MAX - 1) / eos.PART_MAX,
		)
		got := -1
		for p, i in w.pkts {
			n, ok := eos.frame_join(&r, p, out[:])
			testing.expect_value(t, ok, i == len(w.pkts) - 1)
			if ok {
				got = n
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
	r: eos.Reasm
	w := Wire {
		pkts = make([dynamic][]u8, context.temp_allocator),
	}
	// Four large datagrams, each a different fill; deliver the parts shuffled, drop one part of
	// datagram 2: the other three arrive whole and intact.
	for k in 0 ..< 4 {
		for &b in src {
			b = u8(k + 1)
		}
		testing.expect(t, eos.frame_split(src[:], &id, collect, &w))
	}
	testing.expect_value(t, len(w.pkts), 8)
	order := []int{7, 0, 3, 5, 1, 6, 2} // part 4 (datagram 2, first half) lost
	got := 0
	for i in order {
		n, ok := eos.frame_join(&r, w.pkts[i], out[:])
		if ok {
			testing.expect_value(t, n, len(src))
			k := int(out[0])
			testing.expect(t, k != 3)
			for b in out[:n] {
				if b != u8(k) {
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
		n := rand.int_max(64)
		for &b in junk[:n] {
			b = u8(rand.uint32())
		}
		if n > 0 {
			junk[0] = u8(rand.int_max(3))
		}
		_, _ = eos.frame_join(&r, junk[:n], out[:])
	}
}

@(test)
credentials_come_from_the_environment :: proc(t: ^testing.T) {
	names := eos.CREDENTIAL_NAMES
	values := [5]string{"p1", "s2", "d3", "c4", "x5"}
	saved: [5]string
	for n, i in names {
		saved[i] = os.get_env(n, context.temp_allocator)
		os.set_env(n, values[i])
	}
	defer for n, i in names {
		if saved[i] != "" do os.set_env(n, saved[i])
		else do os.unset_env(n)
	}
	c, source := eos.credentials_load(context.temp_allocator)
	testing.expect(t, eos.credentials_complete(c))
	testing.expect_value(t, source, "environment")
	testing.expect_value(t, c.product_id, "p1")
	testing.expect_value(t, c.sandbox_id, "s2")
	testing.expect_value(t, c.deployment_id, "d3")
	testing.expect_value(t, c.client_id, "c4")
	testing.expect_value(t, c.client_secret, "x5")
}

@(test)
framing_refuses_what_the_receiver_cannot_reassemble :: proc(t: ^testing.T) {
	id: u16
	src: [eos.MAX_PARTS * eos.PART_MAX + 1]u8
	w := Wire {
		pkts = make([dynamic][]u8, context.temp_allocator),
	}
	testing.expect(t, eos.frame_split(src[:eos.MAX_PARTS * eos.PART_MAX], &id, collect, &w))
	testing.expect_value(t, len(w.pkts), eos.MAX_PARTS)
	clear(&w.pkts)
	testing.expect(t, !eos.frame_split(src[:], &id, collect, &w), "one part too many must be refused")
	testing.expect_value(t, len(w.pkts), 0)
}
