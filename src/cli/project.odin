package cli

import "core:os"
import "core:slice"
import "core:strings"

// The project the CLI runs in: this repo, or a game repo with unified as a submodule at unified/ (SPEC.md, Layout).
Project :: struct {
	root:    string, // the project root: the shims, tools/, .out/
	unified: string, // the unified checkout: the root itself, or <root>/unified
	out:     string, // <root>/.out
	games:   []Game,
}

// A game: a Godot project with simulation/ (its Odin code), the project root or each games/*/.
Game :: struct {
	name: string, // the directory's name, also its sim.Game name and its library's stem
	dir:  string,
}

// The project is two levels above the running binary (<root>/.out/cli/unified-<hash>).
@(private)
find_project :: proc() -> (project: Project) {
	exe, err := os.get_executable_path(context.allocator)
	if err != nil {
		fatal("cannot find the running executable: %v", err)
	}
	project.root = os.dir(os.dir(os.dir(exe)))
	project.out = join(project.root, ".out")
	project.unified =
		os.is_directory(join(project.root, "unified", "src", "cli")) ? join(project.root, "unified") : project.root
	project.games = find_games(project.root)
	return
}

@(private)
find_games :: proc(root: string) -> []Game {
	if is_game(root) {
		games := make([]Game, 1)
		games[0] = {os.base(root), root}
		return games
	}
	games: [dynamic]Game
	dirs, _ := os.read_all_directory_by_path(join(root, "games"), context.allocator)
	for entry in dirs {
		if entry.type == .Directory && is_game(entry.fullpath) {
			append(&games, Game{strings.clone(entry.name), strings.clone(entry.fullpath)})
		}
	}
	slice.sort_by(games[:], proc(first, second: Game) -> bool {return first.name < second.name})
	return games[:]
}

@(private)
is_game :: proc(dir: string) -> bool {
	return os.is_file(join(dir, "project.godot")) && os.is_directory(join(dir, "simulation"))
}

// The game a command names, or the only one when it names none.
game :: proc(name: string) -> Game {
	games := state.project.games
	if name == "" {
		if len(games) == 1 {
			return games[0]
		}
		names := make([]string, len(games))
		for candidate, i in games {
			names[i] = candidate.name
		}
		usage("name a game: %s", strings.join(names, ", "))
	}
	for candidate in games {
		if candidate.name == name {
			return candidate
		}
	}
	usage("no game %q", name)
}

// The games a command runs on: the one it names, or every game.
games_or_all :: proc(name: string) -> []Game {
	if name == "" {
		return state.project.games
	}
	selected := new_clone(game(name))
	return slice.from_ptr(selected, 1)
}

// --- platforms --------------------------------------------------------------------------------------------------

when ODIN_OS == .Windows {
	EXE :: ".exe"
	OS_NAME :: "windows"
} else when ODIN_OS == .Darwin {
	EXE :: ""
	OS_NAME :: "macos"
} else {
	EXE :: ""
	OS_NAME :: "linux"
}
when ODIN_ARCH == .arm64 {
	ARCH_NAME :: "arm64"
} else {
	ARCH_NAME :: "x64"
}
// This machine's platform: macos-arm64, linux-x64, linux-arm64, windows-x64.
PLATFORM :: OS_NAME + "-" + ARCH_NAME

// A shared library's file name on this OS: libX.dylib, libX.so, X.dll.
lib_name :: proc(stem: string) -> string {
	when ODIN_OS == .Windows {
		return tprint("%s.dll", stem)
	} else when ODIN_OS == .Darwin {
		return tprint("lib%s.dylib", stem)
	} else {
		return tprint("lib%s.so", stem)
	}
}

// --- paths ------------------------------------------------------------------------------------------------------

// Joins path elements with /, which every OS we run on accepts.
join :: proc(elems: ..string) -> string {
	builder := strings.builder_make()
	for element, i in elems {
		if element == "" {
			continue
		}
		if strings.builder_len(builder) > 0 && !strings.has_suffix(strings.to_string(builder), "/") && i > 0 {
			strings.write_byte(&builder, '/')
		}
		strings.write_string(&builder, element)
	}
	return strings.to_string(builder)
}

// `path` relative to the project root when it is inside it, for messages.
rel :: proc(path: string) -> string {
	root := state.project.root
	if strings.has_prefix(path, root) && len(path) > len(root) && (path[len(root)] == '/' || path[len(root)] == '\\') {
		return path[len(root) + 1:]
	}
	return path
}
