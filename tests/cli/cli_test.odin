// unified:cli's library parts (src/cli/README.md, Testing): the config and .env parsers, zip writing and reading,
// build manifests, SHA-256, and the small parsers the commands use. The commands themselves run end to end in
// `uni selftest` and every CI job.
package test_cli

import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import "unified:cli"

@(test)
config_sections_keys_quotes_comments :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator // the CLI never frees: it is short-lived
	config := cli.config_parse(
		`; a comment
top = "level"
[odin]
tag = "dev-2026-11a"
commit = 9a6991685
[godot_templates]
version.txt = "abc"
`,
	)
	value, ok := cli.config_get(config, "odin", "tag")
	testing.expect(t, ok)
	testing.expect_value(t, value, "dev-2026-11a")
	value, ok = cli.config_get(config, "odin", "commit")
	testing.expect_value(t, value, "9a6991685")
	value, ok = cli.config_get(config, "", "top")
	testing.expect_value(t, value, "level")
	value, ok = cli.config_get(config, "godot_templates", "version.txt")
	testing.expect_value(t, value, "abc")
	_, ok = cli.config_get(config, "odin", "missing")
	testing.expect(t, !ok)
}

@(test)
env_takes_unified_keys_only :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator // the CLI never frees: it is short-lived
	pairs, err := cli.env_parse("# local paths\nUNIFIED_GODOT=/opt/godot/Godot\n\nUNIFIED_EOS_SDK = /sdk \n")
	testing.expect_value(t, err, "")
	testing.expect_value(t, len(pairs), 2)
	testing.expect_value(t, pairs[0], [2]string{"UNIFIED_GODOT", "/opt/godot/Godot"})
	testing.expect_value(t, pairs[1], [2]string{"UNIFIED_EOS_SDK", "/sdk"})
	_, err = cli.env_parse("PATH=/bin\n")
	testing.expect(t, err != "", "a key outside UNIFIED_* is an error")
	_, err = cli.env_parse("UNIFIED_GODOT\n")
	testing.expect(t, err != "", "a line without = is an error")
	_, err = cli.env_parse("UNIFIED_godot=x\n")
	testing.expect(t, err != "", "a lowercase key is an error")
}

@(test)
zip_round_trip :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator // the CLI never frees: it is short-lived
	dir, temp_err := os.make_directory_temp("", "unified-cli-test-*", context.allocator)
	testing.expect(t, temp_err == nil)
	defer os.remove_all(dir)
	big := make([]byte, 200_000)
	for &element, i in big {
		element = byte(i * 7 % 251)
	}
	writer: cli.Zip_Writer
	cli.zip_add(&writer, "VERSION", transmute([]byte)string("1.2.3\n"))
	cli.zip_add(&writer, "SDK/Bin/lib.so", big, 0o755)
	path := cli.join(dir, "a.zip")
	testing.expect(t, cli.write_file(path, cli.zip_finish(&writer)))
	reader := cli.zip_open_file(path)
	entries := cli.zip_entries(&reader)
	testing.expect_value(t, len(entries), 2)
	testing.expect_value(t, entries[1].name, "SDK/Bin/lib.so")
	testing.expect_value(t, entries[1].mode & 0o777, 0o755)
	testing.expect_value(t, string(cli.zip_read(&reader, entries[0])), "1.2.3\n")
	got := cli.zip_read(&reader, entries[1])
	testing.expect_value(t, len(got), len(big))
	testing.expect(t, string(got) == string(big))
	// Writing the same files again gives the same bytes (fixed timestamps): the packed SDK's hashes are pinned.
	second_writer: cli.Zip_Writer
	cli.zip_add(&second_writer, "VERSION", transmute([]byte)string("1.2.3\n"))
	cli.zip_add(&second_writer, "SDK/Bin/lib.so", big, 0o755)
	again := cli.zip_finish(&second_writer)
	first, _ := os.read_entire_file(path, context.allocator)
	testing.expect(t, string(again) == string(first))
	// A release zip of one top folder unpacks flattened (the unified-box3d release).
	flat_writer: cli.Zip_Writer
	cli.zip_add(&flat_writer, "pkg-1.0/", nil)
	cli.zip_add(&flat_writer, "pkg-1.0/lib/x/lib.so", big, 0o755)
	cli.zip_add(&flat_writer, "pkg-1.0/README.md", transmute([]byte)string("hi\n"))
	top := cli.join(dir, "top.zip")
	testing.expect(t, cli.write_file(top, cli.zip_finish(&flat_writer)))
	flat_reader := cli.zip_open_file(top)
	flat := cli.join(dir, "flat")
	cli.zip_extract_all(&flat_reader, flat, strip_top = true)
	readme, _ := os.read_entire_file(cli.join(flat, "README.md"), context.allocator)
	testing.expect_value(t, string(readme), "hi\n")
	lib, _ := os.read_entire_file(cli.join(flat, "lib", "x", "lib.so"), context.allocator)
	testing.expect(t, string(lib) == string(big))
	testing.expect(t, !os.exists(cli.join(flat, "pkg-1.0")))
}

