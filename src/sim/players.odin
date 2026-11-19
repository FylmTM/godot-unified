// Players (src/sim/README.md, Players): a slot is an input index 0 ..< PLAYERS; a player is a session member, the
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

// Who is in the session: the State's field `players` (sim.Game's where clause checks it), `sim.Players(T, Profile,
// Input, PLAYERS)`. The session remembers 2 x PLAYERS people (MEMBERS_PER_SLOT): a newcomer to a full table takes the
// entry of the longest-absent member, whose handles go stale and who is new if they come back. `before` is each slot's
// Input of the tick before (input_before: presses are the difference), kept in the state so a rollback, a snapshot and
// a replay carry it. `profile` is each member's Profile, the one its last join brought (player_profile; zero bytes for
// sim.No_Profile). The pads keep `before`, `profile` and `data` 8-aligned.
Players :: struct(
	$T: typeid,
	$Profile: typeid,
	$Input: typeid,
	$PLAYERS: int,
) where PLAYERS >= 1 &&
	PLAYERS <= MAX_PLAYERS {
	members: [PLAYERS * MEMBERS_PER_SLOT]Member,
	slots:   [PLAYERS]Player, // who holds each slot (Player{}: nobody)
	_pad:    [PLAYERS % 2 * 4]u8,
	before:  [PLAYERS]Input, // each slot's input of the tick before (zero on its holder's first tick; while absent)
	_pad2:   [(8 - PLAYERS * size_of(Input) % 8) % 8]u8,
	profile: [PLAYERS * MEMBERS_PER_SLOT]Profile, // by member index: what its last join brought
	_pad3:   [(8 - PLAYERS * MEMBERS_PER_SLOT * size_of(Profile) % 8) % 8]u8,
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

// The player queries below each take the tick being computed (`sim.player_data(t, player)`), a State's Players
// (`sim.player_data(&state.players, player)`: views) or a simulation (its current state: tests, drivers outside
// `tick`).

// The player's data, or nil when the handle is nobody, stale or forgotten; valid while the player is absent. Of the
// tick being computed, a State's Players or a simulation's current state.
player_data :: proc {
	player_data_of_players,
	player_data_of_tick,
	player_data_of_sim,
}

player_data_of_players :: proc(players: ^Players($T, $Profile, $Input, $PLAYERS), player: Player) -> ^T {
	return &players.data[player.index] if player_known(players, player) else nil
}

// The result is the T of the State's `players: sim.Players(T, Profile, Input, PLAYERS)`.
player_data_of_tick :: proc(
	tick: ^Tick($G),
	player: Player,
) -> ^part(intrinsics.type_field_type(part(G, GAME_STATE), "players"), 0) {
	return player_data_of_players(&tick.state.players, player)
}

player_data_of_sim :: proc(
	simulation: ^Sim($G),
	player: Player,
) -> ^part(intrinsics.type_field_type(part(G, GAME_STATE), "players"), 0) {
	return player_data_of_players(&simulation.state.players, player)
}

// The Profile the player's last join brought (the zero Profile when the handle is nobody, stale or forgotten); valid
// while the player is absent. A returning member brings a Profile again (they may have picked another character): a
// game that keeps the first one copies it into its T on `joined`. Of the tick being computed, a State's Players or a
// simulation's current state.
player_profile :: proc {
	player_profile_of_players,
	player_profile_of_tick,
	player_profile_of_sim,
}

player_profile_of_players :: proc(players: ^Players($T, $Profile, $Input, $PLAYERS), player: Player) -> Profile {
	return players.profile[player.index] if player_known(players, player) else {}
}

player_profile_of_tick :: proc(tick: ^Tick($G), player: Player) -> part(G, GAME_PROFILE) {
	return player_profile_of_players(&tick.state.players, player)
}

player_profile_of_sim :: proc(simulation: ^Sim($G), player: Player) -> part(G, GAME_PROFILE) {
	return player_profile_of_players(&simulation.state.players, player)
}

// Whether the handle names a member the table still remembers (present or absent).
player_known :: proc {
	player_known_of_players,
	player_known_of_tick,
	player_known_of_sim,
}

player_known_of_players :: proc(players: ^Players($T, $Profile, $Input, $PLAYERS), player: Player) -> bool {
	return player.id != 0 && int(player.index) < len(players.members) && players.members[player.index].id == player.id
}

player_known_of_tick :: proc(tick: ^Tick($G), player: Player) -> bool {
	return player_known_of_players(&tick.state.players, player)
}

player_known_of_sim :: proc(simulation: ^Sim($G), player: Player) -> bool {
	return player_known_of_players(&simulation.state.players, player)
}

// The slot the player holds this tick, or -1 (and false) when absent or unknown: `slot := sim.player_slot(t, player)`.
player_slot :: proc {
	player_slot_of_players,
	player_slot_of_tick,
	player_slot_of_sim,
}

player_slot_of_players :: proc(
	players: ^Players($T, $Profile, $Input, $PLAYERS),
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

player_slot_of_sim :: proc(simulation: ^Sim($G), player: Player) -> (slot: int, present: bool) #optional_ok {
	return player_slot_of_players(&simulation.state.players, player)
}

// Whether the player holds a slot this tick.
player_present :: proc {
	player_present_of_players,
	player_present_of_tick,
	player_present_of_sim,
}

player_present_of_players :: proc(players: ^Players($T, $Profile, $Input, $PLAYERS), player: Player) -> bool {
	_, present := player_slot_of_players(players, player)
	return present
}

player_present_of_tick :: proc(tick: ^Tick($G), player: Player) -> bool {
	return player_present_of_players(&tick.state.players, player)
}

player_present_of_sim :: proc(simulation: ^Sim($G), player: Player) -> bool {
	return player_present_of_players(&simulation.state.players, player)
}

// Who holds `slot` (Player{}: nobody, or a slot out of range); also of a simulation's current state, for drivers
// outside `tick` (a scripted run adds a join record only for a slot nobody holds).
player_in_slot :: proc {
	player_in_slot_of_players,
	player_in_slot_of_tick,
	player_in_slot_of_sim,
}

player_in_slot_of_players :: proc(players: ^Players($T, $Profile, $Input, $PLAYERS), slot: int) -> Player {
	return players.slots[slot] if slot >= 0 && slot < PLAYERS else {}
}

player_in_slot_of_tick :: proc(tick: ^Tick($G), slot: int) -> Player {
	return player_in_slot_of_players(&tick.state.players, slot)
}

player_in_slot_of_sim :: proc(simulation: ^Sim($G), slot: int) -> Player {
	return player_in_slot_of_players(&simulation.state.players, slot)
}

// The data of whoever holds `slot` (nil: nobody): a HUD's row, a test's look at a slot; of the tick being computed, a
// State's Players or a simulation's current state.
slot_data :: proc {
	slot_data_of_players,
	slot_data_of_tick,
	slot_data_of_sim,
}

slot_data_of_players :: proc(players: ^Players($T, $Profile, $Input, $PLAYERS), slot: int) -> ^T {
	return player_data_of_players(players, player_in_slot_of_players(players, slot))
}

// The result is the T of the State's `players: sim.Players(T, Profile, Input, PLAYERS)`.
slot_data_of_tick :: proc(
	tick: ^Tick($G),
	slot: int,
) -> ^part(intrinsics.type_field_type(part(G, GAME_STATE), "players"), 0) {
	return slot_data_of_players(&tick.state.players, slot)
}

slot_data_of_sim :: proc(
	simulation: ^Sim($G),
	slot: int,
) -> ^part(intrinsics.type_field_type(part(G, GAME_STATE), "players"), 0) {
	return slot_data_of_players(&simulation.state.players, slot)
}

// How many players hold a slot this tick.
present_count :: proc {
	present_count_of_players,
	present_count_of_tick,
	present_count_of_sim,
}

present_count_of_players :: proc(players: ^Players($T, $Profile, $Input, $PLAYERS)) -> (count: int) {
	for holder in players.slots {
		if holder.id != 0 do count += 1
	}
	return
}

present_count_of_tick :: proc(tick: ^Tick($G)) -> int {
	return present_count_of_players(&tick.state.players)
}

present_count_of_sim :: proc(simulation: ^Sim($G)) -> int {
	return present_count_of_players(&simulation.state.players)
}

// A walk over the players with their data (iterate_present or iterate_known, then next):
//
//   players := sim.iterate_present(t)
//   for data, player in sim.next(&players) { ... }
Players_Iterator :: struct($T: typeid, $Profile: typeid, $Input: typeid, $PLAYERS: int) {
	players: ^Players(T, Profile, Input, PLAYERS),
	index:   int, // the next slot (present) or member (known) to look at
	known:   bool,
}

// Starts a walk over the present players, in slot order, of the tick being computed, a State's Players or a
// simulation's current state.
iterate_present :: proc {
	iterate_present_of_players,
	iterate_present_of_tick,
	iterate_present_of_sim,
}

// Starts a walk over every member the table remembers, present or absent, in member order, of the tick being
// computed, a State's Players or a simulation's current state.
iterate_known :: proc {
	iterate_known_of_players,
	iterate_known_of_tick,
	iterate_known_of_sim,
}

iterate_present_of_players :: #force_inline proc(
	players: ^Players($T, $Profile, $Input, $PLAYERS),
) -> Players_Iterator(T, Profile, Input, PLAYERS) {
	return {players = players}
}

