// unified:cli's library parts (src/cli/SPEC.md, Testing): the config and .env parsers, zip writing and reading,
// build manifests, SHA-256, and the small parsers the commands use. The commands themselves run end to end in
// `uni selftest` and every CI job.
package test_cli

import "core:os"
import "core:testing"
import "core:time"
import "unified:cli"

@(test)
config_sections_keys_quotes_comments :: proc(t: ^testing.T) {
	c := cli.config_parse(
		`; a comment
top = "level"
[odin]
tag = "dev-2026-11a"
commit = 9a6991685
[godot_templates]
version.txt = "abc"
`,
	)
	v, ok := cli.config_get(c, "odin", "tag")
	testing.expect(t, ok)
	testing.expect_value(t, v, "dev-2026-11a")
	v, ok = cli.config_get(c, "odin", "commit")
	testing.expect_value(t, v, "9a6991685")
	v, ok = cli.config_get(c, "", "top")
	testing.expect_value(t, v, "level")
	v, ok = cli.config_get(c, "godot_templates", "version.txt")
	testing.expect_value(t, v, "abc")
	_, ok = cli.config_get(c, "odin", "missing")
	testing.expect(t, !ok)
}

@(test)
env_takes_unified_keys_only :: proc(t: ^testing.T) {
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
	dir, derr := os.make_directory_temp("", "unified-cli-test-*", context.allocator)
	testing.expect(t, derr == nil)
	defer os.remove_all(dir)
	big := make([]byte, 200_000)
	for &b, i in big {
		b = byte(i * 7 % 251)
	}
	w: cli.Zip_Writer
	cli.zip_add(&w, "VERSION", transmute([]byte)string("1.2.3\n"))
	cli.zip_add(&w, "SDK/Bin/lib.so", big, 0o755)
	path := cli.join(dir, "a.zip")
	testing.expect(t, cli.write_file(path, cli.zip_finish(&w)))
	z := cli.zip_open_file(path)
	entries := cli.zip_entries(&z)
	testing.expect_value(t, len(entries), 2)
	testing.expect_value(t, entries[1].name, "SDK/Bin/lib.so")
	testing.expect_value(t, entries[1].mode & 0o777, 0o755)
	testing.expect_value(t, string(cli.zip_read(&z, entries[0])), "1.2.3\n")
	got := cli.zip_read(&z, entries[1])
	testing.expect_value(t, len(got), len(big))
	testing.expect(t, string(got) == string(big))
	// Writing the same files again gives the same bytes (fixed timestamps): the packed SDK's hashes are pinned.
	w2: cli.Zip_Writer
	cli.zip_add(&w2, "VERSION", transmute([]byte)string("1.2.3\n"))
	cli.zip_add(&w2, "SDK/Bin/lib.so", big, 0o755)
	again := cli.zip_finish(&w2)
	first, _ := os.read_entire_file(path, context.allocator)
	testing.expect(t, string(again) == string(first))
}

@(test)
manifest_notices_changes :: proc(t: ^testing.T) {
	dir, _ := os.make_directory_temp("", "unified-cli-test-*", context.allocator)
	defer os.remove_all(dir)
	pkg := cli.join(dir, "pkg")
	src := cli.join(pkg, "a.odin")
	testing.expect(t, cli.write_file(src, transmute([]byte)string("package a\n")))
	m := cli.join(dir, "out", "out.manifest") // apart from the sources, like .out/ (writing it changes its directory)
	cli.write_manifest(m, "key-1", {src}, "")
	entries, key, ok := cli.read_manifest(m)
	testing.expect(t, ok)
	testing.expect_value(t, key, "key-1")
	testing.expect(t, cli.entries_current(entries), "nothing changed")
	time.sleep(20 * time.Millisecond) // a new modification time
	testing.expect(t, cli.write_file(src, transmute([]byte)string("package a // edited\n")))
	testing.expect(t, !cli.entries_current(entries), "an edited source is noticed")
	cli.write_manifest(m, "key-1", {src}, "")
	entries, _, _ = cli.read_manifest(m)
	time.sleep(20 * time.Millisecond)
	testing.expect(t, cli.write_file(cli.join(pkg, "b.odin"), transmute([]byte)string("package a\n")))
	testing.expect(t, !cli.entries_current(entries), "a new file in a source directory is noticed")
}

@(test)
sha256_known_vector :: proc(t: ^testing.T) {
	testing.expect_value(
		t,
		cli.sha256_hex(transmute([]byte)string("abc")),
		"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
	)
}

@(test)
small_parsers :: proc(t: ^testing.T) {
	testing.expect_value(t, len(cli.split_list(" odin, godot ,,")), 2)
	testing.expect(t, cli.valid_game_name("dots_2"))
	testing.expect(t, !cli.valid_game_name("2dots"))
	testing.expect(t, !cli.valid_game_name("Dots"))
	testing.expect(t, !cli.valid_game_name("my-game"))
	testing.expect_value(t, cli.parse_i64("1234 bytes"), 1234)
	testing.expect_value(t, cli.join("a/", "b", "", "c"), "a/b/c")
}
