// `render`: a recording played in the game's own play scene on the replay's frame clock while Godot's movie writer
// writes every frame, kept to the clip and written as a video (.avi), an animated GIF (gif.odin), or PNG frames
// (README.md, Rendering clips).
package cli

import "core:encoding/endian"
import "core:encoding/json"
import "core:image"
import "core:image/png"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:time"

// The frame rates `render` writes at when none is asked: a video's, and a GIF's (a GIF's frames are bigger).
RENDER_FPS :: 30
RENDER_GIF_FPS :: 15
// The fastest GIF: browsers show a delay under 2 hundredths of a second as 10.
RENDER_GIF_FPS_MAX :: 50
// A GIF's window when none is asked, and the widest GIF: a wider render is scaled down to it.
RENDER_GIF_SIZE :: "960x540"
RENDER_GIF_WIDTH_MAX :: 960
// How long a render's Godot run may take.
RENDER_TIMEOUT :: 1800 * time.Second
// The line the game prints once the clip's last frame is on screen (src/godot's FRAME_CLOCK_MARKER).
RENDER_CLIP_MARKER :: "UNIFIED_CLIP "
// Where a render works, under the game's .out/, and the lock file there that keeps a game's renders one at a time.
RENDER_DIR :: "render"
RENDER_LOCK :: "render.lock"
// The names of the PNG frames and audio a directory gets (frame00000000.png, ...: Godot's movie writer's numbering).
RENDER_FRAME_PREFIX :: "frame"
RENDER_AUDIO :: "audio.wav"

@(private)
Render_Opts :: struct {
	out:      string `args:"required" hint:"<file>" usage:"what to write, by its extension: .avi (MJPEG video with the game's sound, Godot's movie writer), .gif (animated, encoded by uni), or a directory (ending in / or one that exists): PNG frames and audio.wav"`,
	from:     string `hint:"<tick|Ns>" usage:"where the clip starts: a tick, or seconds into the recording (4.5s); default its first tick (a later one: the game plays the second before it, cut, so it has settled)"`,
	to:       string `hint:"<tick|Ns>" usage:"where it ends; default the recording's last tick"`,
	at:       string `hint:"<Event_Name[#n]>" usage:"instead of --from and --to: the clip is cut around the n-th (default the first) event of that type in the recording, the game's own type as Odin or GDScript names it (Event_Boss_Slam#2, EventBossSlam), so a recording made again keeps its clip on the same moment; the game finds it by replaying the recording first and refuses an event that never occurs or an n past the last (uni headless <game> -- replay --log <dir>/inputs.unil --any-build --game <game> --events lists them, plus --snapshot <dir>/snapshot.unis when the folder has one)"`,
	before:   string `hint:"<Ns|ticks>" usage:"with --at: how long before the event the clip starts (default 2s)"`,
	after:    string `hint:"<Ns|ticks>" usage:"with --at: how long after it the clip ends (default 3s)"`,
	fps:      int `hint:"<n>" usage:"frames per second (default 30; a GIF 15, at most 50): the clip is frame-exact at any machine speed"`,
	size:     string `hint:"<WxH>" usage:"the window and frame size (default: the project's window; a GIF 960x540, and never wider than 960); side by side: each pane's (default that size divided across the panes)"`,
	player:   string `hint:"<n[,n...]>" usage:"whose view: the player shown as P<n> (slot n-1) where the clip starts (default: whoever recorded it; a recording that doesn't say, such as a replay regression or a co-op run's: P1, its host); several (1,2; up to 4): each one's view of the same recording side by side, left to right, in one clip, frames in exact sync (a render each on the same frame clock), the sound the first one's; a GIF or PNG frames only (a video is one view)"`,
	speed:    string `hint:"<x>" usage:"playback speed, 0.25 to 4 (default 1)"`,
	dither:   bool `usage:"GIF: ordered dither (smoother gradients, a bigger file)"`,
	overflow: [dynamic]string `hint:"[game] <recording>" usage:"the game (default: the only one) and the recording: a folder holding inputs.unil (a session recording, an F3 note, a freeze), a feedback note's name (uni feedback), or a replay regression's (simulation/tests/replays/<name>)"`,
}

// The most views `render --player` lays side by side.
RENDER_PANES_MAX :: 4

// `render -h`'s details.
@(private)
render_details :: proc() -> string {
	return(
		"The game plays the recording in its own play scene, in replay mode, in a window (muted, in the top-left\n" +
		"corner of the leftmost screen, never taking focus), with Godot's movie writer at a fixed frame rate: frame n\n" +
		"always shows the same moment, however slow the machine (the same pixels too, unless the game's GPU\n" +
		"particles draw differently from run to run). The clip starts on the first frame the game shows\n" +
		"the replay's views (a menu or a loading scene before it is cut). The window must fit the leftmost screen.\n" +
		"Side by side (--player 1,2) renders each view in turn and lays their frames out in one clip.\n" +
		"Re-render after the game changes: a recording of an older build plays on, checked against its checkpoints.\n" +
		"The unified-godot skill has how to make a clip for a README." \
	)
}

// What a render made.
Render_Report :: struct {
	out:        string,
	format:     string, // "avi", "gif" or "png"
	frames:     int, // the clip's frames (a GIF folds a frame that changed nothing into the one before: gif_frames)
	fps:        int,
	from, to:   u32, // the ticks it shows
	at:         u32, // --at: the event's tick (0: none)
	first_tick: u32, // the tick its first frame shows (the first at or after `from`)
	tick_hz:    int,
	width:      int,
	height:     int,
	panes:      int, // the views side by side (1: one)
	bytes:      int, // the file's size (png: every frame's)
	gif_frames: int,
	gif_colors: int,
	render_s:   f64, // Godot's runs
	encode_s:   f64, // the GIF's encoding, or the panes' composing (PNG decoding included)
}

