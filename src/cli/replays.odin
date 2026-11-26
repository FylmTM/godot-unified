// A game's replay regressions (src/headless/README.md, Replay regressions) as `coop --record` keeps them: a session
// recording's files put into a replay folder with the arguments that recorded it, and put back as they were when the
// game's tests refuse the new recording, so a folder only ever holds a recording that passed.
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

// A replay folder's files as they were before replay_install changed them: what replay_restore puts back.
Replay_Backup :: struct {
	folder: string,
	made:   bool, // replay_install made the folder: replay_restore removes it again
	files:  [dynamic]Replay_Saved,
}

// One file of a Replay_Backup: its bytes, or that it wasn't there.
Replay_Saved :: struct {
	name:    string,
	data:    []byte,
	existed: bool,
}

// Whether `name` can name a replay folder: a plain directory name, nothing a path could climb out with.
replay_name_ok :: proc(name: string) -> bool {
	if name == "" || name == "." || name == ".." do return false
	return strings.index_any(name, "/\\:") < 0
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
// goes and REPLAY_ARGS_FILE holds `args`. Returns what the folder held before (replay_restore), or why nothing changed.
replay_install :: proc(folder, recording: string, args: []string) -> (backup: Replay_Backup, problem: string) {
	inputs, inputs_err := os.read_entire_file(join(recording, REPLAY_INPUTS), context.allocator)
	if inputs_err != nil do return {}, aprintf("%s holds no %s", recording, REPLAY_INPUTS)
	snapshot, snapshot_err := os.read_entire_file(join(recording, REPLAY_SNAPSHOT), context.allocator)
	backup.folder, backup.made = folder, !os.is_directory(folder)
	for name in ([]string{REPLAY_INPUTS, REPLAY_SNAPSHOT, REPLAY_EXPECTED, REPLAY_ARGS_FILE}) {
		data, err := os.read_entire_file(join(folder, name), context.allocator)
		append(&backup.files, Replay_Saved{name = name, data = data, existed = err == nil})
	}
	lines := strings.join(args, "\n")
	written :=
		write_file(join(folder, REPLAY_INPUTS), inputs) &&
		write_file(join(folder, REPLAY_ARGS_FILE), transmute([]byte)aprintf("%s\n", lines))
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

// Puts a replay folder's files back as replay_install found them (a file that wasn't there goes again).
replay_restore :: proc(backup: Replay_Backup) {
	for saved in backup.files {
		path := join(backup.folder, saved.name)
		if saved.existed {
			if !write_file(path, saved.data) do log("uni: cannot put back %s", path)
		} else {
			os.remove(path)
		}
	}
	if backup.made do os.remove(backup.folder)
}
