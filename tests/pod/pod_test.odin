package test_pod

import "core:testing"

import "unified:pod"

@(test)
accepts_plain_data :: proc(t: ^testing.T) {
	Plain :: struct {
		a: u32,
		b: [3]f32,
		c: [2]struct {
			x: i16,
			y: u8,
			z: bool,
		},
	}
	testing.expect_value(t, pod.violation(type_info_of(Plain)), "")
}

@(test)
rejects_pointers_and_padding :: proc(t: ^testing.T) {
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
	Tail_Padded :: struct {
		a: u32,
		b: u8,
	}
	testing.expect(t, pod.violation(type_info_of(With_Ptr)) != "")
	testing.expect(t, pod.violation(type_info_of(With_Slice)) != "")
	testing.expect(t, pod.violation(type_info_of(Padded)) != "")
	testing.expect(t, pod.violation(type_info_of(Nested)) != "")
	testing.expect(t, pod.violation(type_info_of(Tail_Padded)) != "")
	testing.expect(t, pod.violation(type_info_of(string)) != "")
}
