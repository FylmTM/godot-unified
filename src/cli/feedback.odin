// `feedback`: the notes a dev build writes into the game's Godot user data (an F3 note, a watchdog freeze), listed,
// shown and marked handled, so an agent never guesses where they are.
package cli

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"

// Where a game's notes are, under its user data directory.
FEEDBACK_DIR :: "feedback"
// Where `feedback done` moves a handled note, under FEEDBACK_DIR.
FEEDBACK_DONE_DIR :: "done"
// How much of a note's text `feedback`'s list shows (bytes of its first line).
FEEDBACK_LINE_SHOWN :: 100

// One folder under a game's feedback directory, as `feedback_read` finds it.
Feedback_Note :: struct {
	name:       string, // the folder's name: its local time (20261121-011449[-n]), or freeze-<local time>
	dir:        string,
	kind:       string, // "note", "bug" (sent with the bug tag) or "freeze" (the watchdog's)
	text:       string, // what the player wrote (a freeze: where it froze)
	screenshot: string, // its screenshot.png ("": none)
	recording:  bool, // it holds inputs.unil (and the snapshot.unis it continues), so it replays
	tick:       u32, // the tick shown when it was sent (a freeze: the one being stepped)
	version:    string, // the game's version (note.json; "" for a freeze)
	game:       string, // the name of the game (sim.Game.name: which of its variants) that recorded it (note.json; "": unknown)
	about:      string, // note.json's or freeze.json's text: tick, verified tick, net stats, zones ("": none)
}

@(private)
Feedback_List_Opts :: struct {
	game:     string `args:"pos=0" usage:"the game (default: the only one)"`,
	done:     bool `usage:"the handled notes (in feedback/done/) instead of the open ones"`,
	instance: string `hint:"name" usage:"a drive instance's notes (its own user data, .out/drive/<name>/user/ in the game: what uni drive note saved) instead of the developer's"`,
}

@(private)
Feedback_Show_Opts :: struct {
	note:     string `args:"pos=0,required" hint:"note" usage:"show: the note's folder name, as the list prints it (an open or a handled one)"`,
	game:     string `args:"pos=1" usage:"the game (default: the only one)"`,
	instance: string `hint:"name" usage:"show: a drive instance's note instead of the developer's"`,
}

@(private)
Feedback_Done_Opts :: struct {
	notes:    string `args:"pos=0,required" hint:"note,..." usage:"done: the notes handled, comma-separated: moved to feedback/done/, never deleted"`,
	game:     string `args:"pos=1" usage:"the game (default: the only one)"`,
	instance: string `hint:"name" usage:"done: a drive instance's notes instead of the developer's"`,
}

// `feedback -h`'s details: what a note holds and what to do with one.
@(private)
feedback_details :: proc() -> string {
	return(
		"A dev UI build writes a note when the player presses F3 and sends it, and the watchdog a freeze-<time> folder\n" +
		"when the session thread stops stepping, both into the game's Godot user data (the developer's own: `run` and\n" +
		"`editor` use it; a check's is .out/user/ in the game, a drive instance's .out/drive/<name>/user/, which --instance\n" +
		"<name> reads: what `uni drive note` saved). A note holds note.txt, screenshot.png, note.json and the session's\n" +
		"recording (snapshot.unis, inputs.unil); `show` prints the commands that replay it.\n" +
		"The unified-feedback skill is how an agent handles them." \
	)
}

@(private)
cmd_feedback :: proc(args: []string) -> Result {
	if len(args) > 0 && args[0] == "show" {
		opts: Feedback_Show_Opts
		parse(&opts, args[1:])
		return feedback_show(opts)
	}
	if len(args) > 0 && args[0] == "done" {
		opts: Feedback_Done_Opts
		parse(&opts, args[1:])
		return feedback_done(opts)
	}
	opts: Feedback_List_Opts
	parse(&opts, args)
	return feedback_open(opts)
}