@(private)
cmd_render :: proc(args: []string) -> Result {
	opts: Render_Opts
	parse(&opts, args)
	selected: Game
	recording: string
	switch len(opts.overflow) {
	case 1:
		selected, recording = game(""), opts.overflow[0]
	case 2:
		selected, recording = game(opts.overflow[0]), opts.overflow[1]
	case:
		usage("name the recording: uni render [game] <recording> --out <file>")
	}
	if !has_extension(selected) do usage("%s has no extension: nothing replays", selected.name)
	folder, found := render_recording(selected, recording)
	if !found {
		usage(
			"no recording %q: not a folder holding %s, a feedback note of %s (uni feedback), or a replay regression in %s",
			recording,
			REPLAY_INPUTS,
			selected.name,
			join(selected.dir, REPLAYS_DIR),
		)
	}
	report, problem := render(selected, folder, opts)
	if problem != "" do return {ok = false, summary = aprintf("render FAILED: %s", problem)}
	ticks := aprintf("ticks %d to %d", report.from, report.to)
	if report.at != 0 do ticks = aprintf("%s at tick %d, %s", opts.at, report.at, ticks)
	summary := aprintf(
		"%s: %d frames at %d fps (%s), %dx%d%s -> %s (%s) in %.1fs",
		selected.name,
		report.frames,
		report.fps,
		ticks,
		report.width,
		report.height,
		report.panes > 1 ? aprintf(", %d views side by side", report.panes) : "",
		report.out,
		render_size_text(report.bytes),
		report.render_s + report.encode_s,
	)
	if report.format == "gif" {
		summary = aprintf(
			"%s; GIF: %d frames, %d colours, encoded in %.2fs",
			summary,
			report.gif_frames,
			report.gif_colors,
			report.encode_s,
		)
	}
	return {ok = true, summary = summary, data = box(report)}
}

// A byte count as people read it.
@(private)
render_size_text :: proc(bytes: int) -> string {
	if bytes >= 1 << 20 do return aprintf("%.1f MB", f64(bytes) / f64(1 << 20))
	return aprintf("%.0f KB", f64(bytes) / 1024)
}

// The folder `name` names for the game: a folder holding inputs.unil, else the game's feedback note or replay
// regression of that name.
render_recording :: proc(selected: Game, name: string) -> (folder: string, found: bool) {
	cwd, _ := os.get_working_directory(context.allocator)
	candidates: [dynamic]string
	append(&candidates, absolute_path(cwd, name))
	if replay_name_ok(name) {
		feedback := join(game_user_dir(selected.dir), FEEDBACK_DIR)
		append(&candidates, join(feedback, name), join(feedback, FEEDBACK_DONE_DIR, name))
		append(&candidates, absolute_path(cwd, replay_folder(selected.dir, name)))
	}
	for candidate in candidates {
		if os.is_file(join(candidate, REPLAY_INPUTS)) do return candidate, true
	}
	return "", false
}

// What the output path asks for: "avi", "gif" or "png" (a directory); "" when none.
render_format :: proc(out: string) -> string {
	lower := strings.to_lower(out, context.temp_allocator)
	switch {
	case strings.has_suffix(lower, ".avi"):
		return "avi"
	case strings.has_suffix(lower, ".gif"):
		return "gif"
	case strings.has_suffix(out, "/") || strings.has_suffix(out, "\\") || os.is_directory(out):
		return "png"
	}
	return ""
}

// The players --player names, each the n of P<n> ({0}: none named, whoever recorded it); false when it isn't a list of
// 1 to RENDER_PANES_MAX of them, each 1 to 64.
render_players :: proc(text: string) -> (players: []int, ok: bool) {
	if strings.trim_space(text) == "" do return slice.clone([]int{0}), true
	parts := strings.split(text, ",", context.temp_allocator)
	if len(parts) > RENDER_PANES_MAX do return nil, false
	players = make([]int, len(parts))
	for part, i in parts {
		value, parsed := strconv.parse_int(strings.trim_space(part), 10)
		if !parsed || value < 1 || value > 64 do return nil, false
		players[i] = value
	}
	return players, true
}

// The window size of the game's project: its window size override, else its viewport's (Godot's default 1152x648).
@(private)
render_project_size :: proc(selected: Game) -> (size: [2]int) {
	size = {1152, 648}
	config, ok := config_load(join(selected.dir, "project.godot"))
	if !ok do return
	keys := [2][2]string {
		{"window/size/viewport_width", "window/size/window_width_override"},
		{"window/size/viewport_height", "window/size/window_height_override"},
	}
	for axis in 0 ..< 2 {
		for key in keys[axis] {
			if text, found := config_get(config, "display", key); found {
				if value, parsed := strconv.parse_int(strings.trim_space(text), 10); parsed && value > 0 do size[axis] = value
			}
		}
	}
	return
}

// One view's render (render_run): the folder Godot wrote its movie in and the clip line it printed.
Render_Pane :: struct {
	work: string,
	clip: Render_Clip,
}

// The PNG frame `index` of a pane's clip (Godot's movie writer numbers every frame it wrote: the clip's start at the
// pane's own movie_frame).
render_pane_frame :: proc(pane: Render_Pane, index: int) -> string {
	return join(pane.work, aprintf("%s%08d.png", RENDER_FRAME_PREFIX, pane.clip.movie_frame + index))
}

