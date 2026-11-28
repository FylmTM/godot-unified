// The GIF encoder (src/cli/gif.odin): its LZW streams decode to what went in, the code size growing and the
// dictionary clearing where a decoder expects; a clip's frames decode, composited as a viewer shows them, to the
// source within the palette's error, a frame that changed nothing folded into the one before and the delays adding up
// to the clip's length. The decoder here is the test's own, written from the GIF89a specification.
package test_cli

import "base:runtime"
import "core:math"
import "core:testing"
import "unified:cli"

// What test_lzw_decode read: the indices, the clear codes it met and the widest code.
Lzw_Read :: struct {
	indices:  [dynamic]u8,
	clears:   int,
	max_bits: int,
	ok:       bool,
}

// Decodes a GIF LZW code stream (no sub-blocks) of `min_code_size`, per the specification: a code is min_code_size + 1
// bits, one wider once the next free code reaches the width's limit (at most 12), a clear code starts over.
test_lzw_decode :: proc(data: []u8, min_code_size: int) -> (read: Lzw_Read) {
	clear_code := 1 << uint(min_code_size)
	end_code := clear_code + 1
	prefixes: [4096]int
	suffixes: [4096]u8
	lengths: [4096]int
	for code in 0 ..< clear_code {
		suffixes[code] = u8(code)
		lengths[code] = 1
	}
	code_size := min_code_size + 1
	next := end_code + 1
	previous := -1
	bit := 0
	read_code :: proc(data: []u8, bit: ^int, size: int) -> (code: int, ok: bool) {
		if bit^ + size > len(data) * 8 do return 0, false
		for i in 0 ..< size {
			at := bit^ + i
			if data[at >> 3] & (1 << uint(at & 7)) != 0 do code |= 1 << uint(i)
		}
		bit^ += size
		return code, true
	}
	expand :: proc(read: ^Lzw_Read, prefixes: []int, suffixes: []u8, lengths: []int, code: int) -> u8 {
		start := len(read.indices)
		resize(&read.indices, start + lengths[code])
		walk := code
		for i := lengths[code] - 1; i >= 0; i -= 1 {
			read.indices[start + i] = suffixes[walk]
			walk = prefixes[walk]
		}
		return read.indices[start]
	}
	for {
		code, has := read_code(data, &bit, code_size)
		if !has do return
		read.max_bits = max(read.max_bits, code_size)
		if code == clear_code {
			read.clears += 1
			code_size, next, previous = min_code_size + 1, end_code + 1, -1
			continue
		}
		if code == end_code {
			read.ok = true
			return
		}
		if previous < 0 {
			if code >= clear_code do return
			expand(&read, prefixes[:], suffixes[:], lengths[:], code)
			previous = code
			continue
		}
		first: u8
		if code < next {
			first = expand(&read, prefixes[:], suffixes[:], lengths[:], code)
		} else if code == next {
			// the code being defined: the previous string and its own first value
			start := expand(&read, prefixes[:], suffixes[:], lengths[:], previous)
			append(&read.indices, start)
			first = start
		} else {
			return
		}
		if next < 4096 {
			prefixes[next], suffixes[next], lengths[next] = previous, first, lengths[previous] + 1
			next += 1
			if next == 1 << uint(code_size) && code_size < 12 do code_size += 1
		}
		previous = code
	}
}

// A decoded GIF: its size, palette, each frame as a viewer composites it (RGB), the delays, and the LZW reads.
Gif_Read :: struct {
	width, height: int,
	palette:       [256][3]u8,
	frames:        [dynamic][]u8,
	delays:        [dynamic]int,
	clears:        int,
	max_bits:      int,
	loops:         bool,
	ok:            bool,
}

