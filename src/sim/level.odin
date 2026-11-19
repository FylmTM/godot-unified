// Levels (src/sim/README.md, Levels): a game's levels, embedded and named, and the active one as a value in the block.
package sim

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:strings"

// Why a game's levels and its State don't fit ("" when they do; temp-allocated): a State with an Active_Level field
// must name it `level`, and have one; more than one level needs one; and its enum must list the levels in
// Game.levels' order: as many members as levels, counting up from 0, member i's name lowercased being levels[i].name
// (the rule level.prop_enum uses), so a list in another order never runs. A game without level files (no
// Game.levels) may still keep an Active_Level of its rules' own levels.
levels_violation :: proc(name: string, state: ^runtime.Type_Info, levels: []Level_File) -> string {
	fields, is_struct := runtime.type_info_base(state).variant.(runtime.Type_Info_Struct)
	if !is_struct do return ""
	found := -1
	for i in 0 ..< int(fields.field_count) {
		named, is_named := fields.types[i].variant.(runtime.Type_Info_Named)
		if !is_named || !strings.has_prefix(named.name, "Active_Level") do continue
		if found >= 0 do return fmt.tprintf("%s: the State has two sim.Active_Level fields", name)
		found = i
		if fields.names[i] != "level" {
			return fmt.tprintf(
				"%s: the State's sim.Active_Level field is `%s`: name it `level`",
				name,
				fields.names[i],
			)
		}
	}
	if found < 0 {
		if len(levels) > 1 {
			return fmt.tprintf(
				"%s: %d levels but no `level: sim.Active_Level(Level_Id)` in the State, so none can be entered",
				name,
				len(levels),
			)
		}
		return ""
	}
	if len(levels) == 0 do return "" // levels of the game's rules only, no files
	level_struct := runtime.type_info_base(fields.types[found]).variant.(runtime.Type_Info_Struct)
	id_type := level_struct.types[1] // since, id, _pad
	members := runtime.type_info_base(id_type).variant.(runtime.Type_Info_Enum)
	if len(members.names) != len(levels) {
		return fmt.tprintf(
			"%s: Game.levels has %d levels, the State's level enum %v %d members: one level per member, in order",
			name,
			len(levels),
			id_type.id,
			len(members.names),
		)
	}
	for member, i in members.names {
		if i64(members.values[i]) != i64(i) {
			return fmt.tprintf("%s: the level enum %v's members must count up from 0 (%s)", name, id_type.id, member)
		}
		if !lowercase_equal(member, levels[i].name) {
			return fmt.tprintf(
				"%s: Game.levels[%d] is %q, the level enum's member %d is %s: the levels go in the enum's order, each named like its member, lowercased",
				name,
				i,
				levels[i].name,
				i,
				member,
			)
		}
	}
	return ""
}

// Whether `lowercase` is `member` with its ASCII letters lowercased.
@(private)
lowercase_equal :: proc(member, lowercase: string) -> bool {
	if len(member) != len(lowercase) do return false
	for i in 0 ..< len(member) {
		char := member[i]
		if char >= 'A' && char <= 'Z' do char += 'a' - 'A'
		if char != lowercase[i] do return false
	}
	return true
}

// One of a game's levels (Game.levels): its name, the lowercased name of its member of the game's level enum
// (`Level_Id.Route` is "route"), and its file's bytes (src/level/README.md), embedded with #load.
Level_File :: struct {
	name:  string,
	bytes: []u8,
}

// Which of the game's levels is active, and since which tick: a field of the State named `level`
// (`level: sim.Active_Level(Level_Id)`), where Level_Id is the game's `enum u8` of its levels in Game.levels' order. Only
// level_enter changes it (physics.level_change for a physics game), so a rollback, a snapshot and a replay carry the
// level like any other state.
Active_Level :: struct($Id: typeid) where intrinsics.type_is_enum(Id) {
	since: u32, // the tick whose step entered it (0: init)
	id:    Id,
	_pad:  [3]u8,
}

// Makes `id` the active level from this tick: `t.state.level = {t.number, id}`. A game without physics calls it in
// init and wherever its rules change level, and reads `Game.levels[id].bytes` itself; a physics game calls
// physics.level_change, which swaps the static geometry and then calls this.
level_enter :: proc(t: ^Tick($G), id: $Id) where intrinsics.type_is_enum(Id) {
	t.state.level = {
		since = t.number,
		id    = id,
	}
}