// The pinned odinfmt puts a comma after a multi-line return type, which does not parse.
// odinfmt: disable
iterate_present_of_tick :: #force_inline proc(
	tick: ^Tick($G),
) -> Players_Iterator(
		part(intrinsics.type_field_type(part(G, GAME_STATE), "players"), 0),
		part(G, GAME_PROFILE),
		part(G, GAME_INPUT),
		part(G, GAME_PLAYERS),
	) {
	return {players = &tick.state.players}
}
// odinfmt: enable

iterate_known_of_players :: #force_inline proc(
	players: ^Players($T, $Profile, $Input, $PLAYERS),
) -> Players_Iterator(T, Profile, Input, PLAYERS) {
	return {players = players, known = true}
}

// odinfmt: disable
iterate_known_of_tick :: #force_inline proc(
	tick: ^Tick($G),
) -> Players_Iterator(
		part(intrinsics.type_field_type(part(G, GAME_STATE), "players"), 0),
		part(G, GAME_PROFILE),
		part(G, GAME_INPUT),
		part(G, GAME_PLAYERS),
	) {
	return {players = &tick.state.players, known = true}
}

iterate_present_of_sim :: #force_inline proc(
	simulation: ^Sim($G),
) -> Players_Iterator(
		part(intrinsics.type_field_type(part(G, GAME_STATE), "players"), 0),
		part(G, GAME_PROFILE),
		part(G, GAME_INPUT),
		part(G, GAME_PLAYERS),
	) {
	return {players = &simulation.state.players}
}

