// Re-pinning (scenarios.pin_rewrite, scenarios.repin) on a fixture file of pins: only the values that differ are
// rewritten, in place, so the file keeps its formatting; a second re-pin changes nothing; a literal it can't place
// is refused.
package test_scenarios

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

import "unified:headless/scenarios"

@(private = "file")
FIXTURE :: #load("pin_fixture.txt", string)

// REFERENCE's literal as reference_reproduces prints it, but `compat` written as a shorter number (the same value).
@(private = "file")
REFERENCE_OLD :: `REFERENCE :: scenarios.Reference {
	seed          = 7,
	players       = 4,
	ticks         = 1200,
	snapshot_tick = 600,
	checkpoints   = {0x0dd67e932863c420, 0xce2c95c490e0f7e2, 0xbd9943fe8ed36c51, 0x55ec1c1e97ca8a5c},
	trace         = 0xb7b8f72e7b76d55d,
	snapshot      = 0x8a0e92def67cf112,
	log           = 0x8d3c49c4f33a0a11,
	compat        = 0xff,
}`

// The run after a change: another third checkpoint, trace and compat.
@(private = "file")
REFERENCE_NEW :: `REFERENCE :: scenarios.Reference {
	seed          = 7,
	players       = 4,
	ticks         = 1200,
	snapshot_tick = 600,
	checkpoints   = {0x0dd67e932863c420, 0xce2c95c490e0f7e2, 0x0000000000000abc, 0x55ec1c1e97ca8a5c},
	trace         = 0x1234567890abcdef,
	snapshot      = 0x8a0e92def67cf112,
	log           = 0x8d3c49c4f33a0a11,
	compat        = 0x00000000000001ff,
}`

// The fixture with each pair's first text replaced by its second (each once).
@(private = "file")
fixture_with :: proc(pairs: ..[2]string) -> string {
	text := FIXTURE
	for pair in pairs {
		text, _ = strings.replace(text, pair[0], pair[1], 1, context.temp_allocator)
	}
	return text
}

@(test)
a_repin_rewrites_only_the_values_that_differ :: proc(t: ^testing.T) {
	rewritten, changes, found, problem := scenarios.pin_rewrite(FIXTURE, REFERENCE_OLD, REFERENCE_NEW)
	testing.expect_value(t, problem, "")
	testing.expect(t, found)
	want := fixture_with(
		{"0xbd9943fe8ed36c51, 0x55ec", "0x0000000000000abc, 0x55ec"},
		{"trace         = 0xb7b8f72e7b76d55d", "trace         = 0x1234567890abcdef"},
		{"compat        = 0x00000000000000ff", "compat        = 0x00000000000001ff"},
	)
	testing.expect(t, rewritten == want, "every other byte of the file stays")
	testing.expect_value(t, len(changes), 3)
	if len(changes) == 3 {
		testing.expect_value(
			t,
			changes[0],
			scenarios.Pin_Change{"REFERENCE", "checkpoints[2]", "0xbd9943fe8ed36c51", "0x0000000000000abc"},
		)
		testing.expect_value(
			t,
			changes[1],
			scenarios.Pin_Change{"REFERENCE", "trace", "0xb7b8f72e7b76d55d", "0x1234567890abcdef"},
		)
		testing.expect_value(
			t,
			changes[2],
			scenarios.Pin_Change{"REFERENCE", "compat", "0x00000000000000ff", "0x00000000000001ff"},
		)
	}
	// once more: the file holds the new literal, nothing changes
	again, again_changes, again_found, again_problem := scenarios.pin_rewrite(rewritten, REFERENCE_OLD, REFERENCE_NEW)
	testing.expect(t, again == rewritten && len(again_changes) == 0 && again_found && again_problem == "")
	// a literal whose values all stay: found, nothing changes
	same, same_changes, same_found, _ := scenarios.pin_rewrite(FIXTURE, REFERENCE_OLD, REFERENCE_OLD)
	testing.expect(t, same == FIXTURE && len(same_changes) == 0 && same_found)
}

