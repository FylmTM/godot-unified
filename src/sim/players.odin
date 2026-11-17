// Players (src/sim/SPEC.md "Players"): a slot is an input index 0 ..< PLAYERS; a player is a session member, the
// person, named by a Player handle that stays theirs when they leave and come back in any free slot. The game
// keeps one Players field in its State: the member table, who holds each slot and the game's per-player struct.
// The harness updates it before `tick` from the tick's presence and join records and emits the join and leave
// events; the game reads it through handles.
package sim

import "base:runtime"
import "core:fmt"
import "core:strings"

NO_SLOT :: u8(0xFF) // Member.slot of an absent member

// A session member: `index` is its entry in Players.members, `id` the member id the relay gave the person (never
// reused in a session). Player{} is nobody. A handle whose entry now holds another id is stale (player_data: nil).
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

// Who is in the session: State holds exactly one (found by type at create). The session remembers 2 x PLAYERS
// people (MEMBERS_PER_SLOT): a newcomer to a full table takes the entry of the longest-absent member, whose handles go
// stale and who is new if they come back. `before` is each slot's Input of the tick before (input_before: presses
// are the difference), kept in the state so a rollback, a snapshot and a replay carry it. The pads keep `before`
// and `data` 8-aligned.
Players :: struct($T: typeid, $Input: typeid, $PLAYERS: int) where PLAYERS >= 1 && PLAYERS <= MAX_PLAYERS {
	members: [PLAYERS * MEMBERS_PER_SLOT]Member,
	slots:   [PLAYERS]Player, // who holds each slot (Player{}: nobody)
	_pad:    [PLAYERS % 2 * 4]u8,
	before:  [PLAYERS]Input, // each slot's input of the tick before (zero on its holder's first tick; while absent)
	_pad2:   [(8 - PLAYERS * size_of(Input) % 8) % 8]u8,
	data:    [PLAYERS * MEMBERS_PER_SLOT]T, // the game's per-player struct, by member index: zeroed for a new member
}

MEMBERS_PER_SLOT :: 2 // how many people a session remembers per slot (Players.members)

// A member joined (`returning`: it was in the session before and keeps its handle and data) in `slot`. The harness
// emits it before `tick` runs; the game's Event union lists it.
Event_Player_Joined :: struct {
	player:    Player,
	slot:      u8,
	returning: bool,
	_pad:      [2]u8,
}

// A member left `slot`. Its data stays until the table needs the entry (player_data still answers).
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
player_data :: proc(players: ^Players($T, $Input, $PLAYERS), player: Player) -> ^T {
	if !player_known(players, player) {
		return nil
	}
	return &players.data[player.index]
}

// Whether the handle names a member the table still remembers (present or absent).
player_known :: proc(players: ^Players($T, $Input, $PLAYERS), player: Player) -> bool {
	return player.id != 0 && int(player.index) < len(players.members) && players.members[player.index].id == player.id
}

// The slot the player holds this tick (present), or -1 and false when absent or unknown.
player_slot :: proc(players: ^Players($T, $Input, $PLAYERS), player: Player) -> (slot: int, present: bool) {
	if !player_known(players, player) || players.members[player.index].slot == NO_SLOT {
		return -1, false
	}
	return int(players.members[player.index].slot), true
}

// Whether the player holds a slot this tick.
player_present :: proc(players: ^Players($T, $Input, $PLAYERS), player: Player) -> bool {
	_, present := player_slot(players, player)
	return present
}

// Who holds `slot` (Player{}: nobody, or a slot out of range).
player_in_slot :: proc(players: ^Players($T, $Input, $PLAYERS), slot: int) -> Player {
	return players.slots[slot] if slot >= 0 && slot < PLAYERS else {}
}

// Walks the players with their data (iterate_present or iterate_known, then next):
//
//   players := sim.iterate_present(&t.state.players)
//   for data, player in sim.next(&players) { ... }
//
// iterate_present: the present players in slot order; iterate_known: every remembered member, present or absent, in
// member order.
Players_Iterator :: struct($T: typeid, $Input: typeid, $PLAYERS: int) {
	players: ^Players(T, Input, PLAYERS),
	index:   int, // the next slot (present) or member (known) to look at
	known:   bool,
}

iterate_present :: #force_inline proc(players: ^Players($T, $Input, $PLAYERS)) -> Players_Iterator(T, Input, PLAYERS) {
	return {players = players}
}

iterate_known :: #force_inline proc(players: ^Players($T, $Input, $PLAYERS)) -> Players_Iterator(T, Input, PLAYERS) {
	return {players = players, known = true}
}