// Renders the recording in `folder` as `opts` ask; why it failed, else "".
render :: proc(
	selected: Game,
	folder: string,
	opts: Render_Opts,
	quiet := false,
) -> (
	report: Render_Report,
	problem: string,
) {
	format := render_format(opts.out)
	if format == "" do usage("--out %s: write a .avi, a .gif, or a directory (ending in /)", opts.out)
	fps := opts.fps != 0 ? opts.fps : (format == "gif" ? RENDER_GIF_FPS : RENDER_FPS)
	if fps < 1 || fps > 240 do usage("--fps takes 1 to 240 (got %d)", fps)
	if format == "gif" && fps > RENDER_GIF_FPS_MAX {
		usage("--fps %d: a GIF plays at most %d (browsers slow faster ones down)", fps, RENDER_GIF_FPS_MAX)
	}
	players, players_ok := render_players(opts.player)
	if !players_ok {
		usage(
			"--player takes the n of P<n>, or up to %d of them (1,2) side by side (got %q)",
			RENDER_PANES_MAX,
			opts.player,
		)
	}
	if len(players) > 1 && format == "avi" {
		usage("--player %s: side by side writes a .gif or PNG frames; a video is one view", opts.player)
	}
	if opts.at != "" && (opts.from != "" || opts.to != "") {
		usage("--at cuts the clip around its event: no --from or --to with it")
	}
	if opts.at == "" && (opts.before != "" || opts.after != "") {
		usage("--before and --after are lengths around --at's event: name one")
	}
	size_text := opts.size != "" ? opts.size : (format == "gif" ? RENDER_GIF_SIZE : "")
	size: [2]int
	if size_text != "" do size = parse_window_size(size_text)
	if len(players) > 1 && opts.size == "" {
		// the clip's size divided across the panes
		whole := size_text != "" ? size : render_project_size(selected)
		size = {whole.x / len(players), whole.y}
	}
	if size != {} do render_check_fits(size)
	cwd, _ := os.get_working_directory(context.allocator)
	out := absolute_path(cwd, opts.out)
	work := absolute_path(cwd, join(selected.dir, ".out", RENDER_DIR))
	// one render of a game at a time: they share the work folder and the project's override.cfg (with_window), so a
	// second (a `uni render` beside the godot suite's render step) waits rather than wiping the first's frames
	lock := lock_acquire(join(selected.dir, ".out", RENDER_LOCK), aprintf("render of %s", selected.name))
	defer lock_release(lock)
	remove_tree(work)
	make_dirs(work)
	ensure_game(selected)
	panes := make([]Render_Pane, len(players))
	for player, i in players {
		pane_work := len(players) == 1 ? work : join(work, aprintf("p%d", i + 1))
		make_dirs(pane_work)
		seconds: f64
		panes[i].work = pane_work
		panes[i].clip, seconds, problem = render_run(
			selected,
			folder,
			opts,
			format,
			fps,
			size,
			player,
			pane_work,
			quiet,
		)
		report.render_s += seconds
		if problem != "" do return report, len(players) > 1 ? aprintf("P%d's view: %s", player, problem) : problem
	}
	clip := panes[0].clip
	if problem = render_panes_agree(panes); problem != "" do return report, problem
	report.format, report.frames, report.fps, report.from, report.to = format, clip.frames, fps, clip.from, clip.to
	report.at, report.first_tick, report.tick_hz, report.panes = clip.at, clip.first_tick, clip.tick_hz, len(panes)
	switch format {
	case "avi":
		movie := join(work, "clip.avi")
		data, err := os.read_entire_file(movie, context.allocator)
		if err != nil do return report, aprintf("Godot wrote no %s", movie)
		trimmed, trim_problem := avi_trim(data, clip.movie_frame, clip.frames)
		if trim_problem != "" do return report, aprintf("%s: %s", movie, trim_problem)
		if !write_file(out, trimmed) do return report, aprintf("cannot write %s", out)
		report.bytes = len(trimmed)
		report.width, report.height = avi_size(trimmed)
	case "png", "gif":
		for pane in panes {
			for i in 0 ..< clip.frames {
				if frame := render_pane_frame(pane, i); !os.is_file(frame) do return report, aprintf("Godot wrote no frame %s", frame)
			}
		}
		if format == "png" {
			make_dirs(out)
			if len(panes) == 1 {
				for i in 0 ..< clip.frames {
					frame := render_pane_frame(panes[0], i)
					target := join(out, aprintf("%s%08d.png", RENDER_FRAME_PREFIX, i))
					os.remove(target)
					if !move_file(frame, target) do return report, aprintf("cannot move %s to %s", frame, target)
					report.bytes += int(file_size(target))
				}
			} else {
				started := time.tick_now()
				report.bytes, problem = render_side_by_side_png(panes, out)
				report.encode_s = seconds_since(started)
				if problem != "" do return report, problem
			}
			// what an older render left past this one's last frame
			for i := clip.frames;; i += 1 {
				stale := join(out, aprintf("%s%08d.png", RENDER_FRAME_PREFIX, i))
				if !os.is_file(stale) do break
				os.remove(stale)
			}
			if wav, err := os.read_entire_file(
				join(panes[0].work, aprintf("%s.wav", RENDER_FRAME_PREFIX)),
				context.allocator,
			); err == nil {
				if audio, audio_ok := wav_trim(wav, clip.movie_frame, clip.frames, fps); audio_ok {
					write_file(join(out, RENDER_AUDIO), audio)
				}
			}
			report.width, report.height = png_size(join(out, aprintf("%s00000000.png", RENDER_FRAME_PREFIX)))
		} else {
			started := time.tick_now()
			gif: []u8
			stats: Gif_Stats
			gif_problem: string
			if len(panes) == 1 {
				frames := make([]string, clip.frames)
				for &frame, i in frames do frame = render_pane_frame(panes[0], i)
				gif, stats, gif_problem = render_gif(frames, fps, opts.dither)
			} else {
				gif, stats, gif_problem = render_side_by_side_gif(panes, fps, opts.dither)
			}
			report.encode_s = seconds_since(started)
			if gif_problem != "" do return report, gif_problem
			if !write_file(out, gif) do return report, aprintf("cannot write %s", out)
			report.bytes = len(gif)
			report.gif_frames, report.gif_colors = stats.frames, stats.colors
			report.width, report.height = int(gif[6]) | int(gif[7]) << 8, int(gif[8]) | int(gif[9]) << 8
		}
	}
	report.out = out
	return report, ""
}