@(test)
manifest_notices_changes :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator // the CLI never frees: it is short-lived
	dir, _ := os.make_directory_temp("", "unified-cli-test-*", context.allocator)
	defer os.remove_all(dir)
	pkg := cli.join(dir, "pkg")
	src := cli.join(pkg, "a.odin")
	testing.expect(t, cli.write_file(src, transmute([]byte)string("package a\n")))
	manifest_path := cli.join(dir, "out", "out.manifest") // apart from the sources, like .out/ (writing it changes its directory)
	cli.write_manifest(manifest_path, "key-1", {src}, "")
	entries, key, ok := cli.read_manifest(manifest_path)
	testing.expect(t, ok)
	testing.expect_value(t, key, "key-1")
	testing.expect(t, cli.entries_current(entries), "nothing changed")
	time.sleep(20 * time.Millisecond) // a new modification time
	testing.expect(t, cli.write_file(src, transmute([]byte)string("package a // edited\n")))
	testing.expect(t, !cli.entries_current(entries), "an edited source is noticed")
	cli.write_manifest(manifest_path, "key-1", {src}, "")
	entries, _, _ = cli.read_manifest(manifest_path)
	time.sleep(20 * time.Millisecond)
	testing.expect(t, cli.write_file(cli.join(pkg, "b.odin"), transmute([]byte)string("package a\n")))
	testing.expect(t, !cli.entries_current(entries), "a new file in a source directory is noticed")
}

@(test)
sha256_known_vector :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator // the CLI never frees: it is short-lived
	testing.expect_value(
		t,
		cli.sha256_hex(transmute([]byte)string("abc")),
		"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
	)
}

@(test)
small_parsers :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator // the CLI never frees: it is short-lived
	testing.expect_value(t, len(cli.split_list(" odin, godot ,,")), 2)
	testing.expect(t, cli.valid_game_name("dots_2"))
	testing.expect(t, !cli.valid_game_name("2dots"))
	testing.expect(t, !cli.valid_game_name("Dots"))
	testing.expect(t, !cli.valid_game_name("my-game"))
	testing.expect_value(t, cli.parse_i64("1234 bytes"), 1234)
	testing.expect_value(t, cli.join("a/", "b", "", "c"), "a/b/c")
}

// `init`'s default submodule URL: a GitHub SSH origin becomes HTTPS (no keys needed); anything else stays.
@(test)
init_public_url :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator // the CLI never frees: it is short-lived
	HTTPS :: "https://github.com/FylmTM/godot-unified.git"
	testing.expect_value(t, cli.public_url("git@github.com:FylmTM/godot-unified.git"), HTTPS)
	testing.expect_value(t, cli.public_url("git@github.com:FylmTM/godot-unified"), HTTPS)
	testing.expect_value(t, cli.public_url("ssh://git@github.com/FylmTM/godot-unified.git"), HTTPS)
	testing.expect_value(t, cli.public_url(HTTPS), HTTPS)
	testing.expect_value(t, cli.public_url("git@gitlab.com:someone/unified.git"), "git@gitlab.com:someone/unified.git")
	testing.expect_value(t, cli.public_url("C:/work/unified"), "C:/work/unified")
}