// `feedback`: the notes of the game (or of the drive instance it names), open or handled, newest first.
@(private)
feedback_open :: proc(opts: Feedback_List_Opts) -> Result {
	selected := game(opts.game)
	dir := feedback_dir_of(selected, opts.instance)
	if opts.done do dir = join(dir, FEEDBACK_DONE_DIR)
	notes := feedback_list(dir)
	return {ok = true, summary = feedback_list_text(selected, dir, notes, opts.done, opts.instance), data = box(notes)}
}

// `feedback show`: one note, open or handled, with the commands that replay it; a name that is none stops the command.
@(private)
feedback_show :: proc(opts: Feedback_Show_Opts) -> Result {
	selected := game(opts.game)
	feedback := feedback_dir_of(selected, opts.instance)
	note, ok := feedback_read(join(feedback, opts.note))
	if !ok do note, ok = feedback_read(join(feedback, FEEDBACK_DONE_DIR, opts.note))
	if !ok do fatal("no note %q in %s (uni feedback lists them)", opts.note, feedback)
	return {ok = true, summary = feedback_show_text(selected, note), data = box(note)}
}

// `feedback done`: the notes named moved to the handled ones (feedback_mark_done); a problem stops the command.
@(private)
feedback_done :: proc(opts: Feedback_Done_Opts) -> Result {
	feedback := feedback_dir_of(game(opts.game), opts.instance)
	moved, problem := feedback_mark_done(feedback, split_list(opts.notes))
	if problem != "" do fatal("%s", problem)
	return {
		ok      = true,
		summary = aprintf("moved %s to %s", strings.join(moved, ", "), join(feedback, FEEDBACK_DONE_DIR)),
		data    = box(moved),
	}
}

// The feedback directory `feedback` reads: the developer's (`instance` ""), or that drive instance's; a name that
// can't be an instance's, or an instance that never ran, stops the command.
@(private)
feedback_dir_of :: proc(selected: Game, instance: string) -> string {
	if instance != "" {
		if !replay_name_ok(instance) do usage("--instance %q: a drive instance's name (letters, digits, _ and -)", instance)
		if base := drive_user_base(selected.dir, instance); !os.is_directory(base) {
			fatal(
				"%s has no drive instance %q: no user data in %s (uni drive start --name %s)",
				selected.name,
				instance,
				base,
				instance,
			)
		}
	}
	return feedback_dir(selected.dir, instance)
}

// The feedback directory of the game in `game_dir`: in the developer's own user data (the one `run` and the editor
// use) when `instance` is "", else in that drive instance's (drive_user_base).
feedback_dir :: proc(game_dir: string, instance: string) -> string {
	if instance == "" do return join(game_user_dir(game_dir), FEEDBACK_DIR)
	return join(game_user_dir(game_dir, drive_user_base(game_dir, instance)), FEEDBACK_DIR)
}

// Every note in `dir` (a game's feedback directory, or its done/), newest first; a folder that holds none of a
// note's files is skipped.
feedback_list :: proc(dir: string) -> []Feedback_Note {
	entries, _ := os.read_all_directory_by_path(dir, context.allocator)
	out: [dynamic]Feedback_Note
	for entry in entries {
		if entry.type != .Directory || entry.name == FEEDBACK_DONE_DIR do continue
		if note, ok := feedback_read(join(dir, entry.name)); ok do append(&out, note)
	}
	// a name is its local time, after freeze- for a freeze: newest first, a note's -2 before the one it follows
	slice.sort_by(out[:], proc(a, b: Feedback_Note) -> bool {
		return feedback_sort_key(a.name) > feedback_sort_key(b.name)
	})
	return out[:]
}

@(private)
feedback_sort_key :: proc(name: string) -> string {
	return strings.trim_prefix(name, "freeze-")
}

