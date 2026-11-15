package view

import "core:sync"

// ---- triple buffer: one writer thread, one reader thread; the reader always gets the newest frame.

@(private)
FRESH :: u32(4)

Triple :: struct($T: typeid) {
	slots:  [3]T,
	latest: u32, // atomic: index of the newest published slot | FRESH while unread
	write:  u32, // writer-owned
	read:   u32, // reader-owned
}

// Gives the writer, the published frame and the reader one slot each. Call before either thread uses it.
triple_init :: proc(triple: ^Triple($T)) {
	triple.write, triple.latest, triple.read = 0, 1, 2
}

// The slot the writer fills next (its previous contents are a frame two publishes old).
triple_back :: proc(triple: ^Triple($T)) -> ^T {
	return &triple.slots[triple.write]
}

// Publishes the slot the writer just filled as the newest frame (lock-free) and hands the writer the previously
// published one, so an unread frame is replaced rather than queued.
triple_publish :: proc(triple: ^Triple($T)) {
	old := sync.atomic_exchange(&triple.latest, triple.write | FRESH)
	triple.write = old & 3
}

// The newest published frame; `fresh` when it wasn't returned before. Valid until the next call.
triple_front :: proc(triple: ^Triple($T)) -> (frame: ^T, fresh: bool) {
	if sync.atomic_load(&triple.latest) & FRESH != 0 {
		old := sync.atomic_exchange(&triple.latest, triple.read)
		triple.read = old & 3
		fresh = true
	}
	return &triple.slots[triple.read], fresh
}

// ---- single-producer single-consumer queue (bounded; push fails when full)

Queue :: struct($T: typeid, $N: int) where (N & (N - 1)) == 0 {
	items: [N]T,
	head:  u32, // consumer
	tail:  u32, // producer
}

// Appends an item from the producer thread; false when the queue is full (the caller decides whether to drop it).
queue_push :: proc(queue: ^Queue($T, $N), item: T) -> bool {
	tail := sync.atomic_load_explicit(&queue.tail, .Relaxed)
	if tail - sync.atomic_load_explicit(&queue.head, .Acquire) >= u32(N) do return false
	queue.items[tail % u32(N)] = item
	sync.atomic_store_explicit(&queue.tail, tail + 1, .Release)
	return true
}

// The oldest item without taking it (consumer thread), so the consumer can leave it for later; nil when empty.
// Valid until the next queue_pop.
queue_peek :: proc(queue: ^Queue($T, $N)) -> ^T {
	head := sync.atomic_load_explicit(&queue.head, .Relaxed)
	if head == sync.atomic_load_explicit(&queue.tail, .Acquire) do return nil
	return &queue.items[head % u32(N)]
}

// Takes the oldest item on the consumer thread; `ok` is false when the queue is empty.
queue_pop :: proc(queue: ^Queue($T, $N)) -> (item: T, ok: bool) {
	head := sync.atomic_load_explicit(&queue.head, .Relaxed)
	if head == sync.atomic_load_explicit(&queue.tail, .Acquire) do return
	item = queue.items[head % u32(N)]
	sync.atomic_store_explicit(&queue.head, head + 1, .Release)
	return item, true
}

// The number of items waiting. Read from either thread it is a snapshot that may already be stale.
queue_len :: proc(queue: ^Queue($T, $N)) -> int {
	return int(sync.atomic_load(&queue.tail) - sync.atomic_load(&queue.head))
}

// ---- interpolation factor

// Where the render clock sits between the two newest ticks P-1 (alpha 0) and P (alpha 1): `due_us` is when
// tick P was due on the sim clock. Clamped to [0, 1] (no extrapolation).
alpha :: proc(now_us, due_us, tick_us: i64) -> f32 {
	if tick_us <= 0 do return 1
	return clamp(f32(now_us - due_us) / f32(tick_us), 0, 1)
}