// A .gdextension's [dependencies], written by `uni build` from what the extension links: added when missing, replaced
// when stale (with the comment above it), removed when it links nothing, the rest of the file as it was.
@(test)
dependencies_follow_what_the_extension_links :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator // the CLI never frees: it is short-lived
	BASE :: "[configuration]\n\nentry_symbol = \"g_init\"\n\n[libraries]\n\nwindows.x86_64 = \"res://.out/bin/g.dll\"\n"
	testing.expect_value(t, cli.dependencies_section(false, false), "")
	testing.expect_value(t, cli.with_dependencies(BASE, ""), BASE)
	box3d := cli.dependencies_section(true, false)
	both := cli.dependencies_section(true, true)
	testing.expect(t, strings.contains(box3d, `windows.x86_64 = { "res://.out/bin/box3d.dll": "" }`))
	testing.expect(t, !strings.contains(box3d, "EOSSDK"))
	testing.expect(
		t,
		strings.contains(
			both,
			`macos.release = { "res://.out/bin/libbox3d.dylib": "Contents/Frameworks", "res://.out/bin/libEOSSDK-Mac-Shipping.dylib": "Contents/Frameworks" }`,
		),
	)
	testing.expect(t, strings.contains(both, `linux.x86_64 = { "res://.out/bin/libbox3d.so": "" }`)) // no EOS on Linux
	added := cli.with_dependencies(BASE, box3d)
	testing.expect_value(t, added, strings.concatenate({BASE, "\n", box3d}))
	testing.expect_value(t, cli.with_dependencies(added, box3d), added) // current: unchanged
	replaced := cli.with_dependencies(added, both)
	testing.expect_value(t, replaced, strings.concatenate({BASE, "\n", both}))
	testing.expect_value(t, cli.with_dependencies(replaced, ""), BASE)
	// a section after it stays
	LATER :: "[icons]\n\nGame = \"res://icon.svg\"\n"
	testing.expect_value(
		t,
		cli.with_dependencies(strings.concatenate({added, "\n", LATER}), both),
		strings.concatenate({BASE, "\n", both, "\n", LATER}),
	)
}

// The test root's game imports (tests/games.gen.odin, written by uni): every in-repo game's tests, sorted, so a new
// game (init --in-repo) edits no shared file.
@(test)
game_test_imports_are_generated :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator // the CLI never frees: it is short-lived
	text := cli.game_test_imports({"survivor", "drift", "minimal"})
	testing.expect(t, strings.contains(text, "package tests\n"))
	testing.expect(
		t,
		strings.has_suffix(
			text,
			"\n@(require) import drift_tests \"../games/drift/simulation/tests\"\n" +
			"@(require) import minimal_tests \"../games/minimal/simulation/tests\"\n" +
			"@(require) import survivor_tests \"../games/survivor/simulation/tests\"\n",
		),
	)
	testing.expect(t, strings.has_suffix(cli.game_test_imports({}), "package tests\n"))
}

// The test runner's output (-define:ODIN_TEST_LOG_STATE_CHANGES=true) as the test watchdog reads it.
@(test)
test_watch_follows_the_runner :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator // the CLI never frees: it is short-lived
	watch: cli.Test_Watch
	lines := []string {
		"[INFO ] --- [2026-11-14 10:44:53] Test #0 test_b3.crashes changed state to Running.\n",
		"[INFO ] --- [2026-11-14 10:44:53] Test #1 test_b3.waits changed state to Running.\r\n",
		"[INFO ] --- [2026-11-14 10:44:53] Test #2 test_sim.quick changed state to Running.\n",
		"[INFO ] --- [2026-11-14 10:44:53] Test #2 test_sim.quick changed state to Successful.\n",
		"[FATAL] --- [2026-11-14 10:44:53] Caught signal to stop test #0 test_b3.crashes for: Segmentation_Fault.\n",
		"[INFO ] --- [2026-11-14 10:44:53] [x.odin:1:p()] a test's own line: Test #9 a.b changed state to Running.\n",
	}
	echoed := 0
	for line in lines {
		if !cli.test_watch_line(&watch, line) {
			echoed += 1
		}
	}
	testing.expect_value(t, echoed, 2) // the crash and the test's own line
	testing.expect_value(t, len(watch.crashed), 1)
	testing.expect_value(t, watch.crashed[0], "test_b3.crashes")
	testing.expect_value(t, len(watch.running), 1)
	testing.expect_value(t, watch.running[0], "test_b3.waits")
}

@(test)
config_readers_take_crlf :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator // the CLI never frees: it is short-lived
	config := cli.config_parse("[odin]\r\ntag = \"dev-2026-11a\"\r\n")
	value, _ := cli.config_get(config, "odin", "tag")
	testing.expect_value(t, value, "dev-2026-11a")
	pairs, err := cli.env_parse("UNIFIED_GODOT=/opt/godot\r\n")
	testing.expect_value(t, err, "")
	testing.expect_value(t, pairs[0], [2]string{"UNIFIED_GODOT", "/opt/godot"})
}