// One Godot run of a render: the recording played on the frame clock under the movie writer at `fps`, at `size` (zero:
// the project's), following `player` (0: whoever recorded it), its movie (clip.avi, or PNG frames and their audio)
// written in `work`; the clip line it printed, how long it took, and why it showed no clip, else "".
@(private)
render_run :: proc(
	selected: Game,
	folder: string,
	opts: Render_Opts,
	format: string,
	fps: int,
	size: [2]int,
	player: int,
	work: string,
	quiet: bool,
) -> (
	clip: Render_Clip,
	seconds: f64,
	problem: string,
) {
	movie := join(work, format == "avi" ? "clip.avi" : aprintf("%s.png", RENDER_FRAME_PREFIX))
	cmd: [dynamic]string
	append(&cmd, godot())
	append(&cmd, ..window_args(AGENT_WINDOW))
	append(&cmd, "--path", selected.dir, "--write-movie", movie, "--fixed-fps", aprintf("%d", fps), "--disable-vsync")
	append(&cmd, "--", "--no-settings", "--local-net", "--quit-at-end", "--replay", folder)
	append(&cmd, "--replay-fps", aprintf("%d", fps))
	if opts.from != "" do append(&cmd, "--replay-from", opts.from)
	if opts.to != "" do append(&cmd, "--replay-to", opts.to)
	if opts.at != "" do append(&cmd, "--replay-at", opts.at)
	if opts.before != "" do append(&cmd, "--replay-before", opts.before)
	if opts.after != "" do append(&cmd, "--replay-after", opts.after)
	if opts.speed != "" do append(&cmd, "--replay-speed", opts.speed)
	if player != 0 do append(&cmd, "--replay-player", aprintf("%d", player))
	// the movie's size is the window size override (a game whose stretch mode is viewport: its viewport's size)
	display := ""
	if size != {} {
		display = aprintf(
			"window/size/window_width_override=%d\nwindow/size/window_height_override=%d\n",
			size.x,
			size.y,
		)
	}
	cleanup := with_window(selected.dir, AGENT_WINDOW, display)
	if !quiet {
		whose := player != 0 ? aprintf(", P%d's view", player) : ""
		log("uni: rendering %s at %d fps%s in a window (Godot's movie writer)", folder, fps, whose)
	}
	ran := run_proc(
	{
		cmd     = cmd[:],
		capture = true,
		timeout = RENDER_TIMEOUT,
		env     = user_env(selected.dir, ..SUITE_OFFLINE_ENV),
		log_to  = join(work, "godot"), // its output kept: godot.stdout, godot.stderr
	},
	)
	cleanup(selected.dir)
	seconds = ran.seconds
	output := strings.concatenate({ran.stdout, ran.stderr})
	has_clip: bool
	clip, has_clip = render_clip_line(output)
	if !has_clip {
		for line in strings.split_lines(output, context.temp_allocator) {
			if at := strings.index(line, "the session failed: "); at >= 0 {
				// the game refused what it was asked (a refusal says why: an event that never occurs, an empty slot)
				return clip, seconds, aprintf("the game showed no clip: %s", line[at + len("the session failed: "):])
			}
		}
		log("%s", tail(output, 4000))
		if ran.timed_out do return clip, seconds, aprintf("Godot timed out after %.0fs", time.duration_seconds(RENDER_TIMEOUT))
		problems := godot_problems(output)
		if len(problems) > 0 do return clip, seconds, aprintf("the game showed no clip: %s", problems[0])
		return clip, seconds, aprintf("the game showed no clip (exit %d; its output is above)", ran.exit_code)
	}
	if !quiet do for line in godot_problems(output) do log("uni: render: %s", line)
	return clip, seconds, ""
}

// Why the panes' renders are not the same moments, else "": each one's clip must show the same ticks in as many frames
// (the frame clock makes them so; a game whose view decides how long its play scene takes to open still starts each
// on its first shown frame).
render_panes_agree :: proc(panes: []Render_Pane) -> string {
	first := panes[0].clip
	for pane, i in panes[1:] {
		clip := pane.clip
		if clip.frames != first.frames ||
		   clip.from != first.from ||
		   clip.to != first.to ||
		   clip.at != first.at ||
		   clip.first_tick != first.first_tick {
			return aprintf(
				"the views' clips differ: the first shows ticks %d to %d in %d frames, view %d ticks %d to %d in %d",
				first.from,
				first.to,
				first.frames,
				i + 2,
				clip.from,
				clip.to,
				clip.frames,
			)
		}
	}
	return ""
}

// Lays `panes` (RGBA images of `width` x `height` each) side by side, left to right, into `out` (RGBA,
// len(panes) * width wide, `height` high).
render_compose :: proc(panes: [][]u8, width, height: int, out: []u8) {
	row := width * 4
	for pane, p in panes {
		for y in 0 ..< height {
			target := (y * len(panes) + p) * row
			copy(out[target:target + row], pane[y * row:(y + 1) * row])
		}
	}
}

// Loads the frame `index` of every pane's clip and lays them side by side into `out` (render_compose); false when one
// doesn't load or its size isn't the first pane's frame's.
@(private)
render_compose_frame :: proc(panes: []Render_Pane, index, width, height: int, out: []u8) -> bool {
	pixels := make([][]u8, len(panes))
	defer delete(pixels)
	images := make([]^png.Image, len(panes))
	defer for img in images do if img != nil do png.destroy(img)
	for pane, p in panes {
		img, err := png.load_from_file(render_pane_frame(pane, index), {.alpha_add_if_missing}, context.allocator)
		if err != nil do return false
		images[p] = img
		if img.width != width || img.height != height || img.channels != 4 || img.depth != 8 do return false
		pixels[p] = img.pixels[:]
	}
	render_compose(pixels, width, height, out)
	return true
}

// The panes' clips side by side as PNG frames in `out` (frame00000000.png, ...), on every core; the bytes written, and
// why not, else "".
render_side_by_side_png :: proc(panes: []Render_Pane, out: string) -> (bytes: int, problem: string) {
	width, height := png_size(render_pane_frame(panes[0], 0))
	if width == 0 do return 0, aprintf("%s is not a PNG", render_pane_frame(panes[0], 0))
	Job :: struct {
		panes:         []Render_Pane,
		out:           string,
		width, height: int,
		bytes:         int, // atomic
		failed:        int, // atomic: a frame that didn't load or write, + 1
	}
	job := Job{panes, out, width, height, 0, 0}
	gif_parallel(panes[0].clip.frames, os.get_processor_core_count(), &job, proc(data: rawptr, index, _: int) {
		job := (^Job)(data)
		img := image.Image {
			width    = len(job.panes) * job.width,
			height   = job.height,
			channels = 4,
			depth    = 8,
		}
		img.pixels = make([dynamic]u8, img.width * img.height * 4)
		defer delete(img.pixels)
		encoded: [dynamic]u8
		defer delete(encoded)
		target := join(job.out, aprintf("%s%08d.png", RENDER_FRAME_PREFIX, index))
		if !render_compose_frame(job.panes, index, job.width, job.height, img.pixels[:]) ||
		   png.save_to_buffer(&encoded, &img, level = .Level_1) != nil ||
		   !write_file(target, encoded[:]) {
			sync.atomic_store(&job.failed, index + 1)
			return
		}
		sync.atomic_add(&job.bytes, len(encoded))
	})
	if job.failed != 0 {
		return job.bytes, aprintf("frame %d of the views side by side did not load or write", job.failed - 1)
	}
	return job.bytes, ""
}

