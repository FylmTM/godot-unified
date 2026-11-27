// Animated GIFs from RGBA frames, written in Odin with no dependency (README.md, Rendering clips): one palette for the
// whole clip (median cut over the colours of frames spread across it), an optional ordered dither, each frame only the
// rectangle that changed since the one before with its unchanged pixels transparent, a frame that changed nothing
// folded into the one before, and LZW. The work runs on every core, a batch of frames at a time, so memory stays a few
// frames per core whatever the clip's length.
package cli

import "core:math"
import "core:os"
import "core:slice"
import "core:sync"
import "core:thread"

// The palette index of a frame's unchanged pixels (transparent): the clip's colours are the 255 others.
GIF_TRANSPARENT :: 255
GIF_COLORS :: 255
// How many frames, spread over the clip, the palette is made from.
GIF_PALETTE_FRAMES :: 32
// The LZW code size of a 256-colour image: codes start one bit wider, and grow to GIF_CODE_BITS_MAX.
GIF_MIN_CODE_SIZE :: 8
GIF_CODE_BITS_MAX :: 12
// How far the ordered dither moves a channel at most, either way (of 255).
GIF_DITHER_SPREAD :: 8
// The 4x4 Bayer matrix the ordered dither offsets each pixel by (0 ..< 16).
@(private)
GIF_BAYER := [4][4]u8{{0, 8, 2, 10}, {12, 4, 14, 6}, {3, 11, 1, 9}, {15, 7, 13, 5}}

// A clip to encode: `count` frames of `width` x `height` RGBA8 pixels (4 bytes each, alpha ignored) shown at `fps`.
// `frame` fills `out` (width * height * 4 bytes) with frame `index`, false when it can't; it is called from several
// threads at once, each with its own `out`.
Gif_Source :: struct {
	count, width, height, fps: int,
	data:                      rawptr,
	frame:                     proc(data: rawptr, index: int, out: []u8) -> bool,
}

// How gif_encode encodes.
Gif_Options :: struct {
	dither:  bool, // ordered dither: smoother gradients, more bytes
	threads: int, // 0: one per core
}

// What gif_encode wrote: its frames (a source frame that changed nothing is folded into the one before), and the
// palette's colours.
Gif_Stats :: struct {
	frames: int,
	colors: int,
}

// A clip's palette: `count` colours, then GIF_TRANSPARENT.
Gif_Palette :: struct {
	colors: [256][3]u8,
	count:  int,
}

// One bin of a colour histogram (5 bits a channel): how many pixels fell in it and their colours' sum.
Gif_Bin :: struct {
	count: u64,
	sum:   [3]u64,
}

// The bins of a colour histogram: a channel's top 5 bits each, red highest.
GIF_BINS :: 1 << 15

// The histogram bin of a colour.
@(private)
gif_bin :: #force_inline proc(r, g, b: u8) -> int {
	return int(r >> 3) << 10 | int(g >> 3) << 5 | int(b >> 3)
}

// Adds the RGBA pixels' colours to `histogram` (GIF_BINS bins).
gif_histogram_add :: proc(histogram: []Gif_Bin, rgba: []u8) {
	for i := 0; i + 3 < len(rgba); i += 4 {
		r, g, b := rgba[i], rgba[i + 1], rgba[i + 2]
		bin := &histogram[gif_bin(r, g, b)]
		bin.count += 1
		bin.sum += {u64(r), u64(g), u64(b)}
	}
}

