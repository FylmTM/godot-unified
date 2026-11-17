// Players (src/sim/SPEC.md "Players"): a slot is an input index 0 ..< PLAYERS; a player is a session member, the
// person, named by a Player handle that stays theirs when they leave and come back in any free slot. The game
// keeps its Players in its State's field `players`: the member table, who holds each slot and the game's per-player
// struct. The harness updates it before `tick` from the tick's presence and join records and emits the join and
// leave events; the game reads it through handles.
package sim

import "base:intrinsics"

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

// Who is in the session: the State's field `players` (sim.Game's where clause checks it). The session remembers
// 2 x PLAYERS people (MEMBERS_PER_SLOT): a newcomer to a full table takes the entry of the longest-absent member,
// whose handles go stale and who is new if they come back. `before` is each slot's Input of the tick before
// (input_before: presses are the difference), kept in the state so a rollback, a snapshot and a replay carry it. The
// pads keep `before` and `data` 8-aligned.
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

// The player queries below each take the tick being computed (`sim.player_data(t, player)`) or a State's Players
// (`sim.player_data(&state.players, player)`, outside a tick: views, tests).

// The player's data, or nil when the handle is nobody, stale or forgotten. Valid while the player is absent.
player_data :: proc {
	player_data_of_players,
	player_data_of_tick,
}

player_data_of_players :: proc(players: ^Players($T, $Input, $PLAYERS), player: Player) -> ^T {
	return &players.data[player.index] if player_known(players, player) else nil
}

// The result is the T of the State's `players: sim.Players(T, Input, PLAYERS)`.
player_data_of_tick :: proc(
	tick: ^Tick($G),
	player: Player,
) -> ^part(intrinsics.type_field_type(part(G, GAME_STATE), "players"), 0) {
	return player_data_of_players(&tick.state.players, player)
}

// Whether the handle names a member the table still remembers (present or absent).
player_known :: proc(players: ^Players($T, $Input, $PLAYERS), player: Player) -> bool {
	return player.id != 0 && int(player.index) < len(players.members) && players.members[player.index].id == player.id
}

// The slot the player holds this tick, or -1 (and false) when absent or unknown: `slot := sim.player_slot(t, player)`.
player_slot :: proc {
	player_slot_of_players,
	player_slot_of_tick,
}

player_slot_of_players :: proc(
	players: ^Players($T, $Input, $PLAYERS),
	player: Player,
) -> (
	slot: int,
	present: bool,
) #optional_ok {
	if !player_known(players, player) || players.members[player.index].slot == NO_SLOT {
		return -1, false
	}
	return int(players.members[player.index].slot), true
}

player_slot_of_tick :: proc(tick: ^Tick($G), player: Player) -> (slot: int, present: bool) #optional_ok {
	return player_slot_of_players(&tick.state.players, player)
}

// Whether the player holds a slot this tick.
player_present :: proc {
	player_present_of_players,
	player_present_of_tick,
}

player_present_of_players :: proc(players: ^Players($T, $Input, $PLAYERS), player: Player) -> bool {
	_, present := player_slot_of_players(players, player)
	return present
}

player_present_of_tick :: proc(tick: ^Tick($G), player: Player) -> bool {
	return player_present_of_players(&tick.state.players, player)
}

// Who holds `slot` (Player{}: nobody, or a slot out of range); also of a simulation's current state, for drivers
// outside `tick` (a scripted run adds a join record only for a slot nobody holds).
player_in_slot :: proc {
	player_in_slot_of_players,
	player_in_slot_of_tick,
	player_in_slot_of_sim,
}

player_in_slot_of_players :: proc(players: ^Players($T, $Input, $PLAYERS), slot: int) -> Player {
	return players.slots[slot] if slot >= 0 && slot < PLAYERS else {}
}

player_in_slot_of_tick :: proc(tick: ^Tick($G), slot: int) -> Player {
	return player_in_slot_of_players(&tick.state.players, slot)
}

player_in_slot_of_sim :: proc(simulation: ^Sim($G), slot: int) -> Player {
	return player_in_slot_of_players(&simulation.state.players, slot)
}

// How many players hold a slot this tick.
present_count :: proc {
	present_count_of_players,
	present_count_of_tick,
}

present_count_of_players :: proc(players: ^Players($T, $Input, $PLAYERS)) -> (count: int) {
	for holder in players.slots {
		if holder.id != 0 do count += 1
	}
	return
}