iterate_known_of_sim :: #force_inline proc(
	simulation: ^Sim($G),
) -> Players_Iterator(
		part(intrinsics.type_field_type(part(G, GAME_STATE), "players"), 0),
		part(G, GAME_PROFILE),
		part(G, GAME_INPUT),
		part(G, GAME_PLAYERS),
	) {
	return {players = &simulation.state.players, known = true}
}
// odinfmt: enable

players_next :: #force_inline proc(
	iterator: ^Players_Iterator($T, $Profile, $Input, $PLAYERS),
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

// A join record for a test or a script: `member` (the relay's id, >= 1) becomes present in `slot` this tick, bringing
// `profile` (the zero Profile when left out; sim.join(&inputs, 0, 1, Profile{character = .Tank})).
join :: proc {
	join_plain,
	join_with_profile,
}

// join with the zero Profile.
join_plain :: proc(inputs: ^Inputs($G), slot: int, member: int) {
	join_with_profile(inputs, slot, member, part(G, GAME_PROFILE){})
}

// join bringing `profile`.
join_with_profile :: proc(inputs: ^Inputs($G), slot: int, member: int, profile: $P) where P == part(G, GAME_PROFILE) {
	assert(slot >= 0 && slot < part(G, GAME_PLAYERS) && member >= 1 && member <= 0xFFFF)
	inputs.present += {slot}
	inputs.joins[slot] = u16(member)
	inputs.profiles[slot] = profile
}