// Arrays by element, a type before the braces written any way, a comment inside, strings.
@(test)
a_repin_names_each_value :: proc(t: ^testing.T) {
	golden_old := "{0x3125e350623f9163, 0x3f3637eb749e2a37, 0xf0d63788ca5d305b, 0xa2fd5716d15ff9f4}"
	golden_new := "{0x3125e350623f9163, 0x0000000000000001, 0xf0d63788ca5d305b, 0xa2fd5716d15ff9f4}"
	_, golden, _, _ := scenarios.pin_rewrite(FIXTURE, golden_old, golden_new)
	testing.expect(t, len(golden) == 1 && golden[0].name == "GOLDEN" && golden[0].value == "[1]")

	rows_old := "{0xcce700a157c5cd2f, 0x4416e4d52d37c953, 0xbd1ba180e414edf9, 0x3db108bf040a1062}"
	rows_new := "{0x0ce700a157c5cd2f, 0x4416e4d52d37c953, 0xbd1ba180e414edf9, 0x3db108bf040a1062}"
	rows_text, rows, _, _ := scenarios.pin_rewrite(FIXTURE, rows_old, rows_new)
	testing.expect(t, len(rows) == 1 && rows[0].name == "GOLDEN_ROWS" && rows[0].value == "[0]")
	testing.expect(
		t,
		rows_text == fixture_with({"0xcce700a157c5cd2f, // the first", "0x0ce700a157c5cd2f, // the first"}),
	)

	library_old := `GOLDEN_LIBRARY :: sim.Library{version = 1, box3d = "3362633-r5"}`
	library_new := `GOLDEN_LIBRARY :: sim.Library{version = 2, box3d = "3362633-r6"}`
	library_text, library, _, _ := scenarios.pin_rewrite(FIXTURE, library_old, library_new)
	testing.expect_value(t, len(library), 2)
	testing.expect(
		t,
		library_text == fixture_with({"version = 1,", "version = 2,"}, {`"3362633-r5"`, `"3362633-r6"`}),
		"the line breaks stay the file's",
	)
	if len(library) == 2 {
		testing.expect_value(t, library[0], scenarios.Pin_Change{"LIBRARY", "version", "1", "2"})
		testing.expect_value(t, library[1], scenarios.Pin_Change{"LIBRARY", "box3d", `"3362633-r5"`, `"3362633-r6"`})
	}
}

@(test)
a_repin_it_cannot_place_is_refused :: proc(t: ^testing.T) {
	// not in the file
	missing_text, _, missing_found, missing_problem := scenarios.pin_rewrite(FIXTURE, "{1, 2}", "{1, 3}")
	testing.expect(t, missing_text == FIXTURE && !missing_found && missing_problem == "")
	// another shape: a field more
	extended, _ := strings.replace(REFERENCE_NEW, "compat ", "extra = 1,\n\tcompat ", 1, context.temp_allocator)
	_, _, _, shape := scenarios.pin_rewrite(FIXTURE, REFERENCE_OLD, extended)
	testing.expect(t, strings.contains(shape, "differ in more than their values"), shape)
	// held twice
	twice := strings.concatenate({
			FIXTURE,
			"\nAGAIN :: [4]u64{0x3125e350623f9163, 0x3f3637eb749e2a37, 0xf0d63788ca5d305b, 0xa2fd5716d15ff9f4}\n",
		}, context.temp_allocator)
	golden_old := "{0x3125e350623f9163, 0x3f3637eb749e2a37, 0xf0d63788ca5d305b, 0xa2fd5716d15ff9f4}"
	unchanged, _, _, twice_problem := scenarios.pin_rewrite(twice, golden_old, "{1, 2, 3, 4}")
	testing.expect(t, unchanged == twice && strings.contains(twice_problem, "more than once"), twice_problem)
}

// repin finds the one file of a directory that holds the literal, writes it, and leaves it alone the second time.
@(test)
a_repin_writes_the_file_that_holds_it :: proc(t: ^testing.T) {
	dir, _ := filepath.join(
		{os.temp_directory(context.temp_allocator) or_else ".", fmt.tprintf("unified-pin-test-%d", os.get_pid())},
		context.temp_allocator,
	)
	_ = os.make_directory_all(dir)
	defer os.remove_all(dir)
	pins, _ := filepath.join({dir, "pins.odin"}, context.temp_allocator)
	other, _ := filepath.join({dir, "other.odin"}, context.temp_allocator)
	_ = os.write_entire_file(pins, transmute([]u8)FIXTURE)
	_ = os.write_entire_file(other, transmute([]u8)string("package fixture\n\nNONE :: [2]u64{1, 2}\n"))
	file, changes, problem := scenarios.repin(dir, REFERENCE_OLD, REFERENCE_NEW)
	testing.expect_value(t, problem, "")
	// By name: repin resolves the directory, and macOS's temp directory is a symlink (/var -> /private/var).
	testing.expect_value(t, filepath.base(file), "pins.odin")
	testing.expect_value(t, len(changes), 3)
	written, _ := os.read_entire_file(pins, context.temp_allocator)
	first, _, _, _ := scenarios.pin_rewrite(FIXTURE, REFERENCE_OLD, REFERENCE_NEW)
	testing.expect(t, string(written) == first, "the file holds the rewrite")
	_, again, again_problem := scenarios.repin(dir, REFERENCE_OLD, REFERENCE_NEW)
	testing.expect(t, len(again) == 0 && again_problem == "", "a second re-pin changes nothing")
	_, _, missing := scenarios.repin(dir, "{1, 2, 3}", "{1, 2, 4}")
	testing.expect(t, strings.contains(missing, "no .odin file"), missing)
}