// Decodes a GIF89a with a global colour table, compositing each frame over the one before (disposal 1) and leaving a
// pixel of the transparent index as it was.
test_gif_decode :: proc(gif: []u8) -> (read: Gif_Read) {
	if len(gif) < 13 || string(gif[:6]) != "GIF89a" do return
	u16le :: proc(data: []u8, at: int) -> int {
		return int(data[at]) | int(data[at + 1]) << 8
	}
	read.width, read.height = u16le(gif, 6), u16le(gif, 8)
	flags := gif[10]
	at := 13
	if flags & 0x80 != 0 {
		entries := 1 << uint(flags & 7 + 1)
		for i in 0 ..< entries do read.palette[i] = {gif[at + i * 3], gif[at + i * 3 + 1], gif[at + i * 3 + 2]}
		at += entries * 3
	}
	canvas := make([]u8, read.width * read.height * 3)
	transparent := -1
	delay := 0
	for at < len(gif) {
		switch gif[at] {
		case 0x3B:
			read.ok = true
			return
		case 0x21:
			label := gif[at + 1]
			at += 2
			if label == 0xF9 {
				packed := gif[at + 1]
				delay = u16le(gif, at + 2)
				transparent = packed & 1 != 0 ? int(gif[at + 4]) : -1
			}
			if label == 0xFF && string(gif[at + 1:at + 12]) == "NETSCAPE2.0" do read.loops = true
			for gif[at] != 0 do at += int(gif[at]) + 1
			at += 1
		case 0x2C:
			left, top := u16le(gif, at + 1), u16le(gif, at + 3)
			width, height := u16le(gif, at + 5), u16le(gif, at + 7)
			if gif[at + 9] & 0x80 != 0 do return // no local tables here
			min_code_size := int(gif[at + 10])
			at += 11
			data: [dynamic]u8
			for gif[at] != 0 {
				size := int(gif[at])
				append(&data, ..gif[at + 1:at + 1 + size])
				at += size + 1
			}
			at += 1
			lzw := test_lzw_decode(data[:], min_code_size)
			if !lzw.ok || len(lzw.indices) != width * height do return
			read.clears += lzw.clears
			read.max_bits = max(read.max_bits, lzw.max_bits)
			for y in 0 ..< height {
				for x in 0 ..< width {
					index := int(lzw.indices[y * width + x])
					if index == transparent do continue
					pixel := ((top + y) * read.width + left + x) * 3
					canvas[pixel], canvas[pixel + 1], canvas[pixel + 2] =
						read.palette[index][0], read.palette[index][1], read.palette[index][2]
				}
			}
			frame := make([]u8, len(canvas))
			copy(frame, canvas)
			append(&read.frames, frame)
			append(&read.delays, delay)
		case:
			return
		}
	}
	return
}

// A pseudo-random sequence (xorshift), the same every run.
test_random :: proc(state: ^u32) -> u32 {
	state^ ~= state^ << 13
	state^ ~= state^ >> 17
	state^ ~= state^ << 5
	return state^
}

@(test)
lzw_streams_decode_to_their_input :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dictionary := cli.lzw_dictionary()
	defer cli.lzw_dictionary_free(&dictionary)
	for min_code_size in 2 ..= 8 {
		values := 1 << uint(min_code_size)
		seed := u32(12345 + min_code_size)
		random := make([]u8, 300_000)
		for &value in random do value = u8(test_random(&seed) % u32(values))
		// a few values in long runs: strings that grow by one each time (the code being defined is sent: KwKwK)
		runs := make([]u8, 100_000)
		for &value, i in runs do value = u8((i / 5000) % values)
		ramp := make([]u8, 70_000)
		for &value, i in ramp do value = u8((i * 7 + i / 300) % values)
		cases := [][]u8{{}, {0}, {u8(values - 1), 0, u8(values - 1)}, random, runs, ramp, random[:1000]}
		for input, case_index in cases {
			stream: [dynamic]u8
			cli.lzw_encode(input, min_code_size, &dictionary, &stream)
			read := test_lzw_decode(stream[:], min_code_size)
			if !testing.expectf(
				t,
				read.ok,
				"min %d case %d: the stream ends with its end code",
				min_code_size,
				case_index,
			) {
				continue
			}
			testing.expectf(
				t,
				len(read.indices) == len(input) && string(read.indices[:]) == string(input),
				"min %d case %d: %d values in, %d out",
				min_code_size,
				case_index,
				len(input),
				len(read.indices),
			)
		}
		// random data fills the dictionary again and again: 12-bit codes, and a clear code each time it is full
		stream: [dynamic]u8
		cli.lzw_encode(random, min_code_size, &dictionary, &stream)
		read := test_lzw_decode(stream[:], min_code_size)
		testing.expectf(t, read.max_bits == 12, "min %d: codes grow to 12 bits (%d)", min_code_size, read.max_bits)
		testing.expectf(
			t,
			read.clears > 3,
			"min %d: the full dictionary clears (%d clear codes)",
			min_code_size,
			read.clears,
		)
	}
	// every length of a range: the stream ends with an end code the decoder reads at the width it expects, also where
	// the last value's code is the one that widens the codes and the stream ends on a byte boundary (each range holds
	// such a length for its seed; a range far longer takes seconds)
	Sweep :: struct {
		min_code_size, from, to: int,
	}
	for sweep in ([]Sweep{{2, 1, 1000}, {4, 1, 1000}, {8, 4000, 4400}}) {
		context.allocator = runtime.heap_allocator() // each stream freed: hundreds of them
		seed := u32(777 + sweep.min_code_size)
		values := make([]u8, sweep.to)
		defer delete(values)
		for &value in values do value = u8(test_random(&seed) % u32(1 << uint(sweep.min_code_size)))
		failed := 0
		for length in sweep.from ..= sweep.to {
			stream: [dynamic]u8
			cli.lzw_encode(values[:length], sweep.min_code_size, &dictionary, &stream)
			read := test_lzw_decode(stream[:], sweep.min_code_size)
			if !read.ok || string(read.indices[:]) != string(values[:length]) {
				if failed == 0 {
					testing.expectf(
						t,
						false,
						"min %d, %d values: no readable end code, or other values",
						sweep.min_code_size,
						length,
					)
				}
				failed += 1
			}
			delete(stream)
			delete(read.indices)
		}
		testing.expectf(t, failed == 0, "min %d: %d lengths fail", sweep.min_code_size, failed)
	}
	// a short stream stays narrow: one clear code, codes one bit past the values
	stream: [dynamic]u8
	cli.lzw_encode({1, 2, 3, 1, 2, 3}, 8, &dictionary, &stream)
	read := test_lzw_decode(stream[:], 8)
	testing.expect_value(t, read.clears, 1)
	testing.expect_value(t, read.max_bits, 9)
}