// The palette of a histogram by median cut: the box of colours with the most pixels times its widest side is split at
// its median along that side until there are GIF_COLORS boxes or none splits; a box's colour is its pixels' mean (a
// colour alone in its bin comes back exactly).
gif_palette :: proc(histogram: []Gif_Bin) -> (palette: Gif_Palette) {
	Entry :: struct {
		channel: [3]u8, // the bin's 5-bit channels
		bin:     ^Gif_Bin,
	}
	Box :: struct {
		low, high: int, // its entries
		pixels:    u64,
		axis:      int, // its widest channel
		span:      int, // how wide (in bins; 0: one colour)
	}
	entries := make([dynamic]Entry, 0, 4096, context.temp_allocator)
	for &bin, index in histogram {
		if bin.count == 0 do continue
		append(&entries, Entry{{u8(index >> 10), u8(index >> 5 & 31), u8(index & 31)}, &bin})
	}
	if len(entries) == 0 do return
	measure :: proc(entries: []Entry, low, high: int) -> (box: Box) {
		box.low, box.high = low, high
		least, most := [3]u8{31, 31, 31}, [3]u8{0, 0, 0}
		for entry in entries[low:high] {
			box.pixels += entry.bin.count
			for c in 0 ..< 3 {
				least[c] = min(least[c], entry.channel[c])
				most[c] = max(most[c], entry.channel[c])
			}
		}
		for c in 0 ..< 3 {
			if span := int(most[c] - least[c]); span > box.span do box.span, box.axis = span, c
		}
		return
	}
	boxes := make([dynamic]Box, 0, GIF_COLORS, context.temp_allocator)
	append(&boxes, measure(entries[:], 0, len(entries)))
	for len(boxes) < GIF_COLORS {
		best, best_score := -1, u64(0)
		for box, i in boxes {
			if box.span == 0 do continue
			if score := box.pixels * u64(box.span); score > best_score do best, best_score = i, score
		}
		if best < 0 do break
		box := boxes[best]
		axis := box.axis
		part := entries[box.low:box.high]
		context.user_index = axis
		slice.sort_by(part, proc(a, b: Entry) -> bool {
			axis := context.user_index
			return a.channel[axis] < b.channel[axis]
		})
		// the median pixel, kept off both ends so each half holds an entry
		half, seen := box.pixels / 2, u64(0)
		split := box.low + 1
		for entry, i in part {
			seen += entry.bin.count
			if seen >= half {
				split = box.low + i + 1
				break
			}
		}
		split = clamp(split, box.low + 1, box.high - 1)
		boxes[best] = measure(entries[:], box.low, split)
		append(&boxes, measure(entries[:], split, box.high))
	}
	for box, i in boxes {
		sum: [3]u64
		for entry in entries[box.low:box.high] do sum += entry.bin.sum
		for c in 0 ..< 3 do palette.colors[i][c] = u8((sum[c] + box.pixels / 2) / box.pixels)
	}
	palette.count = len(boxes)
	return
}

// The palette index nearest to a colour (squared RGB distance; the first of equals).
gif_nearest :: proc(palette: ^Gif_Palette, r, g, b: u8) -> u8 {
	best, best_distance := 0, max(int)
	for color, i in palette.colors[:palette.count] {
		dr, dg, db := int(color[0]) - int(r), int(color[1]) - int(g), int(color[2]) - int(b)
		if distance := dr * dr + dg * dg + db * db; distance < best_distance do best, best_distance = i, distance
	}
	return u8(best)
}

// The palette index of every pixel through a lookup of 6 bits a channel (`lookup`: 1 << 18 entries, 0xFFFF where not
// yet known, filled as it goes; one per thread), the ordered dither first when asked.
@(private)
gif_index :: proc(palette: ^Gif_Palette, lookup: []u16, rgba: []u8, indices: []u8, width: int, dither: bool) {
	for &index, i in indices {
		r, g, b := rgba[i * 4], rgba[i * 4 + 1], rgba[i * 4 + 2]
		if dither {
			x, y := i % width, i / width
			offset := (int(GIF_BAYER[y & 3][x & 3]) * 2 - 15) * GIF_DITHER_SPREAD / 15
			r = u8(clamp(int(r) + offset, 0, 255))
			g = u8(clamp(int(g) + offset, 0, 255))
			b = u8(clamp(int(b) + offset, 0, 255))
		}
		key := int(r >> 2) << 12 | int(g >> 2) << 6 | int(b >> 2)
		found := lookup[key]
		if found == 0xFFFF {
			// the colour of the cell's middle
			found = u16(gif_nearest(palette, r & 0xFC | 2, g & 0xFC | 2, b & 0xFC | 2))
			lookup[key] = found
		}
		index = u8(found)
	}
}