// The panes' clips side by side as an animated GIF (gif_encode), scaled down to at most RENDER_GIF_WIDTH_MAX wide;
// why not, else "".
render_side_by_side_gif :: proc(
	panes: []Render_Pane,
	fps: int,
	dither: bool,
) -> (
	gif: []u8,
	stats: Gif_Stats,
	problem: string,
) {
	width, height := png_size(render_pane_frame(panes[0], 0))
	if width == 0 do return nil, {}, aprintf("%s is not a PNG", render_pane_frame(panes[0], 0))
	whole := len(panes) * width
	gif_width, gif_height := gif_size(whole, height, RENDER_GIF_WIDTH_MAX)
	Frames :: struct {
		panes:                 []Render_Pane,
		width, height:         int,
		gif_width, gif_height: int,
	}
	source_frames := Frames{panes, width, height, gif_width, gif_height}
	source := Gif_Source {
		count = panes[0].clip.frames,
		width = gif_width,
		height = gif_height,
		fps = fps,
		data = &source_frames,
		frame = proc(data: rawptr, index: int, out: []u8) -> bool {
			frames := (^Frames)(data)
			whole := len(frames.panes) * frames.width
			if whole == frames.gif_width && frames.height == frames.gif_height {
				return render_compose_frame(frames.panes, index, frames.width, frames.height, out)
			}
			composed := make([]u8, whole * frames.height * 4)
			defer delete(composed)
			if !render_compose_frame(frames.panes, index, frames.width, frames.height, composed) do return false
			gif_downscale(composed, whole, frames.height, out, frames.gif_width, frames.gif_height)
			return true
		},
	}
	ok: bool
	gif, stats, ok = gif_encode(source, {dither = dither})
	if !ok do return nil, {}, "a PNG frame did not load (or its size differs from the first)"
	return gif, stats, ""
}

// A render's window must fit the leftmost screen where the OS says how big it is (one bigger would reach onto the
// next screen, and the movie writer records the window's size at its start).
@(private)
render_check_fits :: proc(size: [2]int) {
	screens := os_screens()
	if len(screens) == 0 do return
	leftmost := screens[0]
	for screen in screens do if screen.left < leftmost.left do leftmost = screen
	if width := int(leftmost.right - leftmost.left); size.x > width {
		usage("--size %dx%d is wider than the leftmost screen (%d px): pick a smaller size", size.x, size.y, width)
	}
}

// The clip line the game printed (src/godot's frame_clock_end): which movie frames are the clip, and its ticks.
Render_Clip :: struct {
	movie_frame: int,
	frames:      int,
	from, to:    u32,
	at:          u32, // a clip cut around an event (--at): its tick (0: none)
	first_tick:  u32, // the tick the game showed in the movie frame `movie_frame` (0: none)
	fps:         int,
	tick_hz:     int,
}

// The clip line in a render's output; false when the game printed none.
render_clip_line :: proc(output: string) -> (clip: Render_Clip, found: bool) {
	for line in strings.split_lines(output, context.temp_allocator) {
		at := strings.index(line, RENDER_CLIP_MARKER)
		if at < 0 do continue
		if json.unmarshal_string(line[at + len(RENDER_CLIP_MARKER):], &clip) == nil && clip.frames > 0 {
			found = true
		}
	}
	return
}

// Whether a game can open a window here: always on Windows and macOS, on Linux with an X or Wayland display (CI's Linux
// has none).
has_display :: proc() -> bool {
	when ODIN_OS == .Linux {
		return(
			os.get_env("DISPLAY", context.temp_allocator) != "" ||
			os.get_env("WAYLAND_DISPLAY", context.temp_allocator) != "" \
		)
	}
	return true
}

// The size of a file in bytes (0: none).
@(private)
file_size :: proc(path: string) -> i64 {
	info, err := os.stat(path, context.temp_allocator)
	return err == nil ? info.size : 0
}

// A PNG file's width and height (0, 0: not a PNG).
@(private)
png_size :: proc(path: string) -> (int, int) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil || len(data) < 24 do return 0, 0
	width, _ := endian.get_u32(data[16:20], .Big)
	height, _ := endian.get_u32(data[20:24], .Big)
	return int(width), int(height)
}

// The PNG frames, in order, as an animated GIF (gif_encode) at most RENDER_GIF_WIDTH_MAX wide; why not, else "".
@(private)
render_gif :: proc(frames: []string, fps: int, dither: bool) -> (gif: []u8, stats: Gif_Stats, problem: string) {
	width, height := png_size(frames[0])
	if width == 0 do return nil, {}, aprintf("%s is not a PNG", frames[0])
	gif_width, gif_height := gif_size(width, height, RENDER_GIF_WIDTH_MAX)
	Frames :: struct {
		paths:                 []string,
		width, height:         int,
		gif_width, gif_height: int,
	}
	source_frames := Frames{frames, width, height, gif_width, gif_height}
	source := Gif_Source {
		count = len(frames),
		width = gif_width,
		height = gif_height,
		fps = fps,
		data = &source_frames,
		frame = proc(data: rawptr, index: int, out: []u8) -> bool {
			frames := (^Frames)(data)
			return png_frame(
				frames.paths[index],
				frames.width,
				frames.height,
				out,
				frames.gif_width,
				frames.gif_height,
			)
		},
	}
	ok: bool
	gif, stats, ok = gif_encode(source, {dither = dither})
	if !ok do return nil, {}, "a PNG frame did not load (or its size differs from the first)"
	return gif, stats, ""
}

// Loads a PNG frame of `width` x `height` as RGBA into `out`, scaled down to `out_width` x `out_height`; false when it
// doesn't load or is of another size. Called from several threads at once.
png_frame :: proc(path: string, width, height: int, out: []u8, out_width, out_height: int) -> bool {
	img, err := png.load_from_file(path, {.alpha_add_if_missing}, context.allocator)
	if err != nil do return false
	defer png.destroy(img)
	if img.width != width || img.height != height || img.channels != 4 || img.depth != 8 do return false
	pixels := img.pixels[:]
	if out_width == width && out_height == height {
		copy(out, pixels)
	} else {
		gif_downscale(pixels, width, height, out, out_width, out_height)
	}
	return true
}

// ---- AVI and WAV: cutting Godot's movie to the clip

// The fourcc at `data[offset:]`.
@(private)
fourcc :: proc(data: []u8, offset: int) -> string {
	return offset + 4 <= len(data) ? string(data[offset:offset + 4]) : ""
}

