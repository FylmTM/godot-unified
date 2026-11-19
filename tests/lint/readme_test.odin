// The code is the spec (AGENTS.md, Conventions): every package of src/ and every game has a README.md.
package test_lint

import "core:fmt"
import "core:os"
import "core:testing"

// Every package of src/ (sub-packages are covered by their parent's) and every game has a README.md.
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
}
