package core

import "core:testing"

import "../game"

@(test)
pod_accepts_state :: proc(t: ^testing.T) {
	testing.expect_value(t, pod_violation(type_info_of(game.State)), "")
	testing.expect_value(t, pod_violation(type_info_of(Log_Tick)), "")
}

@(test)
pod_rejects_pointers_and_padding :: proc(t: ^testing.T) {
	With_Ptr :: struct {
		a: i32,
		p: ^i32,
	}
	With_Slice :: struct {
		s: [4][]u8,
	}
	Padded :: struct {
		a: u8,
		b: u32,
	}
	Nested :: struct {
		x: [2]Padded,
	}
	testing.expect(t, pod_violation(type_info_of(With_Ptr)) != "")
	testing.expect(t, pod_violation(type_info_of(With_Slice)) != "")
	testing.expect(t, pod_violation(type_info_of(Padded)) != "")
	testing.expect(t, pod_violation(type_info_of(Nested)) != "")
	testing.expect(t, pod_violation(type_info_of(string)) != "")
}