@(private)
riff_u32 :: proc(data: []u8, offset: int) -> int {
	value, _ := endian.get_u32(data[offset:offset + 4], .Little)
	return int(value)
}

@(private)
riff_put :: proc(data: []u8, offset, value: int) {
	endian.put_u32(data[offset:offset + 4], .Little, u32(value))
}

// The frame size an AVI's main header gives (0, 0: none).
avi_size :: proc(avi: []u8) -> (int, int) {
	at := strings.index(string(avi[:min(len(avi), 1024)]), "avih")
	if at < 0 || at + 48 > len(avi) do return 0, 0
	return riff_u32(avi, at + 8 + 32), riff_u32(avi, at + 8 + 36)
}

// An AVI (RIFF: hdrl, then movi's chunks frame by frame: a video chunk, then the other streams' chunks until the next
// one, then idx1, as Godot's MJPEG movie writer writes it) cut to its frames `first` ..< `first + count`: the headers'
// frame and sample counts, the movi list and the index rewritten. Why it can't, else "".
avi_trim :: proc(avi: []u8, first, count: int) -> (out: []u8, problem: string) {
	if fourcc(avi, 0) != "RIFF" || fourcc(avi, 8) != "AVI " do return nil, "not an AVI"
	Chunk :: struct {
		id:     string,
		offset: int, // of its id
		size:   int, // its data's
	}
	hdrl, movi := -1, -1 // the LIST chunks' offsets
	hdrl_size := 0
	for at := 12; at + 8 <= len(avi); {
		id, size := fourcc(avi, at), riff_u32(avi, at + 4)
		if id == "LIST" && fourcc(avi, at + 8) == "hdrl" do hdrl, hdrl_size = at, size
		if id == "LIST" && fourcc(avi, at + 8) == "movi" {
			movi = at
			break // its size is the one place Godot may leave short of the truth: the chunks after it are walked
		}
		at += 8 + size + (size & 1)
	}
	if hdrl < 0 || movi < 0 do return nil, "no hdrl or movi list"
	// the movi chunks, by frame (a frame: its video chunk and what follows it before the next)
	chunks: [dynamic]Chunk
	frame_starts: [dynamic]int // index into chunks
	for at := movi + 12; at + 8 <= len(avi); {
		id, size := fourcc(avi, at), riff_u32(avi, at + 4)
		if id == "idx1" || id == "LIST" || id == "RIFF" do break
		if at + 8 + size > len(avi) do return nil, "a chunk runs past the end"
		if strings.has_suffix(id, "dc") || strings.has_suffix(id, "db") do append(&frame_starts, len(chunks))
		append(&chunks, Chunk{id, at, size})
		at += 8 + size + (size & 1)
	}
	total := len(frame_starts)
	if first < 0 || count <= 0 || first + count > total {
		return nil, aprintf("frames %d to %d asked of %d", first, first + count - 1, total)
	}
	low := frame_starts[first]
	high := first + count < total ? frame_starts[first + count] : len(chunks)
	kept := chunks[low:high]
	// the headers, their counts set for the kept frames
	header := make([]u8, hdrl + 8 + hdrl_size)
	copy(header, avi[:len(header)])
	avi_counts(header, hdrl + 12, len(header), count, total)
	result := make([dynamic]u8, 0, len(avi))
	append(&result, ..header)
	movi_at := len(result)
	append(&result, 'L', 'I', 'S', 'T', 0, 0, 0, 0, 'm', 'o', 'v', 'i')
	index := make([dynamic]u8, 0, 16 * len(kept) + 8)
	append(&index, 'i', 'd', 'x', '1', 0, 0, 0, 0)
	for chunk in kept {
		entry: [16]u8
		copy(entry[:4], chunk.id)
		riff_put(entry[:], 4, 16) // AVIIF_KEYFRAME
		riff_put(entry[:], 8, len(result) - (movi_at + 8)) // from the movi fourcc
		riff_put(entry[:], 12, chunk.size)
		append(&index, ..entry[:])
		append(&result, ..avi[chunk.offset:chunk.offset + 8 + chunk.size + (chunk.size & 1)])
	}
	riff_put(result[:], movi_at + 4, len(result) - (movi_at + 8))
	riff_put(index[:], 4, len(index) - 8)
	append(&result, ..index[:])
	riff_put(result[:], 4, len(result) - 8)
	return result[:], ""
}

// Sets the frame counts in the header chunks between `from` and `to` (a LIST's contents, any LIST in it too) to
// `count` of `total` frames: the main header's and the video stream's frames, OpenDML's, and the other streams' lengths
// in proportion.
@(private)
avi_counts :: proc(header: []u8, from, to, count, total: int) {
	for at := from; at + 8 <= to; {
		id, size := fourcc(header, at), riff_u32(header, at + 4)
		switch id {
		case "avih":
			riff_put(header, at + 8 + 16, count) // dwTotalFrames
		case "strh":
			length := at + 8 + 32 // dwLength
			if fourcc(header, at + 8) == "vids" {
				riff_put(header, length, count)
			} else {
				riff_put(header, length, int(i64(riff_u32(header, length)) * i64(count) / i64(total)))
			}
		case "dmlh":
			riff_put(header, at + 8, count) // dwTotalFrames
		case "LIST":
			avi_counts(header, at + 12, min(at + 8 + size, to), count, total)
		}
		at += 8 + size + (size & 1)
	}
}

// A WAV (RIFF WAVE: fmt, then data, as Godot's PNG movie writer writes it, a block of mix_rate / fps samples a frame)
// cut to the audio of frames `first` ..< `first + count` at `fps`; false when it isn't such a WAV.
wav_trim :: proc(wav: []u8, first, count, fps: int) -> (out: []u8, ok: bool) {
	if fourcc(wav, 0) != "RIFF" || fourcc(wav, 8) != "WAVE" do return
	rate, align := 0, 0
	data, data_size := -1, 0
	for at := 12; at + 8 <= len(wav); {
		id, size := fourcc(wav, at), riff_u32(wav, at + 4)
		if id == "fmt " && at + 24 <= len(wav) {
			rate = riff_u32(wav, at + 12)
			align = int(wav[at + 20]) | int(wav[at + 21]) << 8
		}
		if id == "data" {
			data, data_size = at + 8, min(size, len(wav) - at - 8)
			break
		}
		at += 8 + size + (size & 1)
	}
	if data < 0 || rate == 0 || align == 0 do return
	block := rate / fps * align
	start := min(first * block, data_size)
	end := min((first + count) * block, data_size)
	result := make([]u8, data + end - start)
	copy(result, wav[:data])
	copy(result[data:], wav[data + start:data + end])
	riff_put(result, data - 4, end - start)
	riff_put(result, 4, len(result) - 8)
	return result, true
}

