// The host's memory of every keyed item's pose (session thread), so fill_frame never passes previous poses: an item
// seen at tick - 1 interpolates from that pose. After a rollback the tick - 1 pose it remembers is the old prediction,
// so it sends an estimate of the corrected one instead: a tick re-filled (the same tick again) moves its tick - 1 pose
// by the same correction; a rollback with a new tick, or a fill after skipped ticks, takes the new pose minus the last
// known one-tick motion (none known yet: the point a tick short of the new pose on the line from the last one). The
// main thread feeds it into the view's error term (track_push_prev), so a correction glides
// instead of popping. Two open-addressed tables, the last fill's and this one's, told apart by a stamp, so nothing is
// cleared per tick; both grow (rehashed) when a fill would make its own more than half full.
package godot

import "base:runtime"
import "core:fmt"

// Which items a pose belongs to: scene views and MultiMesh instances are remembered apart.
Pose_Domain :: enum u8 {
	View, // keys are unique within a scene view kind (the hash takes the kind)
	Multi, // keys are unique within a MultiMesh kind
}

@(private)
Pose_Entry :: struct {
	key:      u64,
	stamp:    u32, // the fill that wrote it (0: never)
	tick:     u32,
	kind:     u8,
	has_prev: bool,
	warp:     u8, // the item's warp epoch (View_Item.warp): a pose of another epoch is no previous pose
	since:    u32, // the earliest tick the key is known to be in the current timeline (appear-on-verified)
	pose:     Remembered_Pose,
	prev:     Remembered_Pose,
}

// An item's pose as the host remembers it, in sim units.
Remembered_Pose :: struct {
	pos: [3]f32,
	rot: [4]f32, // a unit quaternion
}

@(private)
Pose_Table :: struct {
	entries: [2][]Pose_Entry, // by fill parity
	mask:    int,
	count:   int, // entries this fill wrote
}

// Every keyed item's pose at the last fill and at this one (session thread; one per session's driver).
Pose_Memory :: struct {
	tables:        [Pose_Domain]Pose_Table,
	fill:          u32, // the current fill (starts at 1)
	rollback:      bool, // this fill's tick - 1 was re-simulated (a rollback landed with it)
	resim_from:    u32, // the first tick this fill's step computed (Frame_Info.resim_from; 0: unknown)
	// Appear-on-verified: the keys of the last fill of a verified tick (another memory, its own fills), and that tick.
	verified:      ^Pose_Memory,
	verified_tick: u32,
	alloc:         runtime.Allocator,
}

// Room for `views` scene views and `multis` MultiMesh instances per fill to start with (they grow).
pose_memory_init :: proc(memory: ^Pose_Memory, views, multis: int) {
	sizes := [Pose_Domain]int {
		.View  = views,
		.Multi = multis,
	}
	memory.alloc = context.allocator
	for &table, domain in memory.tables {
		capacity := 16
		for capacity < 2 * sizes[domain] do capacity *= 2
		for &entries in table.entries do entries = make([]Pose_Entry, capacity)
		table.mask = capacity - 1
	}
	memory.fill = 1
}

// Frees the pose tables when the session's driver is torn down.
pose_memory_destroy :: proc(memory: ^Pose_Memory) {
	for &table in memory.tables do for entries in table.entries do delete(entries, memory.alloc)
	memory^ = {}
}

// Starts a fill (before fill_frame); `rollback`: the fill's tick - 1 was re-simulated; `resim_from`: the first tick
// the step computed (a key first seen at or after it was re-simulated: its spawn may have moved).
pose_memory_begin :: proc(memory: ^Pose_Memory, rollback := false, resim_from: u32 = 0) {
	memory.fill += 1
	memory.rollback = rollback
	memory.resim_from = resim_from
	for &table in memory.tables do table.count = 0
}

// Whether the memory's last fill pushed the key (appear-on-verified's verified fill).
@(private)
pose_seen :: proc(memory: ^Pose_Memory, domain: Pose_Domain, kind: u8, key: u64) -> bool {
	table := &memory.tables[domain]
	if len(table.entries[0]) == 0 do return false
	current := table.entries[memory.fill & 1]
	for i := pose_slot(key, kind, table.mask); current[i].stamp == memory.fill; i = (i + 1) & table.mask {
		if current[i].key == key && current[i].kind == kind do return true
	}
	return false
}

// Doubles a table, rehashing the last fill's entries and this one's.
@(private)
pose_table_grow :: proc(memory: ^Pose_Memory, table: ^Pose_Table) {
	capacity := 2 * (table.mask + 1)
	for parity in 0 ..< 2 {
		old := table.entries[parity]
		grown := make([]Pose_Entry, capacity, memory.alloc)
		for entry in old {
			if entry.stamp != memory.fill && entry.stamp != memory.fill - 1 do continue
			i := pose_slot(entry.key, entry.kind, capacity - 1)
			for grown[i].stamp != 0 do i = (i + 1) & (capacity - 1)
			grown[i] = entry
		}
		delete(old, memory.alloc)
		table.entries[parity] = grown
	}
	table.mask = capacity - 1
}

