// The per-user cache (README.md, Layout): pinned downloads and builds shared by every checkout on the machine, keyed
// by version and SHA-256 (or commit) so two pins never share a path. The shims put the pinned Odin there (odin/<tag>);
// the CLI puts Godot (godot/<version>-<sha>), the unified-box3d zips (downloads/) and odinfmt
// (odinfmt/<commit>-<odin commit>). `clean` leaves it; `clean --cache` clears what the CLI put there.
package cli

import "core:container/small_array"
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
// gone (a crash, a kill), that is older than LOCK_STALE, or that still holds no pid after LOCK_UNWRITTEN (its process
// was killed before writing it) is taken over (lock_take_over). `what` names the work in the wait's message. The lock
// is released by lock_release, and by a failing exit (`fatal`, `usage`: unwind), which no `defer` survives.
lock_acquire :: proc(path, what: string) -> Lock {
	make_dirs(os.dir(path))
	said := false
	for {
		file, err := os.open(path, {.Write, .Create, .Excl})
		if err == nil {
			os.write_string(file, lock_owner())
			os.close(file)
			if !small_array.push_back(&held_locks, path) do fatal("more than %d locks held at once", HELD_LOCKS_MAX)
			return {path}
		}
		holder := lock_holder(path)
		if lock_stale(holder) {
			lock_take_over(path, holder)
			continue
		}
		if holder.found && holder.text == "" {
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

// Gives back a lock lock_acquire took: its file goes, unless it no longer names this process (another took it over
// as stale: it is theirs now).
lock_release :: proc(lock: Lock) {
	if holder := lock_holder(lock.path); holder.found && holder.text == lock_owner() do os.remove(lock.path)
	for held, i in small_array.slice(&held_locks) {
		if held == lock.path {
			small_array.ordered_remove(&held_locks, i)
			break
		}
	}
}

// Releases every lock this thread still holds, newest first (unwind: a failing exit skips the `defer`s that would).
lock_release_all :: proc() {
	for small_array.len(held_locks) > 0 do lock_release({small_array.get(held_locks, small_array.len(held_locks) - 1)})
}

// How old a lock may be before lock_acquire takes it over whoever holds it: longer than any build or unpack it guards.
LOCK_STALE :: 10 * time.Minute
// How long a lock file may hold no pid before lock_acquire takes it over: its process writes the pid right after
// creating it, so one still empty after this was killed in between. Also how long a takeover's guard may stay.
LOCK_UNWRITTEN :: 5 * time.Second

// The locks this thread holds (lock_acquire), for lock_release_all: the CLI takes them on its main thread; the tests,
// running in parallel threads, each see their own. A fixed array: nothing here outlives an allocator.
@(private, thread_local)
held_locks: small_array.Small_Array(HELD_LOCKS_MAX, string)
// How many locks one thread may hold at once (two nested is the most any command takes).
@(private)
HELD_LOCKS_MAX :: 8

// What a lock file holds while this process holds it: its pid, a line.
@(private)
lock_owner :: proc() -> string {
	return aprintf("%d\n", os.get_pid())
}

// A lock file as lock_acquire saw it: its text and modification time; found false when there was none.
@(private)
Lock_Holder :: struct {
	text:     string,
	modified: time.Time,
	found:    bool,
}

// Reads the lock file at `path` (lock_acquire's).
@(private)
lock_holder :: proc(path: string) -> Lock_Holder {
	info, stat_err := os.stat(path, context.temp_allocator)
	if stat_err != nil do return {}
	text, _ := read_text(path)
	return {text = text, modified = info.modification_time, found = true}
}

// Whether a lock file's holder is gone (its pid runs no more), it is older than LOCK_STALE, or it has held no pid for
// LOCK_UNWRITTEN.
@(private)
lock_stale :: proc(holder: Lock_Holder) -> bool {
	if !holder.found do return false
	age := time.diff(holder.modified, time.now())
	if age > LOCK_STALE do return true
	if pid, parsed := strconv.parse_int(strings.trim_space(holder.text)); parsed do return !process_runs(pid, "")
	return holder.text == "" && age > LOCK_UNWRITTEN
}

// Removes the stale lock file at `path` that lock_acquire saw as `seen`, unless it changed since: two waiters that both
// saw it stale take turns through a guard file (<path>.takeover, exclusive create), and the one holding it removes the
// lock only when it is still the one they judged. The other then finds the lock gone, or another waiter's live one,
// never removing a lock just taken. A guard older than LOCK_UNWRITTEN was left by a process killed while holding it,
// and goes.
@(private)
lock_take_over :: proc(path: string, seen: Lock_Holder) {
	guard := aprintf("%s.takeover", path)
	file, err := os.open(guard, {.Write, .Create, .Excl})
	if err != nil {
		if left := lock_holder(guard); left.found && time.diff(left.modified, time.now()) > LOCK_UNWRITTEN {
			os.remove(guard)
		}
		time.sleep(20 * time.Millisecond)
		return
	}
	os.close(file)
	defer os.remove(guard)
	now := lock_holder(path)
	if now.found && now.text == seen.text && now.modified == seen.modified do os.remove(path)
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
