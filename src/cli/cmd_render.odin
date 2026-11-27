// `render`: a recording played in the game's own play scene on the replay's frame clock while Godot's movie writer
// writes every frame, kept to the clip and written as a video (.avi), an animated GIF (gif.odin), or PNG frames
// (README.md, Rendering clips).
package cli

import "core:encoding/endian"
import "core:encoding/json"
import "core:image/png"
import "core:os"
import "core:slice"
import "core:strings"
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
// Where a render works, under the game's .out/.
RENDER_DIR :: "render"
// The names of the PNG frames and audio a directory gets (frame00000000.png, ...: Godot's movie writer's numbering).
RENDER_FRAME_PREFIX :: "frame"
RENDER_AUDIO :: "audio.wav"

@(private)
Render_Opts :: struct {
	out:      string `args:"required" hint:"<file>" usage:"what to write, by its extension: .avi (MJPEG video with the game's sound, Godot's movie writer), .gif (animated, encoded by uni), or a directory (ending in / or one that exists): PNG frames and audio.wav"`,
	from:     string `hint:"<tick|Ns>" usage:"where the clip starts: a tick, or seconds into the recording (4.5s); default its first tick (a later one: the game plays the second before it, cut, so it has settled)"`,
	to:       string `hint:"<tick|Ns>" usage:"where it ends; default the recording's last tick"`,
	fps:      int `hint:"<n>" usage:"frames per second (default 30; a GIF 15, at most 50): the clip is frame-exact at any machine speed"`,
	size:     string `hint:"<WxH>" usage:"the window and frame size (default: the project's window; a GIF 960x540, and never wider than 960)"`,
	player:   int `hint:"<n>" usage:"whose view: the player shown as P<n> (slot n-1) at the clip's start (default: whoever recorded it)"`,
	speed:    string `hint:"<x>" usage:"playback speed, 0.25 to 4 (default 1)"`,
	dither:   bool `usage:"GIF: ordered dither (smoother gradients, a bigger file)"`,
	overflow: [dynamic]string `hint:"[game] <recording>" usage:"the game (default: the only one) and the recording: a folder holding inputs.unil (a session recording, an F3 note, a freeze), a feedback note's name (uni feedback), or a replay regression's (simulation/tests/replays/<name>)"`,
}

