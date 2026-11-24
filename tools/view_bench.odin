package main

import "core:encoding/json"
import "core:strings"
import "core:time"

import "unified:cli"

// `view-bench`: the Godot host's main-thread view sync (tests/godot_views/view_bench.gd on the view test extension,
// built release), one Godot run per instance count, one after another so the timings are clean.

// The MultiMesh instance counts, and how long each run measures (after its second of warm-up).
VIEW_BENCH_COUNTS :: []int{1000, 4000, 16000}
VIEW_BENCH_SECONDS :: "2"

View_Bench_Opts :: struct {
	window: bool `usage:"in a window (muted, on the leftmost screen, never taking focus): the real renderer (default: headless, Godot's dummy one)"`,
}

// `view-bench -h`: what it measures.
view_bench_details :: proc() -> string {
	return(
		"The Godot host's main-thread view sync per frame, the cost every rendered frame pays on top of the game's\n" +
		"own: a single player session of the view test game (tests/godot_views/view_bench.gd) making every tick N\n" +
		"moving MultiMesh instances (N = 1k, 4k, 16k; one Godot run each), 64 moving and 64 resting scene views, views\n" +
		"that come and go (two kinds alike but for UnifiedView.pool) and a few events a second. Prints per frame the\n" +
		"MultiMesh build (every instance interpolated into its buffer) and upload (set_buffer), the scene views, and per\n" +
		"spawn a scene view instanced and one taken from its pool, the event delivery (per event, and the event objects\n" +
		"made: the bench view hears every event and keeps none), and per published tick the session\n" +
		"thread's half (its events tracked, fill_frame, the Frame published) and how late its sleeps woke, into\n" +
		".out/view_bench.json. Headless, set_buffer reaches Godot's dummy renderer: --window measures the real one\n" +
		"(frames paced by the display)." \
	)
}

View_Bench_Line :: struct {
	instances:       int,
	scene_views:     int,
	fps:             f64,
	fresh:           int, // frames that showed a new tick
	scene_us:        f64, // per frame
	spawns:          int, // scene views instanced
	spawn_us:        f64, // per spawn: instantiate, data, add_child, _ready
	reuses:          int, // scene views taken from their kind's pool
	reuse_us:        f64, // per reuse: data, pose, add_child, _sim_reused
	multi_build_us:  f64,
	multi_upload_us: f64,
	delivery_us:     f64,
	total_us:        f64,
	total_max_us:    f64,
	events:          int,
	event_us:        f64, // per event delivered
	event_objects:   int, // event objects made (the bench view keeps none: one per class, refilled)
	fill_us:         f64, // the session thread, per published tick
	fill_max_us:     f64,
	wakes:           int, // the session thread's sleeps, how late they woke (godot.Wake_Summary)
	wake_p50_us:     f64,
	wake_p99_us:     f64,
	wake_max_us:     f64,
	wakes_over_tick: int,
}

cmd_view_bench :: proc(args: []string) -> cli.Result {
	opts: View_Bench_Opts
	cli.parse(&opts, args)
	dir := cli.join(cli.state.project.root, "tests", "godot_views")
	cli.ensure_bindings()
	build := cli.project_extension_build(dir, cli.join(dir, "ext"), "views_test", .release)
	if cli.stale(build) {
		cli.odin_build(build, "building tests/godot_views/ext (release)")
	}
	cli.write_extension_list_dir(dir)
	cleanup := opts.window ? cli.with_window(dir, cli.AGENT_WINDOW) : cli.no_cleanup
	defer cleanup(dir)
	lines: [dynamic]View_Bench_Line
	failed: [dynamic]string
	for count in VIEW_BENCH_COUNTS {
		cmd: [dynamic]string
		append(&cmd, cli.godot())
		if opts.window {
			append(&cmd, "--resolution", "1280x720")
			append(&cmd, ..cli.window_args(cli.AGENT_WINDOW))
		} else {
			append(&cmd, "--headless")
		}
		append(&cmd, "--path", dir, "-s", "res://view_bench.gd", "--", "--bench", cli.aprintf("%d", count))
		append(&cmd, "--seconds", VIEW_BENCH_SECONDS)
		ran := cli.run_proc(
			{cmd = cmd[:], capture = true, quiet = true, timeout = 60 * time.Second, env = cli.user_env(dir)},
		)
		out := strings.concatenate({ran.stdout, ran.stderr})
		line, found := view_bench_line(out)
		if !ran.ok || !found || len(cli.godot_errors(out)) > 0 {
			cli.log("uni: view-bench at %d instances failed (exit %d):\n%s", count, ran.exit_code, cli.tail(out, 3000))
			append(&failed, cli.aprintf("%d", count))
			continue
		}
		append(&lines, line)
		cli.log(
			"%6d instances  %5.1f µs/frame: multimesh build %5.1f + upload %5.1f, %d scene views %5.1f (a spawn %4.0f µs instanced, %4.1f from its pool), events %4.1f (%4.1f µs each, %d objects for %d); slowest frame %5.0f µs; %.0f fps; session thread %5.1f µs/tick (slowest %5.0f), its sleeps woke late by p50 %.0f µs, p99 %.0f, max %.0f (%d over a tick)",
			line.instances,
			line.total_us,
			line.multi_build_us,
			line.multi_upload_us,
			line.scene_views,
			line.scene_us,
			line.spawn_us,
			line.reuse_us,
			line.delivery_us,
			line.event_us,
			line.event_objects,
			line.events,
			line.total_max_us,
			line.fps,
			line.fill_us,
			line.fill_max_us,
			line.wake_p50_us,
			line.wake_p99_us,
			line.wake_max_us,
			line.wakes_over_tick,
		)
	}
	file := opts.window ? "view_bench_window.json" : "view_bench.json"
	if data, err := json.marshal(lines[:], {pretty = true}); err == nil {
		cli.write_file(cli.join(cli.state.project.out, file), data)
	}
	if len(failed) > 0 {
		return {ok = false, summary = cli.aprintf("view-bench failed at %s instances", strings.join(failed[:], ", "))}
	}
	return {
		ok      = true,
		summary = cli.aprintf(
			"view-bench: the main thread's view sync (%s Godot), reported in .out/%s",
			opts.window ? "windowed" : "headless",
			file,
		),
		data    = new_clone(lines[:])^,
	}
}

// The `VIEW BENCH {json}` line view_bench.gd prints.
view_bench_line :: proc(out: string) -> (line: View_Bench_Line, ok: bool) {
	MARKER :: "VIEW BENCH "
	for text in strings.split_lines(out) {
		if !strings.has_prefix(text, MARKER) do continue
		if json.unmarshal_string(text[len(MARKER):], &line) != nil do return {}, false
		return line, true
	}
	return {}, false
}
