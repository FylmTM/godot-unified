// The session-thread watchdog (dev UI builds; src/godot/README.md, How it works): a thread beside the session's that
// counts its own polls, so a suspended laptop or a process stopped in a debugger never looks like a freeze. A step
// (host_step / client_step) that stays in progress for `watchdog_polls` polls in a row is a freeze: the watchdog writes
// <user data>/feedback/freeze-<local time>/ (freeze.json: the tick, whether it froze in fill_frame, the zone stack;
// the session's recording plus the inputs of the ticks after the last verified one, so the folder replays headless
// into the same tick and freezes there under a debugger; on Windows a minidump of every thread), says so on stderr and
// aborts (watchdog_fire). Off with `--no-watchdog`, and while a debugger is attached where the platform can tell.
package godot

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:sync"
import "core:thread"
import "core:time"
import "unified:netcode"
import "unified:sim"

// How often the watchdog looks (its own running time).
watchdog_poll_ms := 250

// Polls in a row that see one step in progress before it is a freeze (5 s of the watchdog's own time by default).
watchdog_polls := 20

// What the watchdog does after writing its dump: abort the process (a test replaces it).
watchdog_fire: proc() = proc() {runtime.trap()}

// The freeze detector over the session thread's step counter (odd: a step in progress), one poll at a time.
Watchdog_Detector :: struct {
	last: u64, // the counter at the last poll
	same: int, // polls in a row that saw it odd and unchanged
}

// One poll of the step counter: true once the same step has been in progress for `polls` polls in a row (an even
// counter, or one that moved, starts over).
watchdog_poll :: proc(detector: ^Watchdog_Detector, step_seq: u64, polls: int) -> (frozen: bool) {
	if step_seq & 1 == 1 && step_seq == detector.last {
		detector.same += 1
	} else {
		detector.same = step_seq & 1 == 1 ? 1 : 0
	}
	detector.last = step_seq
	return detector.same >= polls
}

// The watchdog's thread (session start, dev UI builds with Start.watchdog): polls until the session ends or it fires.
@(private)
watchdog_run :: proc(driver: ^Driver($G, $View, $MultiView)) {
	detector: Watchdog_Detector
	for !sync.atomic_load(&driver.watchdog_stop) {
		time.sleep(time.Duration(watchdog_poll_ms) * time.Millisecond)
		if debugger_attached() {
			detector = {}
			continue
		}
		if !watchdog_poll(&detector, sync.atomic_load(&driver.step_seq), watchdog_polls) do continue
		dir := watchdog_dump(driver)
		fmt.eprintfln(
			"unified: the session thread froze (a step in progress for %d ms of the watchdog's time); dump: %s",
			watchdog_polls * watchdog_poll_ms,
			dir,
		)
		watchdog_fire()
		return
	}
}

// Writes the freeze's folder and returns its path (read racily: the session thread is stuck in a step, and nothing
// else writes what is read here).
@(private)
watchdog_dump :: proc(driver: ^Driver($G, $View, $MultiView)) -> string {
	PLAYERS :: sim.part(G, sim.GAME_PLAYERS)
	now := time.now()
	year, month, day := time.date(now)
	hour, minute, second := time.clock(now)
	dir := fmt.tprintf(
		"%s/freeze-%04d-%02d-%02d_%02d%02d%02d",
		driver.req.dumps,
		year,
		int(month),
		day,
		hour,
		minute,
		second,
	)
	_ = os.make_directory_all(dir)
	Freeze_Json :: struct {
		game:      string,
		tick:      u32, // the tick being stepped (in fill_frame: the one being filled)
		verified:  u32,
		in_fill:   bool, // frozen in the game's fill_frame, not in its tick
		zones:     []string, // the zone stack when it froze, outermost first ("frozen in steer > combat")
		recording: bool, // snapshot.unis and inputs.unil replay into the frozen tick
		from_tick: u32,
		to_tick:   u32, // the log's last tick: the frozen one when the inputs were known
		net:       Freeze_Net,
	}
	out := Freeze_Json {
		game    = api.game_name,
		in_fill = sync.atomic_load(&driver.in_fill),
	}
	client := driver.client
	if client != nil {
		out.verified = client.verified
		out.net = {client.stats.rollbacks, client.stats.resim_ticks, client.stats.stall_ticks, client.stats.rtt_ms}
		if simulation := client.sim; simulation != nil {
			out.tick = out.in_fill ? simulation.tick : simulation.tick + 1
			if dev := simulation.dev; dev != nil {
				zones := make([dynamic]string, context.temp_allocator)
				for open in dev.stack[:clamp(dev.depth, 0, sim.ZONE_DEPTH)] do append(&zones, dev.groups[open.index])
				out.zones = zones[:]
			}
		}
	}
	// the recording, and the ticks after it that the client stepped (verified + 1 ..= the frozen tick)
	recording := &driver.recording
	if sync.mutex_try_lock(&recording.mu) {
		snapshot := make([dynamic]u8, context.temp_allocator)
		input_log := make([dynamic]u8, context.temp_allocator)
		has := recording.snapshot != nil
		if has {
			append(&snapshot, ..recording.snapshot)
			append(&input_log, ..recording.log[:])
			out.from_tick, out.to_tick = recording.from, recording.last
		}
		sync.mutex_unlock(&recording.mu)
		if has && client != nil {
			stream := sim.Log_Stream {
				sink = sim.log_sink_memory(&input_log),
				size = len(input_log),
				ok   = true,
			}
			for tick := out.to_tick + 1; tick <= out.tick; tick += 1 {
				inputs := netcode.client_inputs(client, tick)
				if inputs == nil do break
				sim.log_stream_tick(&stream, inputs)
				out.to_tick = tick
			}
			delete(stream.writer.buf)
			ok := os.write_entire_file(fmt.tprintf("%s/snapshot.unis", dir), snapshot[:]) == nil
			ok &&= os.write_entire_file(fmt.tprintf("%s/inputs.unil", dir), input_log[:]) == nil
			out.recording = ok
		}
	}
	text, err := json.marshal(out, {pretty = true}, context.temp_allocator)
	if err == nil do _ = os.write_entire_file(fmt.tprintf("%s/freeze.json", dir), text)
	write_minidump(fmt.tprintf("%s/freeze.dmp", dir))
	return dir
}

// The client's counters a freeze report names.
@(private)
Freeze_Net :: struct {
	rollbacks:   int,
	resim_ticks: int,
	stall_ticks: int,
	rtt_ms:      f64,
}

// The watchdog's thread (a name of its own: the Driver's `thread` field shadows the package in its declaration).
@(private)
Watchdog_Thread :: thread.Thread

// Starts the watchdog beside the session thread (dev UI builds, unless the start asked for none).
@(private)
watchdog_start :: proc(driver: ^Driver($G, $View, $MultiView)) {
	when !DEVUI do return
	if !driver.req.watchdog || driver.req.dumps == "" do return
	driver.watchdog = thread.create_and_start_with_poly_data(driver, watchdog_run)
}

// Stops and joins the watchdog (the session's end).
@(private)
watchdog_end :: proc(driver: ^Driver($G, $View, $MultiView)) {
	if driver.watchdog == nil do return
	sync.atomic_store(&driver.watchdog_stop, true)
	thread.join(driver.watchdog)
	thread.destroy(driver.watchdog)
	driver.watchdog = nil
}