// An LZW dictionary for lzw_encode: (prefix code << 8 | byte) -> its code, valid while its generation is the
// dictionary's (a clear code starts a new generation instead of wiping 4 MB). Allocate it with lzw_dictionary.
Lzw_Dictionary :: struct {
	entries:    []u32, // generation << 12 | code
	generation: u32,
}

// A dictionary for lzw_encode (4 MB), freed with lzw_dictionary_free.
lzw_dictionary :: proc() -> Lzw_Dictionary {
	return {entries = make([]u32, 1 << 20), generation = 1}
}

// Frees what lzw_dictionary allocated.
lzw_dictionary_free :: proc(dictionary: ^Lzw_Dictionary) {
	delete(dictionary.entries)
}

// Appends the GIF LZW code stream of `indices` (each below 1 << min_code_size) to `out`, bytes packed least
// significant bit first, not yet in sub-blocks: a clear code, the codes, the end code. A code is min_code_size + 1
// bits wide, one wider each time the dictionary's newest code reaches the next power of two, up to 12 bits; when the
// dictionary holds 4096 codes a clear code (12 bits) starts it over.
lzw_encode :: proc(indices: []u8, min_code_size: int, dictionary: ^Lzw_Dictionary, out: ^[dynamic]u8) {
	clear_code := 1 << uint(min_code_size)
	end_code := clear_code + 1
	code_size := min_code_size + 1
	newest := end_code // the newest code in the dictionary
	bits: u64
	bit_count: uint
	emit :: #force_inline proc(out: ^[dynamic]u8, bits: ^u64, bit_count: ^uint, code, size: int) {
		bits^ |= u64(code) << bit_count^
		bit_count^ += uint(size)
		for bit_count^ >= 8 {
			append(out, u8(bits^))
			bits^ >>= 8
			bit_count^ -= 8
		}
	}
	new_generation :: proc(dictionary: ^Lzw_Dictionary) {
		dictionary.generation += 1
		if dictionary.generation >= 1 << 20 {
			slice.zero(dictionary.entries)
			dictionary.generation = 1
		}
	}
	new_generation(dictionary)
	emit(out, &bits, &bit_count, clear_code, code_size)
	if len(indices) > 0 {
		generation := dictionary.generation
		prefix := int(indices[0])
		for value in indices[1:] {
			key := prefix << 8 | int(value)
			if entry := dictionary.entries[key]; entry >> 12 == generation {
				prefix = int(entry & 0xFFF)
				continue
			}
			emit(out, &bits, &bit_count, prefix, code_size)
			newest += 1
			dictionary.entries[key] = generation << 12 | u32(newest)
			if newest >= 1 << uint(code_size) do code_size += 1
			if newest == (1 << GIF_CODE_BITS_MAX) - 1 {
				emit(out, &bits, &bit_count, clear_code, code_size)
				new_generation(dictionary)
				generation = dictionary.generation
				code_size = min_code_size + 1
				newest = end_code
			}
			prefix = int(value)
		}
		emit(out, &bits, &bit_count, prefix, code_size)
	}
	emit(out, &bits, &bit_count, end_code, code_size)
	if bit_count > 0 do append(out, u8(bits))
}

// One encoded frame: the rectangle that changed and its LZW data in sub-blocks (`same`: nothing changed).
@(private)
Gif_Frame :: struct {
	left, top, width, height: int,
	data:                     [dynamic]u8,
	same:                     bool,
}

// What a worker of gif_encode keeps between frames.
@(private)
Gif_Worker :: struct {
	rgba:       []u8,
	lookup:     []u16,
	histogram:  []Gif_Bin,
	dictionary: Lzw_Dictionary,
	codes:      [dynamic]u8,
	sub:        []u8,
	failed:     bool,
}