// A test clip: frames of `width` x `height` RGBA, held by the test.
Test_Clip :: struct {
	frames:        [][]u8,
	width, height: int,
}

test_clip_source :: proc(clip: ^Test_Clip, fps: int) -> cli.Gif_Source {
	return {
		count = len(clip.frames),
		width = clip.width,
		height = clip.height,
		fps = fps,
		data = clip,
		frame = proc(data: rawptr, index: int, out: []u8) -> bool {
			clip := (^Test_Clip)(data)
			copy(out, clip.frames[index])
			return true
		},
	}
}

// Fills a pixel of an RGBA frame.
test_put :: proc(frame: []u8, width, x, y: int, color: [3]u8) {
	at := (y * width + x) * 4
	frame[at], frame[at + 1], frame[at + 2], frame[at + 3] = color[0], color[1], color[2], 255
}

// An animation of a few colours: a striped background, a square moving across it, a corner that blinks, and two
// frames that repeat the one before them.
test_animation :: proc(count: int) -> Test_Clip {
	width, height := 61, 37
	colors := [][3]u8{{20, 24, 40}, {200, 60, 60}, {60, 200, 90}, {250, 250, 250}, {0, 0, 0}, {128, 128, 255}}
	frames := make([][]u8, count)
	shown := 0
	for &frame, i in frames {
		if i == 4 || i == 9 do shown -= 1 // the same as the frame before
		frame = make([]u8, width * height * 4)
		for y in 0 ..< height {
			for x in 0 ..< width do test_put(frame, width, x, y, colors[(x / 8 + y / 8) % 2 == 0 ? 0 : 5])
		}
		for y in 10 ..< 22 {
			for x in 0 ..< 9 do test_put(frame, width, (shown * 3 + x) % width, y, colors[1])
		}
		if shown % 3 == 0 do test_put(frame, width, width - 1, height - 1, colors[3])
		test_put(frame, width, shown % width, 0, colors[2])
		shown += 1
	}
	return {frames, width, height}
}

@(test)
gif_frames_decode_to_the_clip :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	clip := test_animation(14)
	fps := 15
	for threads in ([]int{1, 3}) {
		// three threads: batches of six, so a frame compared with the one before it crosses batches
		gif, stats, ok := cli.gif_encode(test_clip_source(&clip, fps), {threads = threads})
		if !testing.expect(t, ok) do return
		read := test_gif_decode(gif)
		if !testing.expect(t, read.ok, "the GIF decodes") do return
		testing.expect(t, read.loops, "it loops")
		testing.expect_value(t, read.width, clip.width)
		testing.expect_value(t, read.height, clip.height)
		// frames 4 and 9 repeat the ones before them: folded into them
		testing.expect_value(t, len(read.frames), len(clip.frames) - 2)
		testing.expect_value(t, stats.frames, len(read.frames))
		total := 0
		for delay in read.delays do total += delay
		testing.expect_value(t, total, 100 * len(clip.frames) / fps) // 14 frames at 15 fps: 93 hundredths
		testing.expect_value(t, read.delays[3], cli.gif_delay(3, 5, fps)) // frame 3 shows for frames 3 and 4
		shown := 0
		for source, i in clip.frames {
			if i == 4 || i == 9 do continue
			decoded := read.frames[shown]
			shown += 1
			mismatch := -1
			for pixel in 0 ..< clip.width * clip.height {
				for c in 0 ..< 3 {
					if decoded[pixel * 3 + c] != source[pixel * 4 + c] do mismatch = pixel
				}
			}
			testing.expectf(
				t,
				mismatch < 0,
				"threads %d: frame %d decodes exactly (pixel %d differs)",
				threads,
				i,
				mismatch,
			)
		}
	}
}