// ---- the godot suite's render step

// How much around its event the godot suite's `render` step renders, at what rate and size.
RENDER_CHECK_AROUND :: "0.5s"
RENDER_CHECK_FPS :: 15
RENDER_CHECK_SIZE :: "480x270"

// The godot suite's `render` step (GODOT_STEP_CHECKS) on the game's first replay regression. The headless binary lists
// the recording's events (`replay --events`), and an event is picked whose tick no neighbour of its type shares. Then
// `--at` it, P1's view, to PNG frames: the clip is on that event's tick, its first frame (the movie frame the clip line
// names) showed the clip's first tick and not the lead's, it has as many frames as its ticks at the frame rate, and a
// GIF of them is written (its header, frame count and trailer: tests/cli decodes the encoder's output); then P1's view
// twice side by side: each half of every frame is the single render's
// frame of that moment (render_views_in_sync: within a tolerance, since a game's GPU particles may draw differently
// from run to run, and not a frame out of sync). `skipped` says why it didn't run: no replay regression, or no display to open a window on
// (Linux without DISPLAY or WAYLAND_DISPLAY).
render_check :: proc(game: Game) -> (ok: bool, skipped: string) {
	if !has_extension(game) do return false, "no extension"
	if !has_display() do return false, "no display"
	entries, _ := os.read_all_directory_by_path(join(game.dir, REPLAYS_DIR), context.allocator)
	folders: [dynamic]string
	for entry in entries {
		if entry.type == .Directory && os.is_file(join(entry.fullpath, REPLAY_INPUTS)) do append(&folders, entry.fullpath)
	}
	if len(folders) == 0 do return false, "no replay regression"
	slice.sort(folders[:])
	folder := folders[0]
	fail :: proc(game: Game, format: string, args: ..any) -> bool {
		log("uni: %s render: %s", game.name, aprintf(format, ..args))
		return false
	}
	events, listed := render_check_events(game, folder)
	if !listed do return fail(game, "the headless binary listed no events of %s", folder), ""
	name, n, at, picked := render_check_pick(events)
	if !picked do return fail(game, "%s has no event to cut a clip around", folder), ""
	anchor := aprintf("%s#%d", name, n)
	out := join(game.dir, ".out", "render-check")
	remove_tree(out)
	single_out, pair_out := join(out, "single"), join(out, "pair")
	opts := Render_Opts {
		at     = anchor,
		before = RENDER_CHECK_AROUND,
		after  = RENDER_CHECK_AROUND,
		fps    = RENDER_CHECK_FPS,
		size   = RENDER_CHECK_SIZE,
		player = "1",
		out    = aprintf("%s/", single_out),
	}
	report, problem := render(game, folder, opts, quiet = true)
	if problem != "" do return fail(game, "--at %s: %s", anchor, problem), ""
	ok = true
	expect :: proc(game: Game, ok: ^bool, fine: bool, format: string, args: ..any) {
		if fine do return
		log("uni: %s render: %s", game.name, aprintf(format, ..args))
		ok^ = false
	}
	expect(
		game,
		&ok,
		report.at == at,
		"--at %s: the clip is on tick %d, the headless replay has it on %d",
		anchor,
		report.at,
		at,
	)
	// the absolute anchor: the movie frame the clip line names as its first showed the clip's first tick (the first at
	// or after `from`), not one of the lead's before it
	per_frame := u32((report.tick_hz + RENDER_CHECK_FPS - 1) / RENDER_CHECK_FPS)
	expect(
		game,
		&ok,
		report.first_tick >= report.from && report.first_tick <= report.from + per_frame,
		"the clip's first frame shows tick %d, not one of ticks %d to %d: the frames cut are not the clip's",
		report.first_tick,
		report.from,
		report.from + per_frame,
	)
	ticks := int(report.to - report.from)
	expected := (ticks * RENDER_CHECK_FPS + report.tick_hz - 1) / max(report.tick_hz, 1)
	expect(
		game,
		&ok,
		report.frames == expected,
		"%d frames for %d ticks at %d Hz, %d fps: want %d",
		report.frames,
		ticks,
		report.tick_hz,
		RENDER_CHECK_FPS,
		expected,
	)
	paths: [dynamic]string
	for i := 0;; i += 1 {
		path := join(single_out, aprintf("%s%08d.png", RENDER_FRAME_PREFIX, i))
		if !os.is_file(path) do break
		append(&paths, path)
	}
	expect(game, &ok, len(paths) == report.frames, "%d PNG frames written, the clip has %d", len(paths), report.frames)
	if len(paths) == 0 do return false, ""
	gif, stats, gif_problem := render_gif(paths[:], RENDER_CHECK_FPS, false)
	expect(game, &ok, gif_problem == "", "the GIF: %s", gif_problem)
	expect(
		game,
		&ok,
		len(gif) > 13 &&
		string(gif[:6]) == "GIF89a" &&
		gif[len(gif) - 1] == 0x3B &&
		stats.frames >= 1 &&
		stats.frames <= len(paths),
		"the GIF of %d frames is not one (%d bytes, %d frames)",
		len(paths),
		len(gif),
		stats.frames,
	)
	// side by side: two renders on the same frame clock, laid out in one clip
	opts.player, opts.out = "1,1", aprintf("%s/", pair_out)
	pair, pair_problem := render(game, folder, opts, quiet = true)
	if pair_problem != "" do return fail(game, "--player 1,1: %s", pair_problem), ""
	expect(
		game,
		&ok,
		pair.panes == 2 && pair.frames == report.frames && pair.from == report.from && pair.at == report.at,
		"side by side: %d views, %d frames from tick %d (the single render: %d from %d)",
		pair.panes,
		pair.frames,
		pair.from,
		report.frames,
		report.from,
	)
	pair_paths := make([]string, len(paths))
	for &path, i in pair_paths do path = join(pair_out, aprintf("%s%08d.png", RENDER_FRAME_PREFIX, i))
	if differs := render_views_in_sync(pair_paths, paths[:], 2); differs != "" {
		expect(game, &ok, false, "side by side: %s", differs)
	}
	return ok, ""
}