// One note folder: its text, tag, screenshot, recording and JSON; false when it holds neither note.txt nor a note's
// or freeze's JSON.
feedback_read :: proc(dir: string) -> (note: Feedback_Note, ok: bool) {
	if !os.is_directory(dir) do return
	note.name = os.base(strings.trim_right(dir, "/\\"))
	note.dir = dir
	note.kind = "note"
	About :: struct {
		tick:    u32,
		version: string,
		game:    string,
		in_fill: bool,
		zones:   []string,
	}
	about: About
	text, has_text := read_text(join(dir, "note.txt"))
	json_text, has_json := read_text(join(dir, "note.json"))
	freeze := false
	if !has_json {
		json_text, has_json = read_text(join(dir, "freeze.json"))
		freeze = has_json
	}
	if !has_text && !has_json do return
	if has_json {
		note.about = strings.trim_space(json_text)
		_ = json.unmarshal_string(json_text, &about)
		note.tick, note.version, note.game = about.tick, about.version, about.game
	}
	if has_text {
		// "[note]" or "[bug]", then what the player wrote
		text, _ = strings.replace_all(text, "\r\n", "\n")
		first, _, rest := strings.partition(text, "\n")
		switch strings.trim_space(first) {
		case "[bug]":
			note.kind, note.text = "bug", strings.trim_space(rest)
		case "[note]":
			note.text = strings.trim_space(rest)
		case:
			note.text = strings.trim_space(text)
		}
	}
	if freeze {
		note.kind = "freeze"
		place := about.in_fill ? "in fill_frame" : "in the tick"
		note.text = aprintf("frozen %s", place)
		if len(about.zones) > 0 {
			note.text = aprintf("%s: %s", note.text, strings.join(about.zones, " > "))
		}
	}
	if shot := join(dir, "screenshot.png"); os.is_file(shot) do note.screenshot = shot
	note.recording = os.is_file(join(dir, "inputs.unil"))
	return note, true
}

// Moves each named note of the `feedback` directory into its done/ (a name already there gets -2, -3, ...); returns
// the names moved, or why it moved none: every name is checked before anything moves.
feedback_mark_done :: proc(feedback: string, names: []string) -> (moved: []string, problem: string) {
	if len(names) == 0 do return nil, "name the notes handled"
	for name in names {
		if name == FEEDBACK_DONE_DIR || strings.contains_any(name, "/\\") {
			return nil, aprintf("%q is not a note's folder name", name)
		}
		if _, ok := feedback_read(join(feedback, name)); !ok {
			if os.is_directory(join(feedback, FEEDBACK_DONE_DIR, name)) {
				return nil, aprintf("%s is already handled (in %s)", name, join(feedback, FEEDBACK_DONE_DIR))
			}
			return nil, aprintf("no note %q in %s", name, feedback)
		}
	}
	done := join(feedback, FEEDBACK_DONE_DIR)
	make_dirs(done)
	out: [dynamic]string
	for name in names {
		target := join(done, name)
		for n := 2; os.exists(target); n += 1 do target = join(done, aprintf("%s-%d", name, n))
		if err := os.rename(join(feedback, name), target); err != nil {
			return out[:], aprintf("cannot move %s to %s: %v", name, target, err)
		}
		append(&out, name)
	}
	return out[:], ""
}

// `feedback`'s list: a line per note, newest first.
@(private)
feedback_list_text :: proc(
	selected: Game,
	dir: string,
	notes: []Feedback_Note,
	done: bool,
	instance: string,
) -> string {
	what := done ? "handled notes" : "open notes"
	if len(notes) == 0 do return aprintf("no %s of %s in %s", what, selected.name, dir)
	builder := strings.builder_make()
	fmt.sbprintf(
		&builder,
		"%d %s of %s in %s, newest first (uni feedback show <note>%s):",
		len(notes),
		what,
		selected.name,
		dir,
		instance != "" ? aprintf(" --instance %s", instance) : "",
	)
	for note in notes {
		line, _, _ := strings.partition(note.text, "\n")
		if len(line) > FEEDBACK_LINE_SHOWN do line = aprintf("%s...", line[:FEEDBACK_LINE_SHOWN])
		fmt.sbprintf(
			&builder,
			"\n  %-24s %-6s tick %-7d %-12s %s",
			note.name,
			note.kind,
			note.tick,
			note.recording ? "recording" : "no recording",
			line,
		)
	}
	return strings.to_string(builder)
}

