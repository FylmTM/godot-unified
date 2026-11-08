package test_game

import "core:testing"

import "unified:game"
import "unified:pod"

Small_Pool :: game.Pool(game.Gem, 4)

@(test)
state_is_plain_data :: proc(t: ^testing.T) {
	testing.expect_value(t, pod.violation(type_info_of(game.State)), "")
	testing.expect_value(t, pod.violation(type_info_of(game.Inputs)), "")
}

@(test)
zero_handle_is_null :: proc(t: ^testing.T) {
	p: Small_Pool
	game.pool_init(&p)
	idx := game.pool_alloc(&p)
	testing.expect_value(t, idx, 0)
	testing.expect_value(t, p.items[0].generation, 0) // slot 0, generation 0: what Handle{} used to match
	testing.expect(t, game.pool_get(&p, game.Handle{}) == nil)
	h := game.pool_handle(&p, idx)
	testing.expect(t, h != game.Handle{})
	testing.expect(t, game.pool_get(&p, h) == &p.items[0])
}

@(test)
stale_handles_are_rejected :: proc(t: ^testing.T) {
	p: Small_Pool
	game.pool_init(&p)
	a := game.pool_alloc(&p)
	b := game.pool_alloc(&p)
	ha := game.pool_handle(&p, a)
	hb := game.pool_handle(&p, b)
	game.pool_free(&p, a)
	testing.expect(t, game.pool_get(&p, ha) == nil) // freed
	testing.expect(t, game.pool_get(&p, hb) != nil)
	a2 := game.pool_alloc(&p) // LIFO reuse of slot a, next generation
	testing.expect_value(t, a2, a)
	testing.expect(t, game.pool_get(&p, ha) == nil) // reused: the old handle stays dead
	testing.expect(t, game.pool_get(&p, game.pool_handle(&p, a2)) == &p.items[a])
	testing.expect_value(t, p.count, 2)
}

@(test)
out_of_range_handle_is_null :: proc(t: ^testing.T) {
	p: Small_Pool
	game.pool_init(&p)
	_ = game.pool_alloc(&p)
	testing.expect(t, game.pool_get(&p, game.Handle{index1 = 5}) == nil) // N = 4
	testing.expect(t, game.pool_get(&p, game.Handle{index1 = 0xFFFF}) == nil)
}

@(test)
full_pool_returns_minus_one :: proc(t: ^testing.T) {
	p: Small_Pool
	game.pool_init(&p)
	for i in 0 ..< 4 {
		testing.expect_value(t, game.pool_alloc(&p), i32(i))
	}
	testing.expect_value(t, game.pool_alloc(&p), -1)
}
