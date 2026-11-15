// unified:cli's library parts (src/cli/SPEC.md, Testing): the config and .env parsers, zip writing and reading,
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

// `init --in-repo` imports the game's tests in tests/tests.odin, sorted among the other games' imports, once.
@(test)
init_imports_game_tests :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator // the CLI never frees: it is short-lived
	ROOT :: `package tests

@(require) import "sim"

@(require) import drift_tests "../games/drift/simulation/tests"
@(require) import survivor_tests "../games/survivor/simulation/tests"
`
	text, added := cli.import_game_tests(ROOT, "minimal")
	testing.expect(t, added)
	testing.expect_value(
		t,
		text,
		`package tests

@(require) import "sim"

@(require) import drift_tests "../games/drift/simulation/tests"
@(require) import minimal_tests "../games/minimal/simulation/tests"
@(require) import survivor_tests "../games/survivor/simulation/tests"
`,
	)
	again, added_again := cli.import_game_tests(text, "minimal")
	testing.expect(t, !added_again)
	testing.expect_value(t, again, text)
	first, _ := cli.import_game_tests(ROOT, "alpha")
	testing.expect(t, strings.contains(first, "\"sim\"\n\n@(require) import alpha_tests"))
	last, _ := cli.import_game_tests(ROOT, "zeta")
	testing.expect(
		t,
		strings.has_suffix(
			last,
			"survivor_tests \"../games/survivor/simulation/tests\"\n@(require) import zeta_tests \"../games/zeta/simulation/tests\"\n",
		),
	)
	none, _ := cli.import_game_tests("package tests\n\n@(require) import \"sim\"\n", "alpha")
	testing.expect_value(
		t,
		none,
		"package tests\n\n@(require) import \"sim\"\n\n@(require) import alpha_tests \"../games/alpha/simulation/tests\"\n",
	)
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
line_endings_lf_except_batch_files :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator // the CLI never frees: it is short-lived
	Case :: struct {
		info:    string,
		problem: bool,
		crlf:    bool,
	}
	cases := []Case {
		{"i/lf    w/lf    attr/text=auto eol=lf ", false, false},
		{"i/lf    w/crlf  attr/text=auto eol=lf ", true, false}, // an editor saved CRLF
		{"i/lf    w/mixed attr/text=auto eol=lf ", true, false},
		{"i/crlf  w/crlf  attr/                 ", true, false}, // committed CRLF
		{"i/none  w/none  attr/text=auto eol=lf ", false, false}, // empty, or no line ending
		{"i/-text w/-text attr/text=auto eol=lf ", false, false}, // git sees binary
		{"i/-text w/-text attr/-text            ", false, false}, // marked binary
		{"i/lf    w/crlf  attr/text eol=crlf    ", false, true}, // uni.cmd on any OS
		{"i/lf    w/lf    attr/text eol=crlf    ", true, true}, // a batch file left LF
		{"i/lf    w/mixed attr/text eol=crlf    ", true, true},
		{"i/lf    w/      attr/text=auto eol=lf ", false, false}, // deleted in the working tree
	}
	for test_case in cases {
		problem, crlf := cli.eol_problem(test_case.info)
		testing.expectf(t, (problem != "") == test_case.problem, "%q: problem %q", test_case.info, problem)
		testing.expectf(t, crlf == test_case.crlf, "%q: crlf %v", test_case.info, crlf)
	}
	listing := "i/lf    w/lf    attr/text=auto eol=lf \tsrc/a.odin\x00i/lf    w/crlf  attr/text=auto eol=lf \tdocs/my file.md\x00i/lf    w/lf    attr/text eol=crlf    \tuni.cmd\x00"
	files := cli.eol_problems(listing)
	if testing.expect_value(t, len(files), 2) {
		testing.expect_value(t, files[0].path, "docs/my file.md")
		testing.expect(t, !files[0].crlf)
		testing.expect_value(t, files[1].path, "uni.cmd")
		testing.expect(t, files[1].crlf)
	}
	testing.expect_value(t, cli.eol_convert("a\r\nb\nc\r\n", false), "a\nb\nc\n")
	testing.expect_value(t, cli.eol_convert("a\r\nb\nc", true), "a\r\nb\r\nc")
	// the config readers take CRLF files too
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
	write(dir, "addons/shared/validate.gd", "class_name UnifiedValidate\nextends SceneTree\n")
	testing.expect(t, !cli.import_current(dir), "the mirrored shared code gained a class")
	cli.import_mark_current(dir)
	testing.expect(t, cli.import_current(dir))
	os.remove(cli.join(dir, ".godot", "global_script_class_cache.cfg"))
	testing.expect(t, !cli.import_current(dir), "the class cache is gone")
}