// Runs body(data, index, worker) for every index in 0 ..< count on `threads` threads (this one among them), each
// index once.
@(private)
gif_parallel :: proc(count, threads: int, data: rawptr, body: proc(data: rawptr, index, worker: int)) {
	Job :: struct {
		next:  int,
		count: int,
		data:  rawptr,
		body:  proc(data: rawptr, index, worker: int),
	}
	job := Job{0, count, data, body}
	run :: proc(job: ^Job, worker: int) {
		for {
			index := sync.atomic_add(&job.next, 1)
			if index >= job.count do return
			job.body(job.data, index, worker)
		}
	}
	Start :: struct {
		job:    ^Job,
		worker: int,
	}
	workers := min(threads, count)
	started := make([]^thread.Thread, max(workers - 1, 0), context.temp_allocator)
	for &handle, i in started {
		handle = thread.create_and_start_with_poly_data(Start{&job, i + 1}, proc(start: Start) {
			run(start.job, start.worker)
		})
	}
	run(&job, 0)
	for handle in started {
		thread.join(handle)
		thread.destroy(handle)
	}
}

// Encodes the clip as an animated GIF that loops forever (see the file's header); false when a frame could not be
// read. The bytes are the caller's.
gif_encode :: proc(clip: Gif_Source, options: Gif_Options) -> (gif: []u8, stats: Gif_Stats, ok: bool) {
	source := clip
	if source.count <= 0 || source.width <= 0 || source.height <= 0 || source.fps <= 0 do return
	threads := options.threads > 0 ? options.threads : max(os.get_processor_core_count(), 1)
	pixels := source.width * source.height
	workers := make([]Gif_Worker, threads)
	defer {
		for &worker in workers {
			delete(worker.rgba)
			delete(worker.lookup)
			delete(worker.histogram)
			lzw_dictionary_free(&worker.dictionary)
			delete(worker.codes)
			delete(worker.sub)
		}
		delete(workers)
	}
	for &worker in workers {
		worker.rgba = make([]u8, pixels * 4)
		worker.lookup = make([]u16, 1 << 18)
		slice.fill(worker.lookup, 0xFFFF)
		worker.dictionary = lzw_dictionary()
		worker.sub = make([]u8, pixels)
	}

	// the palette, from frames spread over the clip
	Palette_Job :: struct {
		source:  ^Gif_Source,
		workers: []Gif_Worker,
		samples: int,
	}
	samples := min(source.count, GIF_PALETTE_FRAMES)
	palette_job := Palette_Job{&source, workers, samples}
	gif_parallel(samples, threads, &palette_job, proc(data: rawptr, index, worker_index: int) {
		job := (^Palette_Job)(data)
		worker := &job.workers[worker_index]
		if worker.histogram == nil do worker.histogram = make([]Gif_Bin, GIF_BINS)
		frame := index * job.source.count / job.samples
		if !job.source.frame(job.source.data, frame, worker.rgba) {
			worker.failed = true
			return
		}
		gif_histogram_add(worker.histogram, worker.rgba)
	})
	histogram := make([]Gif_Bin, GIF_BINS)
	defer delete(histogram)
	for worker in workers {
		if worker.failed do return
		if worker.histogram == nil do continue
		for bin, i in worker.histogram {
			histogram[i].count += bin.count
			histogram[i].sum += bin.sum
		}
	}
	palette := gif_palette(histogram)
	stats.colors = palette.count

	out := make([dynamic]u8, 0, 1 << 20)
	gif_header(&out, source.width, source.height, &palette)

	// the frames, a batch at a time: each indexed, then each against the one before it
	Batch_Job :: struct {
		source:  ^Gif_Source,
		workers: []Gif_Worker,
		palette: ^Gif_Palette,
		dither:  bool,
		first:   int, // the batch's first frame
		indices: [][]u8, // [0]: the frame before the batch (nil for the clip's first), then the batch's
		frames:  []Gif_Frame,
	}
	batch_size := threads * 2
	indices := make([][]u8, batch_size + 1)
	frames := make([]Gif_Frame, batch_size)
	defer {
		for frame_indices in indices do delete(frame_indices)
		delete(indices)
		for frame in frames do delete(frame.data)
		delete(frames)
	}
	for &frame_indices in indices[1:] do frame_indices = make([]u8, pixels)
	job := Batch_Job{&source, workers, &palette, options.dither, 0, indices, frames}
	pending: Maybe(Gif_Frame) // written once its delay is known: the frames after it that changed nothing add to it
	pending_from := 0
	pending_data := make([dynamic]u8)
	defer delete(pending_data)
	for first := 0; first < source.count; first += batch_size {
		count := min(batch_size, source.count - first)
		job.first = first
		gif_parallel(count, threads, &job, proc(data: rawptr, index, worker_index: int) {
			job := (^Batch_Job)(data)
			worker := &job.workers[worker_index]
			if !job.source.frame(job.source.data, job.first + index, worker.rgba) {
				worker.failed = true
				return
			}
			gif_index(job.palette, worker.lookup, worker.rgba, job.indices[index + 1], job.source.width, job.dither)
		})
		for worker in workers do if worker.failed do return
		gif_parallel(count, threads, &job, proc(data: rawptr, index, worker_index: int) {
			job := (^Batch_Job)(data)
			gif_frame(
				&job.frames[index],
				job.indices[index],
				job.indices[index + 1],
				job.source.width,
				job.source.height,
				&job.workers[worker_index],
			)
		})
		for i in 0 ..< count {
			frame := &frames[i]
			if frame.same do continue
			if previous, has := pending.?; has {
				gif_write_frame(&out, previous, pending_data[:], gif_delay(pending_from, first + i, source.fps))
				stats.frames += 1
			}
			pending = Gif_Frame {
				left   = frame.left,
				top    = frame.top,
				width  = frame.width,
				height = frame.height,
			}
			clear(&pending_data)
			append(&pending_data, ..frame.data[:])
			pending_from = first + i
		}
		// the batch's last frame is the next batch's "before"
		indices[0], indices[count] = indices[count], indices[0]
		if indices[count] == nil do indices[count] = make([]u8, pixels)
	}
	if previous, has := pending.?; has {
		gif_write_frame(&out, previous, pending_data[:], gif_delay(pending_from, source.count, source.fps))
		stats.frames += 1
	}
	append(&out, 0x3B) // trailer
	return out[:], stats, true
}

