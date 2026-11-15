// The host's memory of every keyed item's pose (session thread), so fill_frame never passes previous poses: an
// item seen at tick - 1 interpolates from that pose. After a rollback the tick - 1 pose it remembers is the old
// prediction, so it sends an estimate of the corrected one instead (#284, measured under --lag): a tick re-filled
// (the same tick again) moves its tick - 1 pose by the same correction; a rollback with a new tick, or a fill after
// skipped ticks, takes the new pose minus the last known one-tick motion. The main thread feeds it into the view's
// error term (view.track_push_prev), so a correction glides instead of popping. Two open-addressed tables, the last
// fill's and this one's, told apart by a stamp, so nothing is cleared per tick.
package godot

import "core:fmt"
import "unified:view"

Pose_Domain :: enum u8 {
	View, // keys are unique among scene views
	Multi, // keys are per Multi kind
}

@(private)
Pose_Entry :: struct {
	key:      u64,
	stamp:    u32, // the fill that wrote it (0: never)
	tick:     u32,
	kind:     u8,
	has_prev: bool,
	pose:     Remembered_Pose,
	prev:     Remembered_Pose,
}

Remembered_Pose :: struct {
	pos: [3]f32,
	rot: [4]f32, // a scene view's quaternion; a MultiMesh instance's yaw in rot.x
}

@(private)
Pose_Table :: struct {
	entries: [2][]Pose_Entry, // by fill parity
	mask:    int,
}

Pose_Memory :: struct {
	tables:   [Pose_Domain]Pose_Table,
	fill:     u32, // the current fill (starts at 1)
	rollback: bool, // this fill's tick - 1 was re-simulated (a rollback landed with it)
}

// Room for `views` scene views and `multis` MultiMesh instances per fill.
pose_memory_init :: proc(memory: ^Pose_Memory, views, multis: int) {
	sizes := [Pose_Domain]int {
		.View  = views,
		.Multi = multis,
	}
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
	for &table in memory.tables do for entries in table.entries do delete(entries)
	memory^ = {}
}

// Starts a fill (before fill_frame); `rollback`: the fill's tick - 1 was re-simulated.
pose_memory_begin :: proc(memory: ^Pose_Memory, rollback := false) {
	memory.fill += 1
	memory.rollback = rollback
}

// The pose one tick before `pose`, moved by the motion from `prev` to `last` (rotations: the same turn).
@(private)
step_back :: proc(pose: Remembered_Pose, last, prev: Remembered_Pose) -> Remembered_Pose {
	return {
		pos = pose.pos - (last.pos - prev.pos),
		rot = view.qmul(view.qmul(prev.rot, view.qconj(last.rot)), pose.rot),
	}
}

// The tick - 1 pose `pose_prev` moved by the correction from `old` to `pose` (a re-filled tick).
@(private)
shift :: proc(pose_prev, old, pose: Remembered_Pose) -> Remembered_Pose {
	return {
		pos = pose_prev.pos + (pose.pos - old.pos),
		rot = view.qmul(view.qmul(pose.rot, view.qconj(old.rot)), pose_prev.rot),
	}
}

@(private)
pose_slot :: proc(key: u64, kind: u8, mask: int) -> int {
	hash := (key ~ u64(kind) << 56) * 0x9E3779B97F4A7C15
	return int(hash >> 32) & mask
}

// Records the item's pose at `tick` and returns the pose it had at tick - 1, if the host knows it.
pose_remember :: proc(
	memory: ^Pose_Memory,
	domain: Pose_Domain,
	kind: u8,
	key: u64,
	tick: u32,
	pos: [3]f32,
	rot: [4]f32,
) -> (
	previous: Remembered_Pose,
	found: bool,
) {
	table := &memory.tables[domain]
	if len(table.entries[0]) == 0 do return
	last := table.entries[(memory.fill - 1) & 1]
	current := table.entries[memory.fill & 1]
	slot := pose_slot(key, kind, table.mask)
	for i := slot; last[i].stamp == memory.fill - 1; i = (i + 1) & table.mask {
		entry := &last[i]
		if entry.key != key || entry.kind != kind do continue
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
		}
		break
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
			pose     = {pos, rot},
			prev     = previous,
		}
		return
	}
}

// Each scene view kind's data type, learned from push_view (session thread): a kind always pushes the same type.
@(private)
view_data_types: [256]typeid

@(private)
view_data_type :: proc(kind: u8, data_type: typeid, loc := #caller_location) {
	known := view_data_types[kind]
	if known == nil {
		view_data_types[kind] = data_type
	} else if known != data_type {
		panic(fmt.tprintf("push_view: view kind %d pushed %v, before %v", kind, data_type, known), loc)
	}
}