// A bless's records (scenarios.bless_record_to) go to their file one JSON object per line, appended, with every field
// as given: what `uni test --bless` lists once the run is done.
@(test)
a_bless_appends_one_json_line_per_record :: proc(t: ^testing.T) {
	path, _ := filepath.join({
			os.temp_directory(context.temp_allocator) or_else ".",
			fmt.tprintf("unified-bless-test-%d.jsonl", os.get_pid()),
		}, context.temp_allocator)
	os.remove(path)
	defer os.remove(path)
	first := scenarios.Bless_Record{"reference_reproduces (4 players)", "a/b.odin", "REFERENCE.log", "0x2d", "0x2c"}
	second := scenarios.Bless_Record {
		check = "replays_reproduce",
		file  = "replays/bug_7",
		value = "replays/bug_7",
		new   = `no "expected.unie"`,
	}
	testing.expect(t, scenarios.bless_record_to(path, first))
	testing.expect(t, scenarios.bless_record_to(path, second))
	data, _ := os.read_entire_file(path, context.temp_allocator)
	lines := strings.split_lines(strings.trim_right(string(data), "\n"), context.temp_allocator)
	testing.expect_value(t, len(lines), 2)
	for line, i in lines {
		read: scenarios.Bless_Record
		testing.expect(t, json.unmarshal_string(line, &read, allocator = context.temp_allocator) == nil, line)
		testing.expect_value(t, read, i == 0 ? first : second)
	}
}

// What reference_reproduces does with each kind of move (scenarios.reference_verdict): results that moved on the
// build that pinned them are refused even under --bless; a version bump's moved hashes re-pin under --bless and fail
// without it; a reference without results is unpinned; one pinned before `compat` existed is pasted once.
@(test)
a_reference_verdict_follows_what_moved :: proc(t: ^testing.T) {
	pinned := scenarios.Reference {
		seed          = 7,
		players       = 4,
		ticks         = 1200,
		snapshot_tick = 600,
		checkpoints   = {1, 2, 3, 4},
		trace         = 5,
		snapshot      = 6,
		log           = 7,
		compat        = 8,
	}
	results := pinned
	results.checkpoints[2] = 30
	results.trace = 50
	bumped := results
	bumped.compat = 80
	identity := pinned // a bump that computes the same: only the encodings and the compat move
	identity.snapshot, identity.log, identity.compat = 60, 70, 80
	encoding := pinned // a format change without its version bump: only results are guarded
	encoding.snapshot = 60
	unpinned := scenarios.Reference {
		seed          = 7,
		players       = 4,
		ticks         = 1200,
		snapshot_tick = 600,
	}
	predates := pinned
	predates.compat = 0
	for bless in ([]bool{false, true}) {
		moved: scenarios.Pin_Verdict = bless ? .Repin : .Fail
		testing.expect_value(t, scenarios.reference_verdict(pinned, pinned, bless), scenarios.Pin_Verdict.Same)
		testing.expect_value(t, scenarios.reference_verdict(pinned, results, bless), scenarios.Pin_Verdict.Refuse)
		testing.expect_value(t, scenarios.reference_verdict(pinned, bumped, bless), moved)
		testing.expect_value(t, scenarios.reference_verdict(pinned, identity, bless), moved)
		testing.expect_value(t, scenarios.reference_verdict(pinned, encoding, bless), moved)
		testing.expect_value(t, scenarios.reference_verdict(unpinned, pinned, bless), scenarios.Pin_Verdict.Unpinned)
		testing.expect_value(t, scenarios.reference_verdict(predates, pinned, bless), scenarios.Pin_Verdict.Predates)
	}
}