// The pose one tick before `pose`, moved by the motion from `prev` to `last` (rotations: the same turn).
@(private)
step_back :: proc(pose: Remembered_Pose, last, prev: Remembered_Pose) -> Remembered_Pose {
	return {
		pos = pose.pos - (last.pos - prev.pos),
		rot = qmul(qmul(prev.rot, qconj(last.rot)), pose.rot),
	}
}

// The tick - 1 pose `pose_prev` moved by the correction from `old` to `pose` (a re-filled tick).
@(private)
shift :: proc(pose_prev, old, pose: Remembered_Pose) -> Remembered_Pose {
	return {
		pos = pose_prev.pos + (pose.pos - old.pos),
		rot = qmul(qmul(pose.rot, qconj(old.rot)), pose_prev.rot),
	}
}

@(private)
pose_slot :: proc(key: u64, kind: u8, mask: int) -> int {
	hash := (key ~ u64(kind) << 56) * 0x9E3779B97F4A7C15
	return int(hash >> 32) & mask
}

// Records the item's pose at `tick` and returns the pose it had at tick - 1, if the host knows it. Across a change of
// `warp` (the item's warp epoch) it knows none: no interpolation or correction estimate crosses a teleport. `since`:
// the earliest tick the key is known to be in the current timeline: the verified tick of a verified fill that had it,
// else the first fill that showed it, unless a rollback re-simulated that tick since (then this fill's).
pose_remember :: proc(
	memory: ^Pose_Memory,
	domain: Pose_Domain,
	kind: u8,
	key: u64,
	tick: u32,
	pos: [3]f32,
	rot: [4]f32,
	warp: u8 = 0,
) -> (
	previous: Remembered_Pose,
	found: bool,
	since: u32,
) {
	table := &memory.tables[domain]
	if len(table.entries[0]) == 0 do return
	last := table.entries[(memory.fill - 1) & 1]
	current := table.entries[memory.fill & 1]
	slot := pose_slot(key, kind, table.mask)
	matched := false
	since = tick
	for i := slot; last[i].stamp == memory.fill - 1; i = (i + 1) & table.mask {
		entry := &last[i]
		if entry.key != key || entry.kind != kind do continue
		matched = true
		if memory.resim_from == 0 || memory.resim_from > entry.since do since = entry.since // else re-simulated: proves nothing
		if entry.warp != warp do break // teleported since: no previous pose
		current := Remembered_Pose{pos, rot}
		switch {
		case entry.tick + 1 == tick && !(memory.rollback && entry.has_prev):
			previous, found = entry.pose, true
		case entry.tick == tick && entry.has_prev:
			// re-filled: tick - 1 moved by the same correction
			previous, found = shift(entry.prev, entry.pose, current), true
		case entry.tick < tick && entry.has_prev:
			// a rollback with a new tick, or skipped ticks
			previous, found = step_back(current, entry.pose, entry.prev), true
		case entry.tick + 1 == tick:
			previous, found = entry.pose, true
		case entry.tick < tick:
			// skipped ticks with no one-tick motion known (the item was new at the last fill): on the line from the
			// last pose, a tick short of this one. Else a session stepping two ticks a time (a busy machine) never
			// gave the item a previous pose.
			back := f32(tick - entry.tick - 1) / f32(tick - entry.tick)
			previous = {lerp3(entry.pose.pos, pos, back), nlerp(entry.pose.rot, rot, back)}
			found = true
		}
		break
	}
	if memory.verified != nil && pose_seen(memory.verified, domain, kind, key) {
		since = matched ? min(since, memory.verified_tick) : memory.verified_tick
	}
	if 2 * (table.count + 1) > table.mask + 1 {
		pose_table_grow(memory, table)
		current = table.entries[memory.fill & 1]
		slot = pose_slot(key, kind, table.mask)
	}
	for i := slot;; i = (i + 1) & table.mask {
		entry := &current[i]
		if entry.stamp == memory.fill {
			if entry.key == key && entry.kind == kind do return // pushed twice this fill: the first one counts
			continue
		}
		entry^ = {
			key      = key,
			stamp    = memory.fill,
			tick     = tick,
			kind     = kind,
			has_prev = found,
			warp     = warp,
			since    = since,
			pose     = {pos, rot},
			prev     = previous,
		}
		table.count += 1
		return
	}
}

// Each scene view kind's subject and data types, learned from push_view (session thread): a kind always pushes the
// same two (so its keys, one subject's, are unique within it).
@(private)
View_Kind_Types :: struct {
	pushed:    bool,
	subject:   typeid,
	data_type: typeid,
}

@(private)
view_kinds: [256]View_Kind_Types

@(private)
view_kind_types :: proc(kind: u8, subject, data_type: typeid, loc := #caller_location) {
	known := &view_kinds[kind]
	if !known.pushed {
		known^ = {true, subject, data_type}
		return
	}
	if known.data_type != data_type {
		panic(fmt.tprintf("push_view: view kind %d pushed %v, before %v", kind, data_type, known.data_type), loc)
	}
	if known.subject != subject {
		panic(
			fmt.tprintf(
				"push_view: view kind %d pushed a subject %v, before %v (nil: none)",
				kind,
				subject,
				known.subject,
			),
			loc,
		)
	}
}