@(test)
import_current_follows_class_names_and_the_cache :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator // the CLI never frees: it is short-lived
	dir, temp_err := os.make_directory_temp("", "unified-cli-import-*", context.allocator)
	testing.expect(t, temp_err == nil)
	defer os.remove_all(dir)
	write :: proc(dir, name, text: string) {
		cli.write_text(cli.join(dir, name), text)
	}
	write(dir, "project.godot", "[application]\n")
	write(dir, "game/main.gd", "class_name Main\nextends Node\n")
	testing.expect(t, !cli.import_current(dir), "a fresh checkout has no import")
	write(dir, ".godot/global_script_class_cache.cfg", "list=[]\n")
	cli.import_mark_current(dir)
	testing.expect(t, cli.import_current(dir), "just imported")
	write(dir, "game/main.gd", "class_name Main\nextends Node\n\nfunc _ready() -> void:\n\tpass\n")
	testing.expect(t, cli.import_current(dir), "a script body changed: no import needed")
	write(dir, "addons/unified/validate.gd", "class_name UnifiedValidate\nextends SceneTree\n")
	testing.expect(t, !cli.import_current(dir), "the mirrored tool scripts gained a class")
	cli.import_mark_current(dir)
	testing.expect(t, cli.import_current(dir))
	os.remove(cli.join(dir, ".godot", "global_script_class_cache.cfg"))
	testing.expect(t, !cli.import_current(dir), "the class cache is gone")
}

// sources_import reads import lines only: a commented-out import doesn't count, an attributed one does.
@(test)
sources_import_reads_import_lines :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator // the CLI never frees: it is short-lived
	dir, temp_err := os.make_directory_temp("", "unified-cli-sources-*", context.allocator)
	testing.expect(t, temp_err == nil)
	defer os.remove_all(dir)
	cli.write_text(cli.join(dir, "a.odin"), "package a\n\n// import \"unified:physics\"\nx := \"unified:physics\"\n")
	testing.expect(t, !cli.scan_imports(dir, {`"unified:physics"`}), "a comment or a string is not an import")
	cli.write_text(cli.join(dir, "sub/b.odin"), "package b\n\n@(require) import \"unified:physics\"\n")
	testing.expect(t, cli.scan_imports(dir, {`"unified:physics"`}), "an attributed import counts")
	testing.expect(t, !cli.scan_imports(dir, {`"unified:eos"`}))
}

// The level scenes uni bake exports: every scene in game/levels/, and any other one with its .level beside it, never
// one under a hidden or .gdignore'd directory or addons/ (src/level/README.md, Baking).
@(test)
level_scenes_are_found_wherever_a_game_keeps_them :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator // the CLI never frees: it is short-lived
	dir, temp_err := os.make_directory_temp("", "unified-cli-test-*", context.allocator)
	testing.expect(t, temp_err == nil)
	defer os.remove_all(dir)
	files := []string {
		"game/levels/arena.tscn", // the default place: baked even before its first .level
		"game/levels/props/crate.tscn", // a scene below it, no .level: not a level
		"maps/yard.tscn",
		"maps/yard.level", // a level kept elsewhere
		"maps/menu.tscn", // no .level beside it: not a level
		"addons/tool/demo.tscn",
		"addons/tool/demo.level",
		".hidden/x.tscn",
		".hidden/x.level",
		"vendor/.gdignore",
		"vendor/v.tscn",
		"vendor/v.level",
	}
	for file in files {
		path := cli.join(dir, file)
		os.make_directory_all(cli.join(dir, file[:strings.last_index(file, "/")]))
		testing.expect(t, cli.write_file(path, transmute([]byte)string("x")), path)
	}
	testing.expect_value(
		t,
		strings.join(cli.level_scenes(dir), " "),
		"res://game/levels/arena.tscn res://maps/yard.tscn",
	)
}