// How long, in hundredths of a second, frames `from` ..< `to` of a clip at `fps` show: each frame's start rounded, so
// the delays add up to the clip's length.
gif_delay :: proc(from, to, fps: int) -> int {
	centis :: proc(frame, fps: int) -> int {
		return (200 * frame + fps) / (2 * fps)
	}
	return centis(to, fps) - centis(from, fps)
}

// Encodes the frame `current` (palette indices) against `before` (nil: the clip's first, written whole): the rectangle
// that changed, its unchanged pixels GIF_TRANSPARENT, as LZW in sub-blocks; `same` when nothing changed.
@(private)
gif_frame :: proc(frame: ^Gif_Frame, before, current: []u8, width, height: int, worker: ^Gif_Worker) {
	clear(&frame.data)
	frame.same = false
	left, top, right, bottom := 0, 0, width - 1, height - 1
	if before != nil {
		left, top, right, bottom = width, height, -1, -1
		for y in 0 ..< height {
			row := y * width
			changed_left := -1
			for x in 0 ..< width {
				if current[row + x] != before[row + x] {
					changed_left = x
					break
				}
			}
			if changed_left < 0 do continue
			changed_right := changed_left
			for x := width - 1; x > changed_left; x -= 1 {
				if current[row + x] != before[row + x] {
					changed_right = x
					break
				}
			}
			left, right = min(left, changed_left), max(right, changed_right)
			top = min(top, y)
			bottom = y
		}
		if right < 0 {
			frame.same = true
			return
		}
	}
	frame.left, frame.top = left, top
	frame.width, frame.height = right - left + 1, bottom - top + 1
	sub := worker.sub[:frame.width * frame.height]
	for y in 0 ..< frame.height {
		row := (top + y) * width + left
		line := sub[y * frame.width:][:frame.width]
		copy(line, current[row:][:frame.width])
		if before != nil {
			for &index, x in line do if before[row + x] == index do index = GIF_TRANSPARENT
		}
	}
	clear(&worker.codes)
	lzw_encode(sub, GIF_MIN_CODE_SIZE, &worker.dictionary, &worker.codes)
	for start := 0; start < len(worker.codes); start += 255 {
		block := worker.codes[start:min(start + 255, len(worker.codes))]
		append(&frame.data, u8(len(block)))
		append(&frame.data, ..block)
	}
	append(&frame.data, 0)
}