present_count_of_tick :: proc(tick: ^Tick($G)) -> int {
	return present_count_of_players(&tick.state.players)
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
input :: proc(tick: ^Tick($G), player: Player) -> part(G, GAME_INPUT) {
	slot := player_slot_of_tick(tick, player)
	return tick.inputs.input[slot] if slot >= 0 else {}
}

// The player's input of the tick before, in the slot they hold now (zero on their first tick in it, and when
// absent): a button pressed this tick is down in `input` and not here.
//
//   pressed := sim.input(t, player).buttons - sim.input_before(t, player).buttons
input_before :: proc(tick: ^Tick($G), player: Player) -> part(G, GAME_INPUT) {
	slot := player_slot_of_tick(tick, player)
	return tick.state.players.before[slot] if slot >= 0 else {}
}

// The commands `player` sent for this tick, decoded, in the order sent; empty when absent, never a nil entry (one
// whose bytes don't decode is left out on every peer alike). Valid until the tick returns:
//
//   for sent in sim.commands(t, player) {
//       switch command in sent { case Cmd_Pick: ... }
//   }
commands :: proc(tick: ^Tick($G), player: Player) -> []part(G, GAME_CMD) {
	slot := player_slot_of_tick(tick, player)
	return commands_of_slot(tick.commands, slot) if slot >= 0 else nil
}

// A join record for a test or a script: `member` (the relay's id, >= 1) becomes present in `slot` this tick.
join :: proc(inputs: ^Inputs($G), slot: int, member: int) {
	assert(slot >= 0 && slot < part(G, GAME_PLAYERS) && member >= 1 && member <= 0xFFFF)
	inputs.present += {slot}
	inputs.member[slot] = u16(member)
}

// The changes of a tick's presence, for Tick.player_changes.
@(private)
Changes_Buffer :: struct($PLAYERS: int) {
	arrived, joined, left:                   [PLAYERS]Player,
	arrived_count, joined_count, left_count: int,
}

// Applies a tick's presence and join records to the State's Players before the game's `tick` (the harness, step):
// leaves first (a slot no longer present, or present with another member's join record), then joins in slot order
// (a slot that becomes present with a join record; without one it stays absent). Emits the join and leave events.
@(private)
players_update :: proc(tick: ^Tick($G), changes: ^Changes_Buffer($PLAYERS)) {
	players := &tick.state.players
	inputs := tick.inputs
	changes^ = {}
	for slot in 0 ..< PLAYERS {
		holder := players.slots[slot]
		record := inputs.member[slot]
		if holder.id == 0 || (slot in inputs.present && (record == 0 || record == holder.id)) {
			continue
		}
		players_leave(tick, slot, changes)
	}
	for slot in 0 ..< PLAYERS {
		record := inputs.member[slot]
		if record == 0 || slot not_in inputs.present || players.slots[slot].id != 0 {
			continue
		}
		for other in 0 ..< slot {
			// read_joins refuses it; two would leave one slot twice, past changes.left
			assert(other not_in inputs.present || inputs.member[other] != record, "one member in two join records")
		}
		index := -1
		for member, i in players.members {
			if member.id == record {
				index = i
				break
			}
		}
		returning := index >= 0
		if returning {
			if elsewhere := players.members[index].slot; elsewhere != NO_SLOT {
				players_leave(tick, int(elsewhere), changes) // the same person in two slots: the newest
			}
		} else {
			index = players_entry(players, tick.number)
			if index < 0 {
				continue // no entry to give: the slot stays absent (only a script's leave and join in one tick)
			}
			players.members[index] = {
				id = record,
			}
			players.data[index] = {}
		}
		member := &players.members[index]
		member.slot = u8(slot)
		member.since = tick.number
		players.before[slot] = {} // nothing held before their first tick here
		player := Player{u16(index), record}
		players.slots[slot] = player
		changes.arrived[changes.arrived_count] = player
		changes.arrived_count += 1
		if !returning {
			changes.joined[changes.joined_count] = player
			changes.joined_count += 1
		}
		emit(tick, Event_Player_Joined{player = player, slot = u8(slot), returning = returning})
	}
}

// After `tick`: each slot's input becomes its `before` for the next tick (zero for a slot nobody holds).
@(private)
players_remember :: proc(players: ^Players($T, $Input, $PLAYERS), inputs: ^Inputs($G)) {
	for slot in 0 ..< PLAYERS {
		players.before[slot] = inputs.input[slot] if players.slots[slot].id != 0 else {}
	}
}

@(private)
players_leave :: proc(tick: ^Tick($G), slot: int, changes: ^Changes_Buffer($PLAYERS)) {
	players := &tick.state.players
	holder := players.slots[slot]
	member := &players.members[holder.index]
	member.slot = NO_SLOT
	member.since = tick.number
	players.slots[slot] = {}
	changes.left[changes.left_count] = holder
	changes.left_count += 1
	emit(tick, Event_Player_Left{player = holder, slot = u8(slot)})
}

// The entry for a new member: the first free one, else the longest-absent member's (the lowest `since`; ties: the
// lowest index), -1 when there is none. A member who left on this tick is never forgotten on it: its handle in
// t.player_changes.left must still name its data while the game cleans up. (The relay never needs it: a slot it seats
// was free on the tick before, so the members present then and the free or longer-absent entries always cover the
// joins.)
@(private)
players_entry :: proc(players: ^Players($T, $Input, $PLAYERS), number: u32) -> int {
	oldest := -1
	for member, i in players.members {
		if member.id == 0 {
			return i
		}
		if member.slot == NO_SLOT &&
		   member.since != number &&
		   (oldest < 0 || member.since < players.members[oldest].since) {
			oldest = i
		}
	}
	return oldest
}
