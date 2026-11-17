// The LAN token claim (godot.token_claim): each copy of a game on one machine locks a slot of its own, a released
// slot's token is taken back by the next claimer, and with every slot held the token is fresh and kept nowhere.
package test_godot_driver

import "core:fmt"
import "core:os"
import "core:testing"

import "unified:godot"
import "unified:netcode"

@(test)
lan_token_claims_are_exclusive_and_kept :: proc(t: ^testing.T) {
	dir, temp_err := os.make_directory_temp("", "unified-token-*", context.temp_allocator)
	testing.expect(t, temp_err == nil)
	defer os.remove_all(dir)

	first, first_lock, first_slot := godot.token_claim(dir)
	second, second_lock, second_slot := godot.token_claim(dir)
	testing.expect_value(t, first_slot, 0)
	testing.expect_value(t, second_slot, 1) // slot 0 is held: a second copy takes another token
	testing.expect(t, first != second)
	testing.expect(t, first != {})
	kept, _ := os.read_entire_file(fmt.tprintf("%s/unified_token_0", dir), context.temp_allocator)
	testing.expect_value(t, string(kept), netcode.token_text(first)) // 32 hex digits

	godot.token_release(first_lock)
	again, again_lock, again_slot := godot.token_claim(dir)
	testing.expect_value(t, again_slot, 0) // a restarted copy takes its token back
	testing.expect_value(t, again, first)

	locks: [dynamic]godot.Token_Lock
	defer delete(locks)
	for _ in 2 ..< godot.TOKEN_INSTANCES {
		_, lock, slot := godot.token_claim(dir)
		testing.expect(t, slot >= 2)
		append(&locks, lock)
	}
	none, none_lock, none_slot := godot.token_claim(dir)
	testing.expect_value(t, none_slot, -1) // every slot held
	testing.expect_value(t, none_lock, 0)
	testing.expect(t, none != {} && none != first && none != second)

	godot.token_release(again_lock)
	godot.token_release(second_lock)
	for lock in locks do godot.token_release(lock)
}