@(private)
gif_u16 :: proc(out: ^[dynamic]u8, value: int) {
	append(out, u8(value), u8(value >> 8))
}

// GIF89a's header: the logical screen, the global palette (256 entries), and the loop-forever extension.
@(private)
gif_header :: proc(out: ^[dynamic]u8, width, height: int, palette: ^Gif_Palette) {
	append(out, ..transmute([]u8)string("GIF89a"))
	gif_u16(out, width)
	gif_u16(out, height)
	append(out, 0xF7, 0, 0) // a global colour table of 256 entries, 8 bits a channel; background 0; square pixels
	for color in palette.colors do append(out, color[0], color[1], color[2])
	append(out, 0x21, 0xFF, 11)
	append(out, ..transmute([]u8)string("NETSCAPE2.0"))
	append(out, 3, 1, 0, 0, 0) // loop forever
}

// One frame: its graphic control (kept under the next frame, its unchanged pixels transparent, its delay) and image.
@(private)
gif_write_frame :: proc(out: ^[dynamic]u8, frame: Gif_Frame, data: []u8, delay: int) {
	append(out, 0x21, 0xF9, 4, 1 << 2 | 1) // disposal 1 (keep), transparency on
	gif_u16(out, delay)
	append(out, GIF_TRANSPARENT, 0)
	append(out, 0x2C)
	gif_u16(out, frame.left)
	gif_u16(out, frame.top)
	gif_u16(out, frame.width)
	gif_u16(out, frame.height)
	append(out, 0) // no local colour table, not interlaced
	append(out, GIF_MIN_CODE_SIZE)
	append(out, ..data)
}

// Scales an RGBA image down to `width` x `height` (each smaller or equal), each pixel the mean of the source pixels
// it covers (box filter), into `out` (width * height * 4 bytes).
gif_downscale :: proc(rgba: []u8, source_width, source_height: int, out: []u8, width, height: int) {
	for y in 0 ..< height {
		y0 := y * source_height / height
		y1 := max((y + 1) * source_height / height, y0 + 1)
		for x in 0 ..< width {
			x0 := x * source_width / width
			x1 := max((x + 1) * source_width / width, x0 + 1)
			sum: [4]int
			for sy in y0 ..< y1 {
				row := (sy * source_width + x0) * 4
				for sx in 0 ..< x1 - x0 {
					for c in 0 ..< 4 do sum[c] += int(rgba[row + sx * 4 + c])
				}
			}
			area := (x1 - x0) * (y1 - y0)
			for c in 0 ..< 4 do out[(y * width + x) * 4 + c] = u8((sum[c] + area / 2) / area)
		}
	}
}

// The size a frame of `width` x `height` takes in a GIF at most `max_width` wide (the aspect kept).
gif_size :: proc(width, height, max_width: int) -> (int, int) {
	if width <= max_width do return width, height
	return max_width, max(int(math.round(f64(height) * f64(max_width) / f64(width))), 1)
}