// A reference never pinned (its parameters alone) is replaced whole (scenarios.pin_first): the token rewrite can't add
// the fields it lacks. Its fields may come in any order, a zero one left out; a literal that sets anything else, or
// another value, is not it; two of them are refused.
@(test)
a_first_pin_replaces_the_placeholder_whole :: proc(t: ^testing.T) {
	parameters := []scenarios.Pin_Field{{"seed", 7}, {"players", 4}, {"ticks", 1200}, {"snapshot_tick", 600}}
	placeholder := "REFERENCE :: scenarios.Reference {\n\tseed          = 7,\n\tplayers       = 4,\n\tticks         = 1200,\n\tsnapshot_tick = 600,\n}"
	source := fmt.tprintf("package fixture\n\n// the run\n%s\n\nOTHER :: 3\n", placeholder)
	rewritten, found, problem := scenarios.pin_first(source, "Reference", parameters, REFERENCE_NEW)
	testing.expect_value(t, problem, "")
	testing.expect(t, found)
	want, _ := strings.replace(source, placeholder, REFERENCE_NEW, 1, context.temp_allocator)
	testing.expect(t, rewritten == want, "the placeholder becomes the literal; every other byte stays")
	// one line, another order, a comment, seed 0 left out
	zero_seed := []scenarios.Pin_Field{{"seed", 0}, {"players", 4}, {"ticks", 1200}, {"snapshot_tick", 600}}
	terse := "R :: Reference{ticks = 1200, /* half */ snapshot_tick = 600, players = 4}\n"
	terse_rewritten, terse_found, _ := scenarios.pin_first(terse, "Reference", zero_seed, REFERENCE_NEW)
	testing.expect(t, terse_found, "any order, a zero field left out")
	testing.expect(t, strings.has_prefix(terse_rewritten, "R :: Reference {\n\tseed          = 7,"), terse_rewritten)
	others := []string {
		"R :: Reference{seed = 7, players = 4, ticks = 1200, snapshot_tick = 600, trace = 1}", // pinned
		"R :: Reference{seed = 8, players = 4, ticks = 1200, snapshot_tick = 600}", // another seed
		"R :: Reference{seed = 7, players = 4, ticks = 1200}", // a parameter missing
		"R :: Other{seed = 7, players = 4, ticks = 1200, snapshot_tick = 600}", // another type
	}
	for other in others {
		unchanged, other_found, other_problem := scenarios.pin_first(other, "Reference", parameters, REFERENCE_NEW)
		testing.expectf(t, !other_found && other_problem == "" && unchanged == other, "not a placeholder: %s", other)
	}
	twice := fmt.tprintf("%s\n%s\n", placeholder, placeholder)
	_, _, twice_problem := scenarios.pin_first(twice, "Reference", parameters, REFERENCE_NEW)
	testing.expect(t, strings.contains(twice_problem, "more than one"), twice_problem)
}

// repin_first writes the one file of a directory that holds the placeholder; a second check of the same pin finds it
// pinned already.
@(test)
a_first_pin_writes_the_file_that_holds_it :: proc(t: ^testing.T) {
	dir, _ := filepath.join({
			os.temp_directory(context.temp_allocator) or_else ".",
			fmt.tprintf("unified-first-pin-test-%d", os.get_pid()),
		}, context.temp_allocator)
	_ = os.make_directory_all(dir)
	defer os.remove_all(dir)
	parameters := []scenarios.Pin_Field{{"seed", 7}, {"players", 4}, {"ticks", 1200}, {"snapshot_tick", 600}}
	pins, _ := filepath.join({dir, "reference.odin"}, context.temp_allocator)
	placeholder := "package fixture\n\nREFERENCE :: scenarios.Reference{seed = 7, players = 4, ticks = 1200, snapshot_tick = 600}\n"
	_ = os.write_entire_file(pins, transmute([]u8)placeholder)
	file, problem, already := scenarios.repin_first(dir, "Reference", parameters, REFERENCE_NEW)
	testing.expect_value(t, problem, "")
	testing.expect(t, !already, "the placeholder was pinned now")
	testing.expect_value(t, filepath.base(file), "reference.odin")
	written, _ := os.read_entire_file(pins, context.temp_allocator)
	testing.expect_value(t, string(written), fmt.tprintf("package fixture\n\n%s\n", REFERENCE_NEW))
	// a second check of the same pin finds the literal there: pinned already, nothing written
	again_file, again_problem, again_already := scenarios.repin_first(dir, "Reference", parameters, REFERENCE_NEW)
	testing.expect(t, again_problem == "" && again_already, again_problem)
	testing.expect_value(t, filepath.base(again_file), "reference.odin")
	// neither the placeholder nor the literal: nothing to pin
	_, missing, _ := scenarios.repin_first(dir, "Reference", parameters, REFERENCE_OLD)
	testing.expect(t, strings.contains(missing, "no .odin file"), missing)
}
