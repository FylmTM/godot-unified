// A game's replay regressions (src/headless/README.md, Replay regressions) as `coop --record` keeps them: a session
// recording's files put into a replay folder with the arguments that recorded it, checked, and put back as they were
// when the check refuses the new recording (or the command fails, or is killed), so a folder only ever holds a
// recording that passed.
package cli

import "core:os"
import "core:strings"

// Where a game keeps its replay regressions, under its directory.
REPLAYS_DIR :: "simulation/tests/replays"
// The file in a replay folder holding the `uni coop` arguments that recorded it, one per line (`coop --rerecord`).
REPLAY_ARGS_FILE :: "coop.args"
// The files a replay folder holds: the recording's (its inputs, the snapshot they continue) and the expectation a bless
// writes beside them, which a new recording makes stale.
REPLAY_INPUTS :: "inputs.unil"
REPLAY_SNAPSHOT :: "snapshot.unis"
REPLAY_EXPECTED :: "expected.unie"
// Every file replay_install may change, so every file replay_restore puts back.
REPLAY_FILES :: [?]string{REPLAY_INPUTS, REPLAY_SNAPSHOT, REPLAY_EXPECTED, REPLAY_ARGS_FILE}
// Where a game's .out keeps the folders' originals while a --record runs (a directory per replay), and the file in
// each that names the folder it came from (its path, then 1 when replay_install made the folder).
REPLAY_BACKUPS :: "record"
REPLAY_MANIFEST :: "folder.txt"

// A replay folder replay_install changed, and the directory holding what it held before: on disk, so a killed run's
// change is put back by the next one (replay_restore_killed).
Replay_Backup :: struct {
	folder:  string,
	backups: string,
}

