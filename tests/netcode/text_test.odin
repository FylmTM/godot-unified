// Player names as text (src/netcode/proto.odin, Text): cut on a character boundary when packed, and made valid UTF-8
// when read from another machine, while a Profile's bytes cross as they are.
package test_netcode

import "core:testing"
import "core:unicode/utf8"

import "unified:netcode"

// 16 Cyrillic letters are 32 bytes: a name keeps the 15 that fit in NAME_MAX (31), never half of the 16th.
@(test)
a_name_is_cut_on_a_character_boundary :: proc(t: ^testing.T) {
	long := "ДмитрийДмитрийДм"
	name := netcode.text_of(netcode.NAME_MAX, long)
	text := netcode.text_string(&name)
	testing.expect_value(t, text, long[:30])
	testing.expect(t, utf8.valid_string(text))
	short := netcode.text_of(netcode.NAME_MAX, "Ann")
	testing.expect_value(t, netcode.text_string(&short), "Ann")
}

// A peer may send any bytes as its name: the relay reads each byte no character starts with, or an unfinished
// character, as '?', so every client's roster holds valid text. (A Profile's bytes cross as they are: the Profile tests
// send binary ones.)
@(test)
a_name_from_another_machine_is_valid_text :: proc(t: ^testing.T) {
	session: Net
	net_make(&session, 0, 0)
	defer net_destroy(&session)
	bad := []u8{'A', 0xFF, 'n', 0xD0} // a stray byte, then half a two-byte character at the end
	joiner := net_join(&session, name = string(bad))
	net_run(&session, 3)
	testing.expect_value(t, joiner.status, netcode.Status.Connected)
	for client in ([]^Client{session.host.client, joiner}) {
		entry := netcode.client_member(client, joiner.member)
		if !testing.expect(t, entry != nil) do continue
		testing.expect_value(t, netcode.text_string(&entry.name), "A?n?")
	}
}