// What fails a Godot run: a game script's warning (its backtrace names res://game/), a leak at exit and an error line;
// the engine's own warnings pass.
@(test)
godot_problems_name_game_warnings_and_leaks :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	out :=
		"WARNING: marker view: no level marker 4\r\n" +
		"     at: push_warning (core/variant/variant_utility.cpp:1118)\r\n" +
		"     GDScript backtrace (most recent call first):\r\n" +
		"         [0] _ready (res://game/views/marker_view.gd:31)\r\n" +
		"WARNING: an engine warning\r\n" +
		"     at: some_engine_function (scene/main/node.cpp:10)\r\n" +
		"WARNING: 2 ObjectDB instances were leaked at exit (run with --verbose for details).\r\n" +
		"ERROR: something broke\r\n"
	problems := cli.godot_problems(out)
	testing.expect_value(t, len(problems), 3)
	if len(problems) == 3 {
		testing.expect(t, strings.has_prefix(problems[0], "game warning: WARNING: marker view"), problems[0])
		testing.expect(t, strings.has_prefix(problems[1], "leak at exit:"), problems[1])
		testing.expect(t, strings.has_prefix(problems[2], "error line: ERROR: something broke"), problems[2])
	}
	testing.expect_value(t, len(cli.godot_problems("WARNING: an engine warning\n     at: f (a.cpp:1)\n")), 0)
	// an extension that did not install: only why, not the script errors that follow from it
	not_installed := cli.godot_problems(
		"ERROR: unified: the game toy is not installed: data type Data_Hud: Data_Hud has 1 bytes of implicit padding\n" +
		"   at: register_classes (views.odin:172)\n" +
		"SCRIPT ERROR: Parse Error: Identifier \"EnumPhase\" not declared in the current scope.\n",
	)
	testing.expect_value(t, len(not_installed), 1)
	testing.expect(t, cli.not_installed(not_installed), "not installed")
	if len(not_installed) == 1 {
		testing.expect_value(
			t,
			not_installed[0],
			"the extension is not installed: data type Data_Hud: Data_Hud has 1 bytes of implicit padding",
		)
	}
}

// uni doc's reading of `odin doc` text: sections, declarations and docs (a formatter directive is no doc), a proc
// group with its procs, names and parts of names, and the brief form.
@(test)
doc_reads_selects_and_briefs :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator // the CLI never frees: it is short-lived
	text :=
		"package toy\n\ttoy.odin\n\t\tThe toy.\n\n\tprocedures\n" +
		"\t\tgo_fast :: proc(x: int)  // src/toy/toy.odin:3\n\t\t\todinfmt: disable\n" +
		"\t\tgo_slow :: proc()  // src/toy/toy.odin:9\n\t\t\tGoes slowly. Then stops.\n\n" +
		"\tproc_group\n\t\tgo :: proc{go_fast, go_slow}\n\t\t\tGoes.\n\n" +
		"\ttypes\n\t\tThing :: struct {a: int}\n\t\t\tA thing.\n\n\tfullpath:\n\t\t/src/toy\n\tfiles:\n\t\ttoy.odin\n"
	doc := cli.doc_parse(text)
	testing.expect_value(t, doc.package_line, "package toy")
	testing.expect_value(t, len(doc.entries), 4)
	if len(doc.entries) != 4 do return
	testing.expect_value(t, doc.entries[0].name, "go_fast")
	testing.expect_value(t, len(doc.entries[0].doc), 0) // the directive left out
	testing.expect_value(t, doc.entries[3].section, "types")
	chosen, missing := cli.doc_select(doc, {"go", "THI", "nothing"})
	testing.expect_value(t, len(chosen), 4) // the group with its two procs, and Thing by part of its name
	testing.expect_value(t, len(missing), 1)
	brief := cli.doc_brief(doc, "toy")
	testing.expect(t, !strings.contains(brief, "go_fast"), "a group's procs fold into it")
	testing.expect(t, strings.contains(brief, "go     Goes."), brief)
	testing.expect(t, strings.contains(brief, "Thing  A thing."), brief)
	testing.expect_value(t, cli.doc_first_sentence({"Goes slowly. Then", "stops."}), "Goes slowly.")
}

// A struct's source for uni doc: through its closing brace (braces in strings, tags and comments don't count), and
// only when its body has a comment.
@(test)
doc_source_block_takes_commented_bodies :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator // the CLI never frees: it is short-lived
	commented := []string {
		"Opts :: struct {",
		"\t// the name {not a brace}",
		"\tname: string `usage:\"a }\"`,",
		"}",
		"after",
	}
	testing.expect_value(t, len(cli.doc_source_block(commented)), 4)
	testing.expect_value(t, len(cli.doc_source_block([]string{"Plain :: struct {", "\ta: int,", "}"})), 0)
}