// The events of the recording in `folder` as its game's headless binary replays it (`replay --events`, `--game` the
// game's own name: the variant Godot plays, which a headless binary's default, a stress tuning, may not be): [tick,
// type] in order; false when it printed none.
@(private)
render_check_events :: proc(game: Game, folder: string) -> (events: [][2]json.Value, ok: bool) {
	binary := ensure_headless(
		Headless{game.name, join(game.dir, "simulation", "headless"), game_uses_box3d(game)},
		.release,
	)
	cmd: [dynamic]string
	append(
		&cmd,
		binary,
		"replay",
		"--log",
		join(folder, REPLAY_INPUTS),
		"--any-build",
		"--game",
		game.name,
		"--events",
	)
	if snapshot := join(folder, "snapshot.unis"); os.is_file(snapshot) do append(&cmd, "--snapshot", snapshot)
	ran := run_proc({cmd = cmd[:], capture = true, quiet = true, timeout = 300 * time.Second})
	report := last_json_object(ran.stdout) or_return
	listing := report["events"].(json.Array) or_return
	out: [dynamic][2]json.Value
	for entry in listing {
		pair, is_pair := entry.(json.Array)
		if is_pair && len(pair) == 2 do append(&out, [2]json.Value{pair[0], pair[1]})
	}
	return out[:], len(out) > 0
}

// An event of `events` ([tick, type], in order) to cut a clip around: the n-th of its type whose tick neither the one
// before nor the one after of its type shares, n from 2 up where it can be (a #n off by one finds another tick), the
// one nearest the middle of the recording's events (its players have joined, and there is room around it); false when
// none is.
@(private)
render_check_pick :: proc(events: [][2]json.Value) -> (name: string, n: int, at: u32, ok: bool) {
	if len(events) == 0 do return
	middle := (json_int(events[0][0]) + json_int(events[len(events) - 1][0])) / 2
	best, best_n := -1, 0
	for event, i in events {
		type, tick := json_string(event[1]), json_int(event[0])
		which, shared := 1, false
		for other in events[:i] {
			if json_string(other[1]) != type do continue
			which += 1
			shared = json_int(other[0]) == tick
		}
		for other in events[i + 1:] {
			if json_string(other[1]) != type do continue
			shared ||= json_int(other[0]) == tick
			break
		}
		if shared do continue
		better := best < 0 || (which >= 2) != (best_n >= 2) && which >= 2
		if !better && (which >= 2) == (best_n >= 2) {
			better = abs(tick - middle) < abs(json_int(events[best][0]) - middle)
		}
		if better do best, best_n = i, which
	}
	if best < 0 do return
	return json_string(events[best][1]), best_n, u32(json_int(events[best][0])), true
}

// How far a view laid side by side may come out from the single render of the same moment: the mean absolute
// difference of a channel (of 255). Two renders of a game whose GPU particles are not deterministic differ there.
RENDER_CHECK_NOISE :: 2.0

// Whether every view of the side-by-side frames `composed` (each `panes` views wide) shows the moment the single
// render's frames `single` show in the same place: each frame within RENDER_CHECK_NOISE of it, and nearer it, over the
// clip, than the single render's frame before or after it (a view one frame out of sync is nearer one of those, where
// anything moves); why not, else "".
render_views_in_sync :: proc(composed, single: []string, panes: int) -> string {
	load :: proc(path: string) -> ^png.Image {
		img, err := png.load_from_file(path, {.alpha_add_if_missing}, context.allocator)
		return err == nil ? img : nil
	}
	wholes := make([]^png.Image, len(composed))
	parts := make([]^png.Image, len(single))
	defer for img in wholes do if img != nil do png.destroy(img)
	defer for img in parts do if img != nil do png.destroy(img)
	if len(composed) != len(single) || len(single) == 0 {
		return aprintf("%d frames side by side, %d single", len(composed), len(single))
	}
	for i in 0 ..< len(single) {
		wholes[i], parts[i] = load(composed[i]), load(single[i])
		if wholes[i] == nil do return aprintf("%s does not load", composed[i])
		if parts[i] == nil do return aprintf("%s does not load", single[i])
		whole, part := wholes[i], parts[i]
		if whole.width != panes * part.width || whole.height != part.height {
			return aprintf(
				"frame %d is %dx%d, not %d of %dx%d side by side",
				i,
				whole.width,
				whole.height,
				panes,
				part.width,
				part.height,
			)
		}
	}
	for view in 0 ..< panes {
		same, late, early: f64 // over the frames that have both neighbours' counterparts
		for i in 0 ..< len(single) {
			difference := render_view_difference(wholes[i], parts[i], panes, view)
			if difference > RENDER_CHECK_NOISE {
				return aprintf(
					"view %d of frame %d is %.2f from the single render's (at most %.1f)",
					view + 1,
					i,
					difference,
					RENDER_CHECK_NOISE,
				)
			}
			if i + 1 < len(single) {
				same += difference
				late += render_view_difference(wholes[i], parts[i + 1], panes, view)
				early += render_view_difference(wholes[i + 1], parts[i], panes, view)
			}
		}
		// in sync, a view is noise from its frame and motion plus noise from the next; a frame off, the other way round
		allowance := 0.01 * f64(len(single))
		if same > 2 * late + allowance || same > 2 * early + allowance {
			return aprintf(
				"view %d is out of sync: %.2f from the single render's frames, %.2f from the next ones, %.2f from the ones before",
				view + 1,
				same,
				late,
				early,
			)
		}
	}
	return ""
}

// The mean absolute difference of a channel (RGB, of 255) between view `view` of `whole` (`panes` views side by side)
// and `part`.
@(private)
render_view_difference :: proc(whole, part: ^png.Image, panes, view: int) -> f64 {
	row := part.width * 4
	total := 0
	for y in 0 ..< part.height {
		got := whole.pixels[(y * panes + view) * row:][:row]
		want := part.pixels[y * row:][:row]
		for x := 0; x < row; x += 4 {
			for c in 0 ..< 3 do total += abs(int(got[x + c]) - int(want[x + c]))
		}
	}
	return f64(total) / f64(part.width * part.height * 3)
}
