package cli

import "core:encoding/json"
import "core:strings"
import "core:time"

// `bench --views`: the Godot host's main-thread view sync (unified's own repo: tests/godot_views/view_bench.gd on the
// view test extension, built release), one Godot run per instance count, one after another so the timings are clean.

// The MultiMesh instance counts, and how long each run measures (after its second of warm-up).
VIEW_BENCH_COUNTS :: []int{1000, 4000, 16000}
VIEW_BENCH_SECONDS :: "2"
// A warm run (Godot started three times, three seconds each), not counting a stale extension's build.
VIEW_BENCH_BUDGET :: 15

// `bench -h`: what --views measures and how to run it.
@(private)
bench_details :: proc() -> string {
	return aprintf(
		"--views (unified's repo): the Godot host's main-thread view sync per frame, the cost every rendered frame\n" +
		"pays on top of the game's own: a single player session of the view test game (tests/godot_views/view_bench.gd)\n" +
		"making every tick N moving MultiMesh instances (N = 1k, 4k, 16k; one Godot run each), 64 moving scene views\n" +
		"and a few events a second. Prints per frame the MultiMesh build (every instance interpolated into its buffer)\n" +
		"and upload (set_buffer), the scene views, the event delivery (and per event), into .out/view_bench.json.\n" +
		"Budget %ds. Headless, set_buffer reaches Godot's dummy renderer: `./uni bench --views --window --mute --screen\n" +
		"left` measures the real one (a window that never takes focus; frames paced by the display).",
		VIEW_BENCH_BUDGET,
	)
}

@(private)
View_Bench_Line :: struct {
	instances:       int,
	scene_views:     int,
	fps:             f64,
	fresh:           int, // frames that showed a new tick
	scene_us:        f64, // per frame
	multi_build_us:  f64,
	multi_upload_us: f64,
	delivery_us:     f64,
	total_us:        f64,
	total_max_us:    f64,
	events:          int,
	event_us:        f64, // per event delivered
}

@(private)
bench_views :: proc(window: bool, place: Window_Opts) -> Result {
	if !is_unified_repo() {
		usage("bench --views runs in unified's own repo (tests/godot_views)")
	}
	dir := join(state.project.root, "tests", "godot_views")
	ensure_bindings()
	flags: [dynamic]string
	append(&flags, "-build-mode:dll")
	append(&flags, ..mode_flags(.release))
	build := Build {
		pkg   = join(dir, "ext"),
		out   = join(dir, ".out", "bin", lib_name("views_test")),
		flags = flags[:],
	}
	if stale(build) {
		odin_build(build, "building tests/godot_views/ext (release)")
		cold("the view test extension (release)")
	}
	write_extension_list_dir(dir)
	cleanup := window ? with_window(dir, place) : no_cleanup
	defer cleanup(dir)
	lines: [dynamic]View_Bench_Line
	failed: [dynamic]string
	for count in VIEW_BENCH_COUNTS {
		cmd: [dynamic]string
		append(&cmd, godot())
		if window {
			append(&cmd, "--resolution", "1280x720")
			append(&cmd, ..window_args(place))
		} else {
			append(&cmd, "--headless")
		}
		append(&cmd, "--path", dir, "-s", "res://view_bench.gd", "--", "--bench", aprintf("%d", count))
		append(&cmd, "--seconds", VIEW_BENCH_SECONDS)
		ran := run_proc({cmd = cmd[:], capture = true, quiet = true, timeout = 60 * time.Second})
		out := strings.concatenate({ran.stdout, ran.stderr})
		line, found := view_bench_line(out)
		if !ran.ok || !found || len(godot_errors(out)) > 0 {
			log("uni: bench --views at %d instances failed (exit %d):\n%s", count, ran.exit_code, tail(out, 3000))
			append(&failed, aprintf("%d", count))
			continue
		}
		append(&lines, line)
		log(
			"%6d instances  %5.1f µs/frame: multimesh build %5.1f + upload %5.1f, %d scene views %5.1f, events %4.1f (%4.1f µs each); slowest frame %5.0f µs; %.0f fps",
			line.instances,
			line.total_us,
			line.multi_build_us,
			line.multi_upload_us,
			line.scene_views,
			line.scene_us,
			line.delivery_us,
			line.event_us,
			line.total_max_us,
			line.fps,
		)
	}
	if data, err := json.marshal(lines[:], {pretty = true}); err == nil {
		write_file(join(state.project.out, window ? "view_bench_window.json" : "view_bench.json"), data)
	}
	if len(failed) > 0 {
		return {ok = false, summary = aprintf("bench --views failed at %s instances", strings.join(failed[:], ", "))}
	}
	return {
		ok      = true,
		summary = aprintf(
			"bench --views: the main thread's view sync (%s Godot), reported in .out/%s",
			window ? "windowed" : "headless",
			window ? "view_bench_window.json" : "view_bench.json",
		),
		data    = new_clone(lines[:])^,
		budget  = VIEW_BENCH_BUDGET,
	}
}

// The `VIEW BENCH {json}` line view_bench.gd prints.
@(private)
view_bench_line :: proc(out: string) -> (line: View_Bench_Line, ok: bool) {
	MARKER :: "VIEW BENCH "
	for text in strings.split_lines(out) {
		if !strings.has_prefix(text, MARKER) do continue
		if json.unmarshal_string(text[len(MARKER):], &line) != nil do return {}, false
		return line, true
	}
	return {}, false
}