@(test)
gif_colours_stay_within_the_palette_error :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	// far more colours than a palette holds: gradients and noise
	width, height := 96, 64
	seed := u32(99)
	frames := make([][]u8, 3)
	for &frame, i in frames {
		frame = make([]u8, width * height * 4)
		for y in 0 ..< height {
			for x in 0 ..< width {
				noise := int(test_random(&seed) % 24)
				test_put(
					frame,
					width,
					x,
					y,
					{u8(x * 255 / width), u8(clamp(y * 4 + noise, 0, 255)), u8((x + y + i * 9) % 256)},
				)
			}
		}
	}
	clip := Test_Clip{frames, width, height}
	for dither in ([]bool{false, true}) {
		gif, stats, ok := cli.gif_encode(test_clip_source(&clip, 10), {dither = dither, threads = 2})
		if !testing.expect(t, ok) do return
		read := test_gif_decode(gif)
		if !testing.expect(t, read.ok, "the GIF decodes") do return
		testing.expect_value(t, stats.colors, cli.GIF_COLORS)
		testing.expect_value(t, len(read.frames), len(frames))
		total_error := 0.0
		worst := 0.0
		for source, i in frames {
			decoded := read.frames[i]
			for pixel in 0 ..< width * height {
				src := [3]f64{f64(source[pixel * 4]), f64(source[pixel * 4 + 1]), f64(source[pixel * 4 + 2])}
				got := [3]f64{f64(decoded[pixel * 3]), f64(decoded[pixel * 3 + 1]), f64(decoded[pixel * 3 + 2])}
				// the nearest colour the palette has, and how far the pixel came out past it
				nearest := max(f64)
				for color in read.palette[:stats.colors] {
					delta := [3]f64{f64(color[0]), f64(color[1]), f64(color[2])} - src
					nearest = min(nearest, math.sqrt(delta.x * delta.x + delta.y * delta.y + delta.z * delta.z))
				}
				delta := got - src
				distance := math.sqrt(delta.x * delta.x + delta.y * delta.y + delta.z * delta.z)
				total_error += distance
				if !dither do worst = max(worst, distance - nearest)
			}
		}
		mean := total_error / f64(len(frames) * width * height)
		// the lookup takes a colour's 6-bit cell: at most 2 * sqrt(3) * 2 past the nearest; the dither adds its spread
		testing.expectf(t, worst <= 7, "dither %v: a pixel %.1f past its nearest palette colour", dither, worst)
		testing.expectf(t, mean < (dither ? 16 : 10), "dither %v: mean error %.1f", dither, mean)
	}
}

@(test)
gif_delays_add_up_and_sizes_scale :: proc(t: ^testing.T) {
	for fps in ([]int{7, 10, 15, 24, 30, 50}) {
		total := 0
		for frame in 0 ..< 3 * fps do total += cli.gif_delay(frame, frame + 1, fps)
		testing.expectf(t, total == 300, "%d fps: 3 s of single frames are 300 hundredths (%d)", fps, total)
	}
	testing.expect_value(t, cli.gif_delay(0, 15, 15), 100)
	width, height := cli.gif_size(1920, 1080, 960)
	testing.expect_value(t, width, 960)
	testing.expect_value(t, height, 540)
	width, height = cli.gif_size(640, 480, 960)
	testing.expect_value(t, width, 640)
	// a box filter: a 2x2 block's mean
	source := []u8{0, 0, 0, 255, 100, 0, 0, 255, 0, 200, 0, 255, 0, 0, 40, 255}
	out: [4]u8
	cli.gif_downscale(source, 2, 2, out[:], 1, 1)
	testing.expect_value(t, out, [4]u8{25, 50, 10, 255})
}
