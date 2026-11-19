// Inline fixed-capacity collections for the block (src/sim/README.md, Collections): List, Queue and Bits, plain data
// with no padding for any element type of alignment at most 8 and any capacity, each zeroing what it vacates so equal contents hash equal. Their
// verbs are Odin's own for dynamic arrays and bit_sets; inside package sim the builtins are `builtin.append` and
// `builtin.clear`.
package sim

import "base:intrinsics"

// Up to N items in order, inline: a small bag kept in the block or the World (a level's pillars, a hand of cards, a
// wave's spawns). Indices are not stable (unordered_remove moves the last item in): anything a handle names across
// ticks is a Table. The zero value is empty. The count is as wide as the element's alignment, so a 1-byte element
// allows up to 255 items and a 2-byte one up to 65535; an element aligned past 8 bytes (u128, a #align(16) struct)
// would leave padding before the items, so it does not compile.
List :: struct(
	$T: typeid,
	$N: int,
) where N > 0 &&
	N <= 1 << 30 &&
	align_of(T) <= 8 &&
	(align_of(T) > 1 || N <= 255) &&
	(align_of(T) > 2 || N <= 65535) {
	count: (u8 when align_of(T) == 1 else u16 when align_of(T) == 2 else u32 when align_of(T) == 4 else u64),
	items: [N]T,
}

// Up to N items, first in, first out, inline: an input buffer, a wave queue. `head` is the oldest item's index;
// emptying the queue returns it to 0, so an empty queue is the zero value. Widths as List's.
Queue :: struct(
	$T: typeid,
	$N: int,
) where N > 0 &&
	N <= 1 << 30 &&
	align_of(T) <= 8 &&
	(align_of(T) > 1 || N <= 255) &&
	(align_of(T) > 2 || N <= 65535) {
	head:  (u8 when align_of(T) == 1 else u16 when align_of(T) == 2 else u32 when align_of(T) == 4 else u64),
	count: (u8 when align_of(T) == 1 else u16 when align_of(T) == 2 else u32 when align_of(T) == 4 else u64),
	items: [N]T,
}

// A set of the indices 0 ..< N, inline: which checkpoints were touched, which doors are open (an enum's set is
// Odin's bit_set). The zero value is empty.
Bits :: struct($N: int) where N > 0 && N <= 1 << 30 {
	words: [(N + 63) / 64]u64,
}

// Adds `item` at the end of a list or a queue; false (and nothing changes) when it is full.
append :: proc {
	list_append,
	queue_append,
}

// Removes and returns a list's last item, zeroing its slot; ok is false when it is empty.
pop :: proc {
	list_pop,
}

// Removes and returns a queue's oldest item, zeroing its slot; ok is false when it is empty.
pop_front :: proc {
	queue_pop_front,
}

// Empties a list, a queue or a bit set, zeroing every item.
clear :: proc {
	list_clear,
	queue_clear,
	bits_clear,
}

// A list's live items, items[:count], to walk or index: `for &pillar in sim.slice(&t.world.pillars)`.
slice :: #force_inline proc(list: ^List($T, $N)) -> []T {
	return list.items[:list.count]
}

// append's list form.
list_append :: proc(list: ^List($T, $N), item: T) -> bool {
	if int(list.count) >= N do return false
	list.items[list.count] = item
	list.count += 1
	return true
}

// pop's list form.
list_pop :: proc(list: ^List($T, $N)) -> (item: T, ok: bool) {
	if list.count == 0 do return
	list.count -= 1
	item = list.items[list.count]
	list.items[list.count] = {}
	return item, true
}

// Removes the item at `index`, moving the ones after it down a place (the order is kept), and zeroes the slot left
// at the end. index < count.
ordered_remove :: proc(list: ^List($T, $N), index: int) {
	count := int(list.count)
	assert(index >= 0 && index < count, "sim.ordered_remove: index out of range")
	copy(list.items[index:count - 1], list.items[index + 1:count])
	list.items[count - 1] = {}
	list.count -= 1
}