players_next :: #force_inline proc(
	iterator: ^Players_Iterator($T, $Input, $PLAYERS),
) -> (
	data: ^T,
	player: Player,
	ok: bool,
) {
	players := iterator.players
	if iterator.known {
		for iterator.index < len(players.members) {
			index := iterator.index
			iterator.index += 1
			if id := players.members[index].id; id != 0 {
				return &players.data[index], {u16(index), id}, true
			}
		}
		return
	}
	for iterator.index < PLAYERS {
		holder := players.slots[iterator.index]
		iterator.index += 1
		if holder.id != 0 {
			return &players.data[holder.index], holder, true
		}
	}
	return
}

// The player's input this tick (zero when absent).
input :: proc(tick: ^Tick($State, $Input, $World, $Event, $Cmd, $PLAYERS), player: Player) -> Input {
	slot := tick_slot(tick, player)
	return tick.inputs.input[slot] if slot >= 0 else {}
}

// The player's input of the tick before, in the slot they hold now (zero on their first tick in it, and when
// absent): a button pressed this tick is down in `input` and not here.
//
//   pressed := sim.input(t, player).buttons - sim.input_before(t, player).buttons
input_before :: proc(tick: ^Tick($State, $Input, $World, $Event, $Cmd, $PLAYERS), player: Player) -> Input {
	slot := tick_slot(tick, player)
	if slot < 0 do return {}
	view := players_view(tick.state, tick.players_layout)
	return ([^]Input)(view.before)[slot]
}

// The commands `player` sent for this tick, decoded, in the order sent; empty when absent, never a nil entry (one
// whose bytes don't decode is left out on every peer alike). Valid until the tick returns:
//
//   for sent in sim.commands(t, player) {
//       switch command in sent { case Cmd_Pick: ... }
//   }
commands :: proc(tick: ^Tick($State, $Input, $World, $Event, $Cmd, $PLAYERS), player: Player) -> []Cmd {
	slot := tick_slot(tick, player)
	return commands_of_slot(tick.commands, slot) if slot >= 0 else nil
}

// A join record for a test or a script: `member` (the relay's id, >= 1) becomes present in `slot` this tick.
join :: proc(inputs: ^Inputs($Input, $PLAYERS), slot: int, member: int) {
	assert(slot >= 0 && slot < PLAYERS && member >= 1 && member <= 0xFFFF)
	inputs.present += {slot}
	inputs.member[slot] = u16(member)
}

// Who holds `slot` in the simulation's current state (Player{}: nobody): for drivers outside `tick` (a scripted
// run adds a join record only for a slot nobody holds).
slot_player :: proc(simulation: ^Sim($State, $Input, $World, $Event, $Cmd, $PLAYERS), slot: int) -> Player {
	view := players_view(&simulation.state, &simulation.players_layout)
	return view.slots[slot] if slot >= 0 && slot < PLAYERS else {}
}

// The member table and who holds each slot in `state` (one of the simulation's: its current one, or a saved tick's
// from state_at), for drivers outside `tick` that know the State only generically (a view host).
players_of :: proc(
	simulation: ^Sim($State, $Input, $World, $Event, $Cmd, $PLAYERS),
	state: ^State,
) -> (
	members: []Member,
	slots: []Player,
) {
	view := players_view(state, &simulation.players_layout)
	return view.members, view.slots
}

// The slot `player` holds in the tick being computed (-1: absent or unknown).
@(private)
tick_slot :: proc(tick: ^Tick($State, $Input, $World, $Event, $Cmd, $PLAYERS), player: Player) -> int {
	view := players_view(tick.state, tick.players_layout)
	if player.id == 0 || int(player.index) >= len(view.members) {
		return -1
	}
	member := view.members[player.index]
	return int(member.slot) if member.id == player.id && member.slot != NO_SLOT else -1
}

// Where the State's Players field is, found by RTTI at create.
Players_Layout :: struct {
	offset:    int, // of the field in State
	members:   int, // 2 x PLAYERS
	slots:     int, // PLAYERS
	slots_at:  int, // offset of `slots` in the Players
	data_at:   int, // offset of `data`
	data_size: int, // size_of(T)
	before_at: int, // offset of `before`
	input:     int, // size_of(its Input)
}

// The Players of a state block, untyped (the harness's view of it).
@(private)
Players_View :: struct {
	members: []Member,
	slots:   []Player,
	data:    [^]u8,
	stride:  int,
	before:  [^]u8, // [slots]Input
	input:   int, // size_of(Input)
}

@(private)
players_view :: proc(state: rawptr, layout: ^Players_Layout) -> Players_View {
	base := uintptr(state) + uintptr(layout.offset)
	return {
		members = ([^]Member)(rawptr(base))[:layout.members],
		slots   = ([^]Player)(rawptr(base + uintptr(layout.slots_at)))[:layout.slots],
		data    = ([^]u8)(rawptr(base + uintptr(layout.data_at))),
		stride  = layout.data_size,
		before  = ([^]u8)(rawptr(base + uintptr(layout.before_at))),
		input   = layout.input,
	}
}

