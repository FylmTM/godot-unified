// Players (src/sim/SPEC.md "Players"): a slot is an input index 0 ..< PLAYERS; a player is a session member, the
// person, named by a Player handle that stays theirs when they leave and come back in any free slot. The game
// keeps one Presence field in its State: the member table, who holds each slot and the game's per-player struct.
// The harness updates it before `tick` from the tick's presence and join records and emits the join and leave
// events; the game reads it through handles.
package sim

import "base:runtime"
import "core:fmt"
import "core:strings"

NO_SLOT :: u8(0xFF) // Member.slot of an absent member

// A session member: `index` is its entry in Presence.members, `id` the member id the relay gave the person (never
// reused in a session). Player{} is nobody. A handle whose entry now holds another id is stale (player_get: nil).
Player :: struct {
	index: u16,
	id:    u16,
}

// One entry of the member table: id 0 is a free entry.
Member :: struct {
	id:    u16,
	slot:  u8, // NO_SLOT when absent
	_pad:  u8,
	since: u32, // the tick of the member's last join or leave
}

// Who is in the session: State holds exactly one (found by type at create). MEMBERS (>= PLAYERS) is how many people
// the session remembers: a newcomer to a full table takes the entry of the longest-absent member, whose handles go
// stale and who is new if they come back. `_pad` keeps `data` aligned (4 bytes when PLAYERS is odd).
Presence :: struct(
	$T: typeid,
	$PLAYERS, $MEMBERS: int,
) where PLAYERS >= 1 &&
	PLAYERS <= MAX_PLAYERS &&
	MEMBERS >= PLAYERS &&
	MEMBERS <= 1 << 16 {
	members: [MEMBERS]Member,
	slots:   [PLAYERS]Player, // who holds each slot (Player{}: nobody)
	_pad:    [PLAYERS % 2 * 4]u8,
	data:    [MEMBERS]T, // the game's per-player struct, by member index: zeroed for a new member
}

// A member joined (`returning`: it was in the session before and keeps its handle and data) in `slot`. The harness
// emits it before `tick` runs; the game's Event union lists it.
Event_Player_Joined :: struct {
	player:    Player,
	slot:      u8,
	returning: bool,
	_pad:      [2]u8,
}

// A member left `slot`. Its data stays until the table needs the entry (player_get still answers).
Event_Player_Left :: struct {
	player: Player,
	slot:   u8,
	_pad:   [3]u8,
}

// A u64 key unique among a session's players (0: nobody): what views and GDScript name a player by.
player_key :: proc(player: Player) -> u64 {
	return u64(player.id) << 16 | u64(player.index) if player.id != 0 else 0
}

// The handle a player_key names (Player{} for 0 or a key no handle makes).
player_of_key :: proc(key: u64) -> Player {
	if key == 0 || key >> 32 != 0 || (key >> 16) & 0xFFFF == 0 {
		return {}
	}
	return {index = u16(key & 0xFFFF), id = u16(key >> 16)}
}

// The player's data, or nil when the handle is nobody, stale or forgotten. Valid while the player is absent.
player_get :: proc(presence: ^Presence($T, $PLAYERS, $MEMBERS), player: Player) -> ^T {
	if !player_known(presence, player) {
		return nil
	}
	return &presence.data[player.index]
}

// Whether the handle names a member the table still remembers (present or absent).
player_known :: proc(presence: ^Presence($T, $PLAYERS, $MEMBERS), player: Player) -> bool {
	return player.id != 0 && int(player.index) < MEMBERS && presence.members[player.index].id == player.id
}

// The slot the player holds this tick (present), or -1 and false when absent or unknown.
player_slot :: proc(presence: ^Presence($T, $PLAYERS, $MEMBERS), player: Player) -> (slot: int, present: bool) {
	if !player_known(presence, player) || presence.members[player.index].slot == NO_SLOT {
		return -1, false
	}
	return int(presence.members[player.index].slot), true
}

// Whether the player holds a slot this tick.
player_present :: proc(presence: ^Presence($T, $PLAYERS, $MEMBERS), player: Player) -> bool {
	_, present := player_slot(presence, player)
	return present
}

// Who holds `slot` (Player{}: nobody, or a slot out of range).
player_in_slot :: proc(presence: ^Presence($T, $PLAYERS, $MEMBERS), slot: int) -> Player {
	return presence.slots[slot] if slot >= 0 && slot < PLAYERS else {}
}

// Walks the players with their data (iterate_present or iterate_known, then next):
//
//   players := sim.iterate_present(&t.state.players)
//   for data, player in sim.next(&players) { ... }
//
// iterate_present: the present players in slot order; iterate_known: every remembered member, present or absent, in
// member order.
Presence_Iterator :: struct($T: typeid, $PLAYERS, $MEMBERS: int) {
	presence: ^Presence(T, PLAYERS, MEMBERS),
	index:    int, // the next slot (present) or member (known) to look at
	known:    bool,
}