// `feedback show`'s text: the note, its files, and the commands that replay it.
@(private)
feedback_show_text :: proc(selected: Game, note: Feedback_Note) -> string {
	builder := strings.builder_make()
	fmt.sbprintf(&builder, "%s: %s at tick %d", note.name, note.kind, note.tick)
	if note.version != "" do fmt.sbprintf(&builder, ", version %s", note.version)
	fmt.sbprintf(&builder, "\n\n%s\n\nfolder:     %s", note.text != "" ? note.text : "(no text)", note.dir)
	fmt.sbprintf(&builder, "\nscreenshot: %s", note.screenshot != "" ? note.screenshot : "(none)")
	if note.recording {
		// the game's name only where a command needs it: a game repo holds one game
		name := len(state.project.games) > 1 ? aprintf(" %s", selected.name) : ""
		snapshot := join(note.dir, "snapshot.unis")
		snapshot_arg := os.is_file(snapshot) ? aprintf(" --snapshot \"%s\"", snapshot) : ""
		// the variant that recorded it: a headless binary plays another by default (a stress tuning), whose build
		// identity the log's is not
		game_arg := note.game != "" ? aprintf(" --game %s", note.game) : ""
		fmt.sbprintf(
			&builder,
			"\nreplay it headless (checked against its checkpoints): ./uni headless%s -- replay%s%s --log \"%s\"",
			name,
			game_arg,
			snapshot_arg,
			join(note.dir, "inputs.unil"),
		)
		fmt.sbprintf(
			&builder,
			"\nwatch it in the game (paused on its tick; shot, state): ./uni drive%s start -- --replay \"%s\"",
			name,
			note.dir,
		)
		fmt.sbprintf(
			&builder,
			"\nkeep it as a replay regression: its inputs.unil%s copied into %s/, then ./uni test%s --bless",
			snapshot_arg != "" ? " and snapshot.unis" : "",
			replay_folder(selected.dir, "<name>"),
			name,
		)
	} else {
		fmt.sbprintf(&builder, "\nno recording: it doesn't replay")
	}
	if note.about != "" do fmt.sbprintf(&builder, "\n\n%s", note.about)
	return strings.to_string(builder)
}

// A game's Godot user data directory (its user://) on this OS, named as Godot names it from project.godot: the
// developer's own, or under `base` (godot_user_dir's).
game_user_dir :: proc(game_dir: string, base := "") -> string {
	config, _ := config_load(join(game_dir, "project.godot"))
	name, _ := config_get(config, "application", "config/name")
	name = godot_safe_dir_name(name, false)
	if name == "" do return join(godot_user_dir(base), "app_userdata", "[unnamed project]")
	custom, _ := config_get(config, "application", "config/use_custom_user_dir")
	if custom != "true" do return join(godot_user_dir(base), "app_userdata", name)
	custom_name, _ := config_get(config, "application", "config/custom_user_dir_name")
	custom_name = godot_safe_dir_name(custom_name, true)
	return join(os_data_dir(base), custom_name != "" ? custom_name : name)
}

// What Godot makes of a project's name for a directory (OS::get_safe_dir_name): `: * ? " < > |` (and with no
// paths, / and \) become -, the edges trimmed.
godot_safe_dir_name :: proc(name: string, allow_paths: bool) -> string {
	out := name
	if allow_paths do out = slashed(out)
	invalid := allow_paths ? `:*?"<>|` : `:*?"<>|/\`
	for c in invalid {
		out, _ = strings.replace_all(out, fmt.tprintf("%c", c), "-")
	}
	return strings.trim_space(out)
}
