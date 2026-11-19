// The code is the spec (AGENTS.md, Conventions): every package of src/ and every game has a README.md, and no SPEC.md
// comes back.
package test_lint

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:testing"

// Every package of src/ (sub-packages are covered by their parent's) and every game has a README.md, and no SPEC.md
// comes back: the code, its doc comments and the README are the spec.
@(test)
every_package_and_game_has_a_readme :: proc(t: ^testing.T) {
	for root in ([]string{SRC_DIR, GAMES_DIR}) {
		infos, err := os.read_all_directory_by_path(root, context.temp_allocator)
		testing.expectf(t, err == nil, "cannot list %s: %v", root, err)
		for info in infos {
			if info.type != .Directory do continue
			if root == GAMES_DIR && !os.exists(fmt.tprintf("%s/simulation", info.fullpath)) do continue
			testing.expectf(
				t,
				os.exists(fmt.tprintf("%s/README.md", info.fullpath)),
				"%s has no README.md",
				info.fullpath,
			)
		}
	}
	files: [dynamic]string
	defer delete(files)
	collect_files(SRC_DIR, &files)
	collect_files(GAMES_DIR, &files)
	for file in files {
		testing.expectf(t, filepath.base(file) != "SPEC.md", "%s: the README and the doc comments are the spec", file)
	}
}

@(private)
collect_files :: proc(dir: string, out: ^[dynamic]string) {
	infos, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil do return
	for info in infos {
		if info.type == .Directory {
			if info.name == ".out" || info.name == ".godot" || info.name == "addons" do continue
			collect_files(info.fullpath, out)
		} else {
			append(out, info.fullpath)
		}
	}
}
