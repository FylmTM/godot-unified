// The network-free parts of unified:eos: lobby codes, credentials loading. The
// SDK bindings' struct layouts are checked against the headers in layout_test.odin.
package test_eos

import "core:os"
import "core:strings"
import "core:testing"

import "unified:eos"
import "unified:sim"

// The seeded byte source of codes_use_the_alphabet_and_parse_back (sim's SplitMix64 stream: fixed, so the run
// is the same every time).
seeded_rng: sim.Rng

@(test)
codes_use_the_alphabet_and_parse_back :: proc(t: ^testing.T) {
	seeded :: proc(buf: []u8) {
		for &value in buf {
			value = u8(sim.rng_next(&seeded_rng))
		}
	}
	seeded_rng = sim.rng_seed(1)
	seen := make(map[string]bool, context.temp_allocator)
	for i in 0 ..= 2000 {
		// the first from the default (crypto) source, the rest seeded
		code := i == 0 ? eos.code_new() : eos.code_new(seeded)
		text := string(code[:])
		testing.expect_value(t, len(text), eos.CODE_LEN)
		for j in 0 ..< len(text) {
			testing.expectf(t, strings.index_byte(eos.CODE_ALPHABET, text[j]) >= 0, "code %q has %q", text, text[j])
		}
		back, ok := eos.code_parse(text)
		testing.expect(t, ok && back == code)
		if i > 0 {
			seen[strings.clone(text, context.temp_allocator)] = true
		}
	}
	// 2000 seeded draws from 31^6 codes, all distinct. Not a property of a random source: a correct one collides
	// in about 0.2% of runs (the birthday bound, 2000^2 / (2 * 31^6)); a fixed stream either collides or never.
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
	testing.expect_value(t, string(code[:]), "AB3X9K")
	_, ok = eos.code_parse(" AB3 X9K ")
	testing.expect(t, ok)
	for bad in ([]string{"", "AB3X9", "AB3X9KK", "AB0X9K", "ABOX9K", "AB1X9K", "ABIX9K", "ABLX9K", "AB3X9!"}) {
		_, ok = eos.code_parse(bad)
		testing.expectf(t, !ok, "%q parsed", bad)
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
	credentials := eos.credentials_load(context.temp_allocator)
	testing.expect(t, eos.credentials_complete(credentials))
	testing.expect_value(t, credentials.product_id, "p1")
	testing.expect_value(t, credentials.sandbox_id, "s2")
	testing.expect_value(t, credentials.deployment_id, "d3")
	testing.expect_value(t, credentials.client_id, "c4")
	testing.expect_value(t, credentials.client_secret, "x5")
}