// Whether `name` can name a replay folder: letters, digits, _ and - only, so it is never a path.
replay_name_ok :: proc(name: string) -> bool {
	if name == "" do return false
	for c in name {
		ok := (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '-'
		if !ok do return false
	}
	return true
}

// The replay folder `name` of the game in `game_dir`.
replay_folder :: proc(game_dir, name: string) -> string {
	return join(game_dir, REPLAYS_DIR, name)
}

// The `uni coop` arguments that recorded the replay in `folder` (its REPLAY_ARGS_FILE, a line each; blank lines
// skipped); false when it has none.
replay_args :: proc(folder: string) -> (args: []string, found: bool) {
	text := read_text(join(folder, REPLAY_ARGS_FILE)) or_return
	out: [dynamic]string
	for line in strings.split_lines(text) {
		trimmed := strings.trim_right(line, "\r")
		if strings.trim_space(trimmed) != "" do append(&out, trimmed)
	}
	return out[:], true
}

// Makes the recording in `recording` (a session recording's folder: its inputs.unil, and the snapshot.unis it
// continues, if any) the replay in `folder` (made when missing): its files replace the folder's, the stale expectation
// goes and REPLAY_ARGS_FILE holds `args`. What the folder held is kept under `backups` first (a killed run's left
// there is put back before). Returns the backup (replay_restore, replay_keep), or why nothing changed.
replay_install :: proc(folder, recording: string, args: []string, backups: string) -> (Replay_Backup, string) {
	inputs, inputs_err := os.read_entire_file(join(recording, REPLAY_INPUTS), context.allocator)
	if inputs_err != nil do return {}, aprintf("%s holds no %s", recording, REPLAY_INPUTS)
	snapshot, snapshot_err := os.read_entire_file(join(recording, REPLAY_SNAPSHOT), context.allocator)
	backup := Replay_Backup{folder, backups}
	replay_restore(backup) // a killed run's change, before this one's backup
	made := !os.is_directory(folder)
	saved := write_file(join(backups, REPLAY_MANIFEST), transmute([]byte)aprintf("%s\n%d\n", folder, made ? 1 : 0))
	for name in REPLAY_FILES {
		if data, err := os.read_entire_file(join(folder, name), context.allocator); err == nil {
			saved = saved && write_file(join(backups, name), data)
		}
	}
	if !saved {
		remove_tree(backups)
		return {}, aprintf("cannot back up %s in %s", folder, backups)
	}
	written :=
		write_file(join(folder, REPLAY_INPUTS), inputs) &&
		write_file(join(folder, REPLAY_ARGS_FILE), transmute([]byte)aprintf("%s\n", strings.join(args, "\n")))
	if written && snapshot_err == nil {
		written = write_file(join(folder, REPLAY_SNAPSHOT), snapshot)
	} else if written {
		os.remove(join(folder, REPLAY_SNAPSHOT)) // a recording from tick 0 continues none: the old one would be read
	}
	os.remove(join(folder, REPLAY_EXPECTED))
	if !written {
		replay_restore(backup)
		return {}, aprintf("cannot write the recording into %s", folder)
	}
	return backup, ""
}

// Puts the folder back as replay_install found it, from its backups (a file that wasn't there goes again, a folder it
// made goes), and drops them; true when it put anything back. Again, or with no backups: nothing to do.
replay_restore :: proc(backup: Replay_Backup) -> bool {
	manifest, found := read_text(join(backup.backups, REPLAY_MANIFEST))
	if !found do return false
	lines := strings.split_lines(manifest)
	for name in REPLAY_FILES {
		path := join(backup.folder, name)
		if data, err := os.read_entire_file(join(backup.backups, name), context.allocator); err == nil {
			if !write_file(path, data) do log("uni: cannot put back %s", path)
		} else {
			os.remove(path)
		}
	}
	if len(lines) > 1 && strings.trim_space(lines[1]) == "1" do os.remove(backup.folder) // only when empty
	remove_tree(backup.backups)
	return true
}

// Keeps the new recording: drops the backups, so nothing puts the folder back.
replay_keep :: proc(backup: Replay_Backup) {
	remove_tree(backup.backups)
}

// Puts back every folder a killed --record left changed: each directory under `dir` (a game's .out/record) that names
// one (replay_restore); returns those folders.
replay_restore_killed :: proc(dir: string) -> []string {
	out: [dynamic]string
	entries, _ := os.read_all_directory_by_path(dir, context.allocator)
	for entry in entries {
		if entry.type != .Directory do continue
		manifest := read_text(join(entry.fullpath, REPLAY_MANIFEST)) or_continue
		folder := strings.trim_space(strings.split_lines(manifest)[0])
		if folder != "" && replay_restore({folder, entry.fullpath}) do append(&out, folder)
	}
	return out[:]
}

// A check of a new recording in its replay folder (`coop --record`'s: the game's tests, narrowed to bless that folder
// alone): `game` and `folder`, the result.
Replay_Check :: proc(game, folder: string) -> Result

// Records `recording` as the replay in `folder` (replay_install, with `args` and its backups under `backups`), then
// `check`s it: it is kept only when the check passes and wrote the folder's expectation (a check that passed without
// one checked nothing). Refused, the folder is put back as it was. A command that may fail or `fatal` meanwhile
// registers replay_restore of {folder, backups} with on_failure first (it does nothing once this has returned), and a
// killed run's is put back by the next (replay_restore_killed).
replay_record :: proc(
	game, folder, recording: string,
	args: []string,
	backups: string,
	check: Replay_Check,
) -> Result {
	backup, problem := replay_install(folder, recording, args, backups)
	if problem != "" do return {ok = false, summary = problem}
	log("uni: %s holds the new recording (%s); checking it", folder, recording)
	checked := check(game, folder)
	if checked.ok && !os.exists(join(folder, REPLAY_EXPECTED)) {
		checked = {
			ok      = false,
			summary = aprintf("the check wrote no %s: nothing checked the recording", REPLAY_EXPECTED),
		}
	}
	if !checked.ok {
		replay_restore(backup)
		log("uni: put back %s as it was; the refused recording: %s", folder, recording)
		return {
			ok      = false,
			summary = aprintf("the new recording was refused (%s); %s is as it was", checked.summary, folder),
		}
	}
	replay_keep(backup)
	return {ok = true, summary = aprintf("%s holds the new recording, checked", folder)}
}
