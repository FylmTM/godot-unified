// The gif row of `uni bench`: cli.gif_encode on a 10 s clip at 960x540 and 15 fps, like a README clip of a game: a
// sky gradient, a floor grid scrolling under a moving camera (every frame changes almost everywhere), discs crossing
// it and a still HUD panel. The frames are made before the clock starts (30, cycled), so it times the encoder alone:
// the palette, the indexing, the frame differences and LZW. One JSON line.
package cli_bench

import "core:fmt"
import "core:math"
import "core:time"

import "unified:cli"

WIDTH :: 960
HEIGHT :: 540
FPS :: 15
SECONDS :: 10
DISTINCT :: 30 // frames made; the clip cycles through them

// One frame of the synthetic clip at `phase` (0 ..< 1 over the cycle), RGBA.
make_frame :: proc(phase: f64) -> []u8 {
	frame := make([]u8, WIDTH * HEIGHT * 4)
	horizon := HEIGHT * 2 / 5
	scroll := phase * 64
	for y in 0 ..< HEIGHT {
		for x in 0 ..< WIDTH {
			r, g, b: f64
			if y < horizon {
				t := f64(y) / f64(horizon)
				r, g, b = 40 + 60 * t, 70 + 80 * t, 140 + 70 * t
			} else {
				// a floor seen in perspective: grid lines get closer toward the horizon
				depth := 1 / (f64(y - horizon) + 8) * 4000
				u := (f64(x) - WIDTH / 2) * depth / 400 + scroll
				v := depth + scroll * 3
				line := math.abs(u - math.round(u / 32) * 32) < 1.2 || math.abs(v - math.round(v / 32) * 32) < 1.2
				shade := 0.6 + 0.4 * f64(y - horizon) / f64(HEIGHT - horizon)
				r, g, b = 50 * shade, 60 * shade, 90 * shade
				if line do r, g, b = 90 * shade, 200 * shade, 220 * shade
			}
			at := (y * WIDTH + x) * 4
			frame[at], frame[at + 1], frame[at + 2], frame[at + 3] = u8(r), u8(g), u8(b), 255
		}
	}
	// discs crossing the floor
	for disc in 0 ..< 12 {
		angle := phase * 2 * math.PI + f64(disc) * 0.52
		center_x := WIDTH / 2 + math.cos(angle) * f64(120 + disc * 25)
		center_y := HEIGHT * 0.7 + math.sin(angle) * f64(40 + disc * 6)
		radius := 10 + f64(disc % 4) * 4
		color := [3]u8{u8(120 + disc * 11), u8(60 + disc * 15), u8(200 - disc * 12)}
		for y in int(center_y - radius) ..= int(center_y + radius) {
			for x in int(center_x - radius) ..= int(center_x + radius) {
				if x < 0 || y < 0 || x >= WIDTH || y >= HEIGHT do continue
				dx, dy := f64(x) - center_x, f64(y) - center_y
				if dx * dx + dy * dy > radius * radius do continue
				light := 1 - (dx + dy) / (radius * 4)
				at := (y * WIDTH + x) * 4
				for c in 0 ..< 3 do frame[at + c] = u8(clamp(f64(color[c]) * light, 0, 255))
			}
		}
	}
	// a still HUD panel
	for y in 16 ..< 120 {
		for x in 16 ..< 300 {
			at := (y * WIDTH + x) * 4
			frame[at], frame[at + 1], frame[at + 2] = 28, 30, 40
			if y > 60 && y < 72 && x > 30 && x < 250 do frame[at], frame[at + 1], frame[at + 2] = 90, 240, 160
		}
	}
	return frame
}

main :: proc() {
	frames := make([][]u8, DISTINCT)
	for &frame, i in frames do frame = make_frame(f64(i) / DISTINCT)
	count := FPS * SECONDS
	source := cli.Gif_Source {
		count = count,
		width = WIDTH,
		height = HEIGHT,
		fps = FPS,
		data = &frames,
		frame = proc(data: rawptr, index: int, out: []u8) -> bool {
			frames := (^[][]u8)(data)
			copy(out, frames[index % len(frames)])
			return true
		},
	}
	started := time.tick_now()
	gif, stats, ok := cli.gif_encode(source, {})
	seconds := time.duration_seconds(time.tick_since(started))
	if !ok do return
	fmt.printfln(
		`{{"seconds":%.3f,"bytes":%d,"frames":%d,"gif_frames":%d,"colors":%d,"width":%d,"height":%d,"fps":%d}}`,
		seconds,
		len(gif),
		count,
		stats.frames,
		stats.colors,
		WIDTH,
		HEIGHT,
		FPS,
	)
}