// Removes the item at `index` by moving the last item into it (the order changes; O(1)), and zeroes the last slot.
// index < count.
unordered_remove :: proc(list: ^List($T, $N), index: int) {
	count := int(list.count)
	assert(index >= 0 && index < count, "sim.unordered_remove: index out of range")
	list.items[index] = list.items[count - 1]
	list.items[count - 1] = {}
	list.count -= 1
}

// clear's list form.
list_clear :: proc(list: ^List($T, $N)) {
	// The live items only: the rest is zero already (every remove zeroes what it vacates).
	if list.count > 0 do intrinsics.mem_zero(&list.items[0], int(list.count) * size_of(T))
	list.count = 0
}

// append's queue form: the item becomes the newest.
queue_append :: proc(queue: ^Queue($T, $N), item: T) -> bool {
	if int(queue.count) >= N do return false
	queue.items[(int(queue.head) + int(queue.count)) % N] = item
	queue.count += 1
	return true
}

// pop_front's queue form.
queue_pop_front :: proc(queue: ^Queue($T, $N)) -> (item: T, ok: bool) {
	if queue.count == 0 do return
	item = queue.items[queue.head]
	queue.items[queue.head] = {}
	queue.count -= 1
	queue.head = 0 if queue.count == 0 else auto_cast ((int(queue.head) + 1) % N)
	return item, true
}

// clear's queue form.
queue_clear :: proc(queue: ^Queue($T, $N)) {
	// The live run only, in its one or two pieces: the rest is zero already.
	head, count := int(queue.head), int(queue.count)
	first := N - head
	if count < first do first = count
	if first > 0 do intrinsics.mem_zero(&queue.items[head], first * size_of(T))
	if count > first do intrinsics.mem_zero(&queue.items[0], (count - first) * size_of(T))
	queue.head, queue.count = 0, 0
}

// The queue's k-th oldest item (0: the next pop_front's), or nil past its count.
queue_at :: proc(queue: ^Queue($T, $N), k: int) -> ^T {
	if k < 0 || k >= int(queue.count) do return nil
	return &queue.items[(int(queue.head) + k) % N]
}

// Adds an index to a bit set. 0 <= index < N.
incl :: proc(bits: ^Bits($N), index: int) {
	assert(index >= 0 && index < N, "sim.incl: index out of range")
	bits.words[index >> 6] |= 1 << uint(index & 63)
}

// Removes an index from a bit set. 0 <= index < N.
excl :: proc(bits: ^Bits($N), index: int) {
	assert(index >= 0 && index < N, "sim.excl: index out of range")
	bits.words[index >> 6] &~= 1 << uint(index & 63)
}

// Whether a bit set holds an index (false outside 0 ..< N).
has :: proc(bits: ^Bits($N), index: int) -> bool {
	if index < 0 || index >= N do return false
	return bits.words[index >> 6] & (1 << uint(index & 63)) != 0
}

// How many indices a bit set holds.
card :: proc(bits: ^Bits($N)) -> int {
	total := 0
	for word in bits.words do total += int(intrinsics.count_ones(word))
	return total
}

// clear's bit set form.
bits_clear :: proc(bits: ^Bits($N)) {
	bits^ = {}
}

// A walk over a bit set's indices, lowest first (iterate, then next): `for index in sim.next(&open)`. Changing the
// set during the walk is safe; the walk sees each word as it reaches it.
Bits_Iterator :: struct($N: int) {
	bits:  ^Bits(N),
	index: int, // the next index to look at
}

// Starts a walk over a bit set's indices; `next` yields each one.
iterate_bits :: #force_inline proc(bits: ^Bits($N)) -> Bits_Iterator(N) {
	return {bits = bits}
}

// The next index of a bit-set walk, lowest first; ok is false past the last.
bits_next :: proc(iterator: ^Bits_Iterator($N)) -> (index: int, ok: bool) {
	for iterator.index < N {
		word := iterator.bits.words[iterator.index >> 6] >> uint(iterator.index & 63)
		if word == 0 {
			iterator.index = (iterator.index | 63) + 1
			continue
		}
		index = iterator.index + int(intrinsics.count_trailing_zeros(word))
		iterator.index = index + 1
		return index, index < N
	}
	return
}