// `render -h`'s details.
@(private)
render_details :: proc() -> string {
	return(
		"The game plays the recording in its own play scene, in replay mode, in a window (muted, in the top-left\n" +
		"corner of the leftmost screen, never taking focus), with Godot's movie writer at a fixed frame rate: frame n\n" +
		"always shows the same moment, however slow the machine. The clip starts on the first frame the game shows\n" +
		"the replay's views (a menu or a loading scene before it is cut). The window must fit the leftmost screen.\n" +
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
	tick_hz:    int,
	width:      int,
	height:     int,
	bytes:      int, // the file's size (png: every frame's)
	gif_frames: int,
	gif_colors: int,
	render_s:   f64, // Godot's run
	encode_s:   f64, // the GIF's encoding (PNG decoding included)
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
	summary := aprintf(
		"%s: %d frames at %d fps (ticks %d to %d), %dx%d -> %s (%s) in %.1fs",
		selected.name,
		report.frames,
		report.fps,
		report.from,
		report.to,
		report.width,
		report.height,
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
	if opts.player < 0 || opts.player > 64 do usage("--player takes the n of P<n> (got %d)", opts.player)
	size_text := opts.size != "" ? opts.size : (format == "gif" ? RENDER_GIF_SIZE : "")
	size: [2]int
	if size_text != "" {
		size = parse_window_size(size_text)
		render_check_fits(size)
	}
	cwd, _ := os.get_working_directory(context.allocator)
	out := absolute_path(cwd, opts.out)
	work := absolute_path(cwd, join(selected.dir, ".out", RENDER_DIR))
	remove_tree(work)
	make_dirs(work)
	movie := join(work, format == "avi" ? "clip.avi" : aprintf("%s.png", RENDER_FRAME_PREFIX))

	ensure_game(selected)
	cmd: [dynamic]string
	append(&cmd, godot())
	append(&cmd, ..window_args(AGENT_WINDOW))
	append(&cmd, "--path", selected.dir, "--write-movie", movie, "--fixed-fps", aprintf("%d", fps), "--disable-vsync")
	append(&cmd, "--", "--no-settings", "--local-net", "--quit-at-end", "--replay", folder)
	append(&cmd, "--replay-fps", aprintf("%d", fps))
	if opts.from != "" do append(&cmd, "--replay-from", opts.from)
	if opts.to != "" do append(&cmd, "--replay-to", opts.to)
	if opts.speed != "" do append(&cmd, "--replay-speed", opts.speed)
	if opts.player != 0 do append(&cmd, "--replay-player", aprintf("%d", opts.player))
	// the movie's size is the window size override (a game whose stretch mode is viewport: its viewport's size)
	display := ""
	if size_text != "" {
		display = aprintf(
			"window/size/window_width_override=%d\nwindow/size/window_height_override=%d\n",
			size.x,
			size.y,
		)
	}
	cleanup := with_window(selected.dir, AGENT_WINDOW, display)
	if !quiet do log("uni: rendering %s at %d fps in a window (Godot's movie writer)", folder, fps)
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
	report.render_s = ran.seconds
	output := strings.concatenate({ran.stdout, ran.stderr})
	clip, has_clip := render_clip_line(output)
	if !has_clip {
		log("%s", tail(output, 4000))
		if ran.timed_out do return report, aprintf("Godot timed out after %.0fs", time.duration_seconds(RENDER_TIMEOUT))
		for line in strings.split_lines(output, context.temp_allocator) {
			if at := strings.index(line, "the session failed: "); at >= 0 {
				return report, aprintf("the game showed no clip: %s", line[at + len("the session failed: "):])
			}
		}
		problems := godot_problems(output)
		if len(problems) > 0 do return report, aprintf("the game showed no clip: %s", problems[0])
		return report, aprintf("the game showed no clip (exit %d; its output is above)", ran.exit_code)
	}
	if !quiet do for line in godot_problems(output) do log("uni: render: %s", line)
	report.format, report.frames, report.fps, report.from, report.to = format, clip.frames, fps, clip.from, clip.to
	report.tick_hz = clip.tick_hz
	switch format {
	case "avi":
		data, err := os.read_entire_file(movie, context.allocator)
		if err != nil do return report, aprintf("Godot wrote no %s", movie)
		trimmed, trim_problem := avi_trim(data, clip.movie_frame, clip.frames)
		if trim_problem != "" do return report, aprintf("%s: %s", movie, trim_problem)
		if !write_file(out, trimmed) do return report, aprintf("cannot write %s", out)
		report.bytes = len(trimmed)
		report.width, report.height = avi_size(trimmed)
	case "png", "gif":
		frames := make([]string, clip.frames)
		for &frame, i in frames {
			frame = join(work, aprintf("%s%08d.png", RENDER_FRAME_PREFIX, clip.movie_frame + i))
			if !os.is_file(frame) do return report, aprintf("Godot wrote no frame %s", frame)
		}
		if format == "png" {
			make_dirs(out)
			for frame, i in frames {
				target := join(out, aprintf("%s%08d.png", RENDER_FRAME_PREFIX, i))
				os.remove(target)
				if os.rename(frame, target) != nil do return report, aprintf("cannot move %s to %s", frame, target)
				report.bytes += int(file_size(target))
			}
			// what an older render left past this one's last frame
			for i := clip.frames;; i += 1 {
				stale := join(out, aprintf("%s%08d.png", RENDER_FRAME_PREFIX, i))
				if !os.is_file(stale) do break
				os.remove(stale)
			}
			if wav, err := os.read_entire_file(join(work, aprintf("%s.wav", RENDER_FRAME_PREFIX)), context.allocator);
			   err == nil {
				if audio, audio_ok := wav_trim(wav, clip.movie_frame, clip.frames, fps); audio_ok {
					write_file(join(out, RENDER_AUDIO), audio)
				}
			}
			report.width, report.height = png_size(join(out, aprintf("%s00000000.png", RENDER_FRAME_PREFIX)))
		} else {
			started := time.tick_now()
			gif, stats, gif_problem := render_gif(frames, fps, opts.dither)
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

// How much of a replay regression the godot suite's `render` step renders, and at what rate.
RENDER_CHECK_TO :: "1s"
RENDER_CHECK_FPS :: 15

// The godot suite's `render` step (GODOT_STEP_CHECKS): the game's first replay regression rendered to PNG frames, as
// many as its length at the frame rate, and a GIF of them that decodes to at most that many. `skipped` says why it
// didn't run: no replay regression, or no display to open a window on (Linux without DISPLAY or WAYLAND_DISPLAY).
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
	out := join(game.dir, ".out", "render-check")
	remove_tree(out)
	report, problem := render(
		game,
		folders[0],
		{out = aprintf("%s/", out), to = RENDER_CHECK_TO, fps = RENDER_CHECK_FPS},
		quiet = true,
	)
	if problem != "" {
		log("uni: %s render: %s", game.name, problem)
		return false, ""
	}
	ok = true
	expect :: proc(game: Game, ok: ^bool, fine: bool, format: string, args: ..any) {
		if fine do return
		log("uni: %s render: %s", game.name, aprintf(format, ..args))
		ok^ = false
	}
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
		path := join(out, aprintf("%s%08d.png", RENDER_FRAME_PREFIX, i))
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
	return ok, ""
}