iterate_present :: #force_inline proc(
	presence: ^Presence($T, $PLAYERS, $MEMBERS),
) -> Presence_Iterator(T, PLAYERS, MEMBERS) {
	return {presence = presence}
}

iterate_known :: #force_inline proc(
	presence: ^Presence($T, $PLAYERS, $MEMBERS),
) -> Presence_Iterator(T, PLAYERS, MEMBERS) {
	return {presence = presence, known = true}
}

presence_next :: #force_inline proc(iterator: ^Presence_Iterator($T, $PLAYERS, $MEMBERS)) -> (data: ^T, player: Player, ok: bool) {
	presence := iterator.presence
	if iterator.known {
		for iterator.index < MEMBERS {
			index := iterator.index
			iterator.index += 1
			if id := presence.members[index].id; id != 0 {
				return &presence.data[index], {u16(index), id}, true
			}
		}
		return
	}
	for iterator.index < PLAYERS {
		holder := presence.slots[iterator.index]
		iterator.index += 1
		if holder.id != 0 {
			return &presence.data[holder.index], holder, true
		}
	}
	return
}

// The player's input this tick (zero when absent).
input :: proc(tick: ^Tick($State, $Input, $World, $PLAYERS), player: Player) -> Input {
	slot := tick_slot(tick, player)
	return tick.inputs.input[slot] if slot >= 0 else {}
}

// The commands `player` sent for this tick, in the order sent (none when absent):
//
//   for &raw in sim.commands(t, player) {
//       switch command in sim.command_value(&raw, Cmd) { ... }
//   }
player_commands :: proc(tick: ^Tick($State, $Input, $World, $PLAYERS), player: Player) -> []Raw_Command {
	slot := tick_slot(tick, player)
	return slot_commands(tick.inputs, slot) if slot >= 0 else nil
}

commands :: proc {
	player_commands,
	slot_commands,
}

// A join record for a test or a script: `member` (the relay's id, >= 1) becomes present in `slot` this tick.
join :: proc(inputs: ^Inputs($Input, $PLAYERS), slot: int, member: int) {
	assert(slot >= 0 && slot < PLAYERS && member >= 1 && member <= 0xFFFF)
	inputs.present += {slot}
	inputs.member[slot] = u16(member)
}

// Who holds `slot` in the simulation's current state (Player{}: nobody): for drivers outside `tick` (a scripted
// run adds a join record only for a slot nobody holds).
slot_player :: proc(simulation: ^Sim($State, $Input, $World, $PLAYERS), slot: int) -> Player {
	view := presence_view(&simulation.state, &simulation.presence)
	return view.slots[slot] if slot >= 0 && slot < PLAYERS else {}
}

// The member table and who holds each slot in `state` (one of the simulation's: its current one, or a saved tick's
// from state_at), for drivers outside `tick` that know the State only generically (a view host).
players_of :: proc(
	simulation: ^Sim($State, $Input, $World, $PLAYERS),
	state: ^State,
) -> (
	members: []Member,
	slots: []Player,
) {
	view := presence_view(state, &simulation.presence)
	return view.members, view.slots
}

// The slot `player` holds in the tick being computed (-1: absent or unknown).
@(private)
tick_slot :: proc(tick: ^Tick($State, $Input, $World, $PLAYERS), player: Player) -> int {
	view := presence_view(tick.state, tick.presence)
	if player.id == 0 || int(player.index) >= len(view.members) {
		return -1
	}
	member := view.members[player.index]
	return int(member.slot) if member.id == player.id && member.slot != NO_SLOT else -1
}

// Where the State's Presence field is, found by RTTI at create.
Presence_Layout :: struct {
	offset:    int, // of the field in State
	members:   int, // MEMBERS
	slots:     int, // PLAYERS
	slots_at:  int, // offset of `slots` in the Presence
	data_at:   int, // offset of `data`
	data_size: int, // size_of(T)
}

// The Presence of a state block, untyped (the harness's view of it).
@(private)
Presence_View :: struct {
	members: []Member,
	slots:   []Player,
	data:    [^]u8,
	stride:  int,
}

@(private)
presence_view :: proc(state: rawptr, layout: ^Presence_Layout) -> Presence_View {
	base := uintptr(state) + uintptr(layout.offset)
	return {
		members = ([^]Member)(rawptr(base))[:layout.members],
		slots   = ([^]Player)(rawptr(base + uintptr(layout.slots_at)))[:layout.slots],
		data    = ([^]u8)(rawptr(base + uintptr(layout.data_at))),
		stride  = layout.data_size,
	}
}

