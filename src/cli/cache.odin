// The per-user cache (README.md, Layout): pinned downloads and builds shared by every checkout on the machine, keyed
// by version and SHA-256 (or commit) so two pins never share a path. The shims put the pinned Odin there (odin/<tag>);
// the CLI puts Godot (godot/<version>-<sha>), the unified-box3d zips (downloads/) and odinfmt
// (odinfmt/<commit>-<odin commit>). `clean` leaves it; `clean --cache` clears what the CLI put there.
package cli

import "core:os"
import "core:strconv"
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
	cached = slashed(join(base, "unified"))
	return cached
}

// What `clean --cache` removes from the per-user cache: what the CLI fetched (the shims' Odin stays, or the next
// command downloads it again before it can run).
user_cache_cleanable :: proc() -> []string {
	return strs(join(user_cache(), "godot"), join(user_cache(), "downloads"), join(user_cache(), "odinfmt"))
}

// A lock taken with lock_acquire: release it with lock_release.
Lock :: struct {
	path: string,
}

// Takes the lock file at `path` (made with exclusive create, holding this process's pid), waiting while another
// process holds it: two uni processes that would build or unpack the same thing take turns. A lock whose process is
// gone (a crash, a kill) or that is older than LOCK_STALE is taken over. `what` names the work in the wait's message.
lock_acquire :: proc(path, what: string) -> Lock {
	make_dirs(os.dir(path))
	said := false
	for {
		file, err := os.open(path, {.Write, .Create, .Excl})
		if err == nil {
			os.write_string(file, aprintf("%d\n", os.get_pid()))
			os.close(file)
			return {path}
		}
		holder, _ := read_text(path)
		pid, parsed := strconv.parse_int(strings.trim_space(holder))
		info, stat_err := os.stat(path, context.temp_allocator)
		old := stat_err == nil && time.diff(info.modification_time, time.now()) > LOCK_STALE
		if (parsed && !process_runs(pid, "")) || old {
			os.remove(path) // its holder is gone
			continue
		}
		if !parsed && stat_err == nil && time.diff(info.modification_time, time.now()) < time.Second {
			time.sleep(20 * time.Millisecond) // just created: its pid is being written
			continue
		}
		if !said {
			log("uni: waiting for another uni's %s (%s)", what, path)
			said = true
		}
		time.sleep(100 * time.Millisecond)
	}
}

// Gives back a lock lock_acquire took.
lock_release :: proc(lock: Lock) {
	os.remove(lock.path)
}

// How old a lock may be before lock_acquire takes it over whoever holds it: longer than any build or unpack it guards.
LOCK_STALE :: 10 * time.Minute

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
