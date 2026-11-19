// The per-user cache (README.md, Layout): pinned downloads shared by every checkout on the machine, keyed by version
// and SHA-256 so two pins never share a path. The shims put the pinned Odin there (odin/<tag>); the CLI puts Godot
// (godot/<version>-<sha>) and the unified-box3d zips (downloads/). `clean` leaves it; `clean --cache` clears what
// the CLI put there.
package cli

import "core:os"
import "core:strings"
import "core:time"

// <per-user cache>/unified: %LOCALAPPDATA% on Windows, ${XDG_CACHE_HOME:-~/.cache} elsewhere (where the shims look).
user_cache :: proc() -> string {
	@(static) cached: string
	if cached != "" {
		return cached
	}
	base: string
	when ODIN_OS == .Windows {
		base = os.get_env("LOCALAPPDATA", context.allocator)
		if base == "" {
			fatal("LOCALAPPDATA is not set: the per-user cache goes there")
		}
	} else {
		base = os.get_env("XDG_CACHE_HOME", context.allocator)
		if base == "" {
			home := os.get_env("HOME", context.allocator)
			if home == "" {
				fatal("neither XDG_CACHE_HOME nor HOME is set: the per-user cache goes there")
			}
			base = join(home, ".cache")
		}
	}
	cached, _ = strings.replace_all(join(base, "unified"), "\\", "/")
	return cached
}

// What `clean --cache` removes from the per-user cache: what the CLI fetched (the shims' Odin stays, or the next
// command downloads it again before it can run).
user_cache_cleanable :: proc() -> []string {
	return strs(join(user_cache(), "godot"), join(user_cache(), "downloads"))
}

// Renames a freshly unpacked `tmp` directory to `dir`. Another checkout may have won the race: then `ready` (a file
// inside `dir`) exists and `tmp` goes. On Windows a virus scanner holds a fresh file while it scans it (a CI runner's
// Defender takes seconds over the Godot editor just unpacked and run), so the rename is retried, waiting longer each
// time, for up to RENAME_PATIENCE.
rename_into_place :: proc(tmp, dir, ready: string) {
	start := time.tick_now()
	wait := 250 * time.Millisecond
	for {
		if os.rename(tmp, dir) == nil {
			return
		}
		if os.is_file(ready) {
			remove_tree(tmp)
			return
		}
		if time.tick_since(start) > RENAME_PATIENCE {
			break
		}
		time.sleep(wait)
		wait = min(wait * 2, 4 * time.Second)
	}
	fatal("cannot move %s into place as %s", tmp, dir)
}

// How long rename_into_place keeps retrying a rename a virus scanner blocks.
RENAME_PATIENCE :: 30 * time.Second