// Finds the State's one Presence field and checks it ("" and the layout when it is there and fits PLAYERS).
presence_layout_of :: proc(state: ^runtime.Type_Info, players: int) -> (layout: Presence_Layout, reason: string) {
	info, is_struct := runtime.type_info_base(state).variant.(runtime.Type_Info_Struct)
	if !is_struct {
		return {}, "State is not a struct"
	}
	found := 0
	for i in 0 ..< int(info.field_count) {
		field := info.types[i]
		if !is_presence(field) {
			continue
		}
		found += 1
		presence := runtime.type_info_base(field).variant.(runtime.Type_Info_Struct)
		layout.offset = int(info.offsets[i])
		for j in 0 ..< int(presence.field_count) {
			array, is_array := runtime.type_info_base(presence.types[j]).variant.(runtime.Type_Info_Array)
			if !is_array do continue
			switch presence.names[j] {
			case "members":
				layout.members = array.count
			case "slots":
				layout.slots, layout.slots_at = array.count, int(presence.offsets[j])
			case "data":
				layout.data_at, layout.data_size = int(presence.offsets[j]), array.elem_size
			}
		}
	}
	switch {
	case found == 0:
		reason = "State has no sim.Presence field (the session's players: src/sim/SPEC.md, Players)"
	case found > 1:
		reason = fmt.tprintf("State has %d sim.Presence fields (exactly one)", found)
	case layout.slots != players:
		reason = fmt.tprintf("the State's Presence is for %d players, the game has %d", layout.slots, players)
	}
	return
}

// A sim.Presence(T, PLAYERS, MEMBERS): its RTTI names it "Presence($T=...)" in package sim.
@(private)
is_presence :: proc(type: ^runtime.Type_Info) -> bool {
	named, ok := type.variant.(runtime.Type_Info_Named)
	return ok && named.pkg == "sim" && strings.has_prefix(named.name, "Presence(")
}

// The changes of a tick's presence, for Tick.joined, returned and left.
@(private)
Presence_Changes :: struct($PLAYERS: int) {
	joined, returned, left:                   [PLAYERS]Player,
	joined_count, returned_count, left_count: int,
}

// Applies a tick's presence and join records to the State's Presence before `tick` (the harness, advance):
// leaves first (a slot no longer present, or present with another member's join record), then joins in slot order
// (a slot that becomes present with a join record; without one it stays absent).
@(private)
presence_update :: proc(
	view: Presence_View,
	inputs: ^Inputs($Input, $PLAYERS),
	number: u32,
	events: ^Events,
	changes: ^Presence_Changes(PLAYERS),
) {
	changes^ = {}
	for slot in 0 ..< PLAYERS {
		holder := view.slots[slot]
		record := inputs.member[slot]
		if holder.id == 0 || (slot in inputs.present && (record == 0 || record == holder.id)) {
			continue
		}
		presence_leave(view, slot, number, events, changes)
	}
	for slot in 0 ..< PLAYERS {
		record := inputs.member[slot]
		if record == 0 || slot not_in inputs.present || view.slots[slot].id != 0 {
			continue
		}
		index := -1
		for member, i in view.members {
			if member.id == record {
				index = i
				break
			}
		}
		returning := index >= 0
		if returning {
			if elsewhere := view.members[index].slot; elsewhere != NO_SLOT {
				presence_leave(view, int(elsewhere), number, events, changes) // the same person in two slots: the newest
			}
		} else {
			index = presence_entry(view, number)
			if index < 0 {
				continue // no entry to give: the slot stays absent (only a script's leave and join in one tick)
			}
			view.members[index] = {
				id = record,
			}
			runtime.memset(view.data[index * view.stride:], 0, view.stride)
		}
		member := &view.members[index]
		member.slot = u8(slot)
		member.since = number
		player := Player{u16(index), record}
		view.slots[slot] = player
		if returning {
			changes.returned[changes.returned_count] = player
			changes.returned_count += 1
		} else {
			changes.joined[changes.joined_count] = player
			changes.joined_count += 1
		}
		emit_to(events, Event_Player_Joined{player = player, slot = u8(slot), returning = returning})
	}
}

@(private)
presence_leave :: proc(
	view: Presence_View,
	slot: int,
	number: u32,
	events: ^Events,
	changes: ^Presence_Changes($PLAYERS),
) {
	holder := view.slots[slot]
	member := &view.members[holder.index]
	member.slot = NO_SLOT
	member.since = number
	view.slots[slot] = {}
	changes.left[changes.left_count] = holder
	changes.left_count += 1
	emit_to(events, Event_Player_Left{player = holder, slot = u8(slot)})
}

// The entry for a new member: the first free one, else the longest-absent member's (the lowest `since`; ties: the
// lowest index), -1 when there is none. A member who left on this tick is never forgotten on it: its handle in
// t.left must still name its data while the game cleans up. (The relay never needs it: a slot it seats was free on
// the tick before, so the members present then and the free or longer-absent entries always cover the joins.)
@(private)
presence_entry :: proc(view: Presence_View, number: u32) -> int {
	oldest := -1
	for member, i in view.members {
		if member.id == 0 {
			return i
		}
		if member.slot == NO_SLOT &&
		   member.since != number &&
		   (oldest < 0 || member.since < view.members[oldest].since) {
			oldest = i
		}
	}
	return oldest
}
