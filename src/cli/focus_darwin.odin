package cli

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:thread"
import "core:time"

// macOS: Godot activates its app whenever it shows the main window, no_focus or not (DisplayServerMacOS::show_window
// in 4.7.2), so the flag alone can't keep a window in the background there. While a background window is open, a
// watcher hands focus back to the app that was in front the moment a Godot that uni started comes to the front. It
// polls every FOCUS_POLL, so such a window holds the keyboard for about that long at most.
FOCUS_POLL :: 25 * time.Millisecond

@(private = "file")
Focus_Guard :: struct {
	worker: ^thread.Thread,
	stop:   bool, // atomic
	front:  string, // the ASN of the app in front when the window opened
	bundle: string, // its bundle id, which `open -b` activates
	handed: int, // how many times focus was handed back (read after the join)
}

@(private = "file")
guard: Focus_Guard

// Remembers the app in front and starts the watcher (`with_window`, for a background window); nothing when no app
// is in front.
start_focus_guard :: proc() {
	front := lsappinfo("front")
	bundle := lsappinfo_value(lsappinfo(fmt.tprintf("info -only bundleid %s", front)))
	if front == "" || bundle == "" || bundle == "[ NULL ]" {
		return
	}
	guard = {
		front  = strings.clone(front),
		bundle = strings.clone(bundle),
	}
	guard.worker = thread.create_and_start(watch_focus)
}

// Stops the watcher once the window's Godot has ended; with --verbose, says how often it gave the focus back.
stop_focus_guard :: proc() {
	if guard.worker == nil {
		return
	}
	sync.atomic_store(&guard.stop, true)
	thread.join(guard.worker)
	thread.destroy(guard.worker)
	guard.worker = nil
	if guard.handed > 0 && state.verbose {
		log("uni: gave the focus back to %s %d time(s) (Godot activates itself on macOS)", guard.bundle, guard.handed)
	}
}

@(private = "file")
watch_focus :: proc() {
	ours_by_asn: map[string]bool // whether an app seen in front is a Godot that uni started
	defer {
		for asn in ours_by_asn {
			delete(asn)
		}
		delete(ours_by_asn)
	}
	was_ours := false
	for !sync.atomic_load(&guard.stop) {
		front := lsappinfo("front")
		ours := false
		if front != "" && front != guard.front {
			seen: bool
			ours, seen = ours_by_asn[front]
			if !seen {
				pid, _ := strconv.parse_int(lsappinfo_value(lsappinfo(fmt.tprintf("info -only pid %s", front))))
				if pid > 0 {
					info, err := os.process_info_by_pid(pid, {.PPid}, context.temp_allocator)
					ours = err == nil && info.ppid == os.get_pid()
				}
				ours_by_asn[strings.clone(front)] = ours
			}
			if ours {
				shell(fmt.tprintf("open -b %s", guard.bundle))
				if !was_ours {
					guard.handed += 1
				}
			}
		}
		was_ours = ours
		free_all(context.temp_allocator)
		time.sleep(FOCUS_POLL)
	}
}

// `lsappinfo <args>`'s output (in the temp allocator).
@(private = "file")
lsappinfo :: proc(args: string) -> string {
	return shell(fmt.tprintf("lsappinfo %s", args))
}

// The value of lsappinfo's `"key"=value` line, unquoted.
@(private = "file")
lsappinfo_value :: proc(line: string) -> string {
	eq := strings.index_byte(line, '=')
	return eq < 0 ? "" : strings.trim(strings.trim_space(line[eq + 1:]), "\"")
}

// A command's stdout through /bin/sh, trimmed (in the temp allocator): a poll many times a second, without the
// temp files of run_proc.
@(private = "file")
shell :: proc(command: string) -> string {
	pipe := posix.popen(strings.clone_to_cstring(command, context.temp_allocator), "r")
	if pipe == nil {
		return ""
	}
	buffer: [512]u8
	count := posix.fread(&buffer, 1, len(buffer), pipe)
	posix.pclose(pipe)
	return strings.trim_space(strings.clone(string(buffer[:count]), context.temp_allocator))
}