// Finds the State's one Players field and checks it ("" and the layout when it is there and fits PLAYERS and the
// game's Input).
players_layout_of :: proc(
	state: ^runtime.Type_Info,
	players: int,
	input: ^runtime.Type_Info,
) -> (
	layout: Players_Layout,
	reason: string,
) {
	info, is_struct := runtime.type_info_base(state).variant.(runtime.Type_Info_Struct)
	if !is_struct {
		return {}, "State is not a struct"
	}
	found := 0
	for i in 0 ..< int(info.field_count) {
		field := info.types[i]
		if !is_players(field) {
			continue
		}
		found += 1
		table := runtime.type_info_base(field).variant.(runtime.Type_Info_Struct)
		layout.offset = int(info.offsets[i])
		for j in 0 ..< int(table.field_count) {
			array, is_array := runtime.type_info_base(table.types[j]).variant.(runtime.Type_Info_Array)
			if !is_array do continue
			switch table.names[j] {
			case "members":
				layout.members = array.count
			case "slots":
				layout.slots, layout.slots_at = array.count, int(table.offsets[j])
			case "data":
				layout.data_at, layout.data_size = int(table.offsets[j]), array.elem_size
			case "before":
				layout.before_at, layout.input = int(table.offsets[j]), array.elem_size
				if array.elem.id != input.id do reason = fmt.tprintf("the State's Players is for the input %v, the game's is %v", array.elem.id, input.id)
			}
		}
	}
	switch {
	case reason != "":
	case found == 0:
		reason = "State has no sim.Players field (the session's players: src/sim/SPEC.md, Players)"
	case found > 1:
		reason = fmt.tprintf("State has %d sim.Players fields (exactly one)", found)
	case layout.slots != players:
		reason = fmt.tprintf("the State's Players is for %d players, the game has %d", layout.slots, players)
	}
	return
}

// A sim.Players(T, Input, PLAYERS): its RTTI names it "Players($T=...)" in package sim.
@(private)
is_players :: proc(type: ^runtime.Type_Info) -> bool {
	named, ok := type.variant.(runtime.Type_Info_Named)
	return ok && named.pkg == "sim" && strings.has_prefix(named.name, "Players(")
}

// The changes of a tick's presence, for Tick.player_changes.
@(private)
Changes_Buffer :: struct($PLAYERS: int) {
	joined, returned, left:                   [PLAYERS]Player,
	joined_count, returned_count, left_count: int,
}

// Applies a tick's presence and join records to the State's Players before `tick` (the harness, advance):
// leaves first (a slot no longer present, or present with another member's join record), then joins in slot order
// (a slot that becomes present with a join record; without one it stays absent).
@(private)
players_update :: proc(
	view: Players_View,
	inputs: ^Inputs($Input, $PLAYERS),
	number: u32,
	events: ^Events,
	changes: ^Changes_Buffer(PLAYERS),
) {
	changes^ = {}
	for slot in 0 ..< PLAYERS {
		holder := view.slots[slot]
		record := inputs.member[slot]
		if holder.id == 0 || (slot in inputs.present && (record == 0 || record == holder.id)) {
			continue
		}
		players_leave(view, slot, number, events, changes)
	}
	for slot in 0 ..< PLAYERS {
		record := inputs.member[slot]
		if record == 0 || slot not_in inputs.present || view.slots[slot].id != 0 {
			continue
		}
		for other in 0 ..< slot {
			// read_joins refuses it; two would leave one slot twice, past changes.left
			assert(other not_in inputs.present || inputs.member[other] != record, "one member in two join records")
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
				players_leave(view, int(elsewhere), number, events, changes) // the same person in two slots: the newest
			}
		} else {
			index = players_entry(view, number)
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
		runtime.memset(view.before[slot * view.input:], 0, view.input) // nothing held before their first tick here
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

// After `tick`: each slot's input becomes its `before` for the next tick (zero for a slot nobody holds).
@(private)
players_remember :: proc(view: Players_View, inputs: ^Inputs($Input, $PLAYERS)) {
	before := ([^]Input)(view.before)
	for slot in 0 ..< PLAYERS {
		before[slot] = inputs.input[slot] if view.slots[slot].id != 0 else {}
	}
}

@(private)
players_leave :: proc(
	view: Players_View,
	slot: int,
	number: u32,
	events: ^Events,
	changes: ^Changes_Buffer($PLAYERS),
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
// t.player_changes.left must still name its data while the game cleans up. (The relay never needs it: a slot it seats was free on
// the tick before, so the members present then and the free or longer-absent entries always cover the joins.)
@(private)
players_entry :: proc(view: Players_View, number: u32) -> int {
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
