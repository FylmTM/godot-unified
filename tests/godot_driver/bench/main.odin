// The wake row of `uni bench`: how late the session thread wakes from its sleeps on this machine (godot.measure_wakes:
// the session thread's class and power requests on this platform, a thread per tick rate, all at once, each
// sleeping to every tick's due time). Idle, then under load: a spinning thread per logical core, at normal priority
// (a game's main and render threads and Godot's workers busy beside the session). One JSON line.
package godot_wake_bench

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:sync"
import "core:thread"

import "unified:godot"

TICK_HZ := []int{32, 64, 128}
SECONDS :: 1.5

Rate :: struct {
	hz:             int,
	using lateness: godot.Wake_Summary,
}

Report :: struct {
	seconds: f64,
	cores:   int, // the load's spinning threads
	idle:    []Rate,
	loaded:  []Rate,
}

stop_load: bool // atomic
spun: u64 // the spinners' last values (atomic), so their loops are kept

measure :: proc() -> []Rate {
	summaries := godot.measure_wakes(TICK_HZ, SECONDS)
	rates := make([]Rate, len(TICK_HZ))
	for summary, i in summaries do rates[i] = {TICK_HZ[i], summary}
	return rates
}

main :: proc() {
	report := Report {
		seconds = SECONDS,
		cores   = max(os.get_processor_core_count(), 1),
	}
	report.idle = measure()
	load := make([]^thread.Thread, report.cores)
	for &spinner in load {
		spinner = thread.create_and_start(proc() {
			value: u64 = 1
			for !sync.atomic_load(&stop_load) {
				for _ in 0 ..< 1000 do value = value * 6364136223846793005 + 1442695040888963407
			}
			sync.atomic_add(&spun, value)
		})
	}
	report.loaded = measure()
	sync.atomic_store(&stop_load, true)
	for spinner in load {
		thread.join(spinner)
		thread.destroy(spinner)
	}
	line, err := json.marshal(report)
	if err != nil {
		fmt.eprintln("wake bench: cannot write the report")
		os.exit(1)
	}
	fmt.println(string(line))
}