// `member` holds `slot` in the tick `inputs` is for (tests, tools and bots that keep members seated tick after tick):
// the slot is present, with a join record (bringing `profile`) only when someone else holds it in the state the tick
// steps from (a simulation's current one, or a State's Players). Present without a join record, a slot nobody holds
// stays empty: seat is the way that can't happen.
seat :: proc {
	seat_of_players,
	seat_of_players_with_profile,
	seat_of_sim,
	seat_of_sim_with_profile,
}

seat_of_players :: proc(
	inputs: ^Inputs($G),
	players: ^Players($T, $Profile, $Input, $PLAYERS),
	slot: int,
	member: int,
) {
	seat_of_players_with_profile(inputs, players, slot, member, Profile{})
}

seat_of_players_with_profile :: proc(
	inputs: ^Inputs($G),
	players: ^Players($T, $Profile, $Input, $PLAYERS),
	slot: int,
	member: int,
	profile: Profile,
) {
	if int(player_in_slot_of_players(players, slot).id) != member {
		join_with_profile(inputs, slot, member, profile)
	} else {
		inputs.present += {slot}
	}
}

seat_of_sim :: proc(inputs: ^Inputs($G), simulation: ^Sim(G), slot: int, member: int) {
	seat_of_players(inputs, &simulation.state.players, slot, member)
}

seat_of_sim_with_profile :: proc(inputs: ^Inputs($G), simulation: ^Sim(G), slot: int, member: int, profile: $P) {
	seat_of_players_with_profile(inputs, &simulation.state.players, slot, member, profile)
}

// The changes of a tick's presence, for Tick.player_changes.
@(private)
Changes_Buffer :: struct($PLAYERS: int) {
	arrived, joined, left:                   [PLAYERS]Player,
	arrived_count, joined_count, left_count: int,
}

// Applies a tick's presence and join records to the State's Players before the game's `tick` (the harness, step):
// leaves first (a slot no longer present, or present with another member's join record), then joins in slot order
// (a slot that becomes present with a join record; without one it stays absent), each writing the Profile its join
// brought as every peer reads it (profile_as_read). Emits the join and leave events.
@(private)
players_update :: proc(tick: ^Tick($G), changes: ^Changes_Buffer($PLAYERS)) {
	players := &tick.state.players
	inputs := tick.inputs
	changes^ = {}
	for slot in 0 ..< PLAYERS {
		holder := players.slots[slot]
		record := inputs.joins[slot]
		if holder.id == 0 || (slot in inputs.present && (record == 0 || record == holder.id)) {
			continue
		}
		players_leave(tick, slot, changes)
	}
	for slot in 0 ..< PLAYERS {
		record := inputs.joins[slot]
		if record == 0 || slot not_in inputs.present || players.slots[slot].id != 0 {
			continue
		}
		for other in 0 ..< slot {
			// read_joins refuses it; two would leave one slot twice, past changes.left
			assert(other not_in inputs.present || inputs.joins[other] != record, "one member in two join records")
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
		players.profile[index] = profile_as_read(inputs.profiles[slot])
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

// A join's Profile as every peer reads it, since it comes from another machine: a bool reads 0 or 1, a bit_set loses
// the bits of no element, and an enum outside its declared values or a float that is not finite makes it the zero
// Profile (a command's rule, src/sim/README.md: Bytes from another machine). The relay, a prediction, a replay and a
// test read it alike, because the sim reads it, here.
@(private)
profile_as_read :: proc(profile: $Profile) -> Profile {
	when size_of(Profile) == 0 {
		return {}
	} else {
		read := profile
		if _, rejected := wire_fix(&read, type_info_of(Profile), .Command, apply = true); rejected {
			return {}
		}
		return read
	}
}

// After `tick`: each slot's input becomes its `before` for the next tick (zero for a slot nobody holds).
@(private)
players_remember :: proc(players: ^Players($T, $Profile, $Input, $PLAYERS), inputs: ^Inputs($G)) {
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
players_entry :: proc(players: ^Players($T, $Profile, $Input, $PLAYERS), number: u32) -> int {
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
