// `render --player 1,2` (src/cli/cmd_render.odin): the views' renders laid out side by side, each frame of the clip the
// same moment of every view whatever movie frame each render's clip started on, as PNG frames (byte for byte) and as a
// GIF (within the palette's error); the player list it takes; renders whose clips differ are refused.
package test_cli

import "core:fmt"
import "core:image"
import "core:image/png"
import "core:math"
import "core:os"
import "core:strings"
import "core:testing"
import "unified:cli"

@(private = "file")
PANE_WIDTH :: 24
@(private = "file")
PANE_HEIGHT :: 12
@(private = "file")
MOMENTS :: 5

// The pixels view `pane` shows at `moment` of the clip (moments before the clip, its lead, are negative): every moment
// and view its own picture.
@(private = "file")
pane_pixels :: proc(pane, moment: int) -> []u8 {
	pixels := make([]u8, PANE_WIDTH * PANE_HEIGHT * 4)
	for y in 0 ..< PANE_HEIGHT {
		for x in 0 ..< PANE_WIDTH {
			at := (y * PANE_WIDTH + x) * 4
			pixels[at] = u8(x * 10 + (moment + 4) * 7)
			pixels[at + 1] = u8(y * 20 + pane * 90)
			pixels[at + 2] = u8((moment + 4) * 40 + pane * 3)
			pixels[at + 3] = 255
		}
	}
	return pixels
}

// A pane's render as Godot's movie writer leaves it: `lead` frames before the clip, then its MOMENTS frames, numbered
// from 0; its clip line says the clip starts at movie frame `lead`.
@(private = "file")
write_pane :: proc(dir: string, pane, lead: int) -> cli.Render_Pane {
	_ = os.make_directory_all(dir)
	for frame in 0 ..< lead + MOMENTS {
		img := image.Image {
			width    = PANE_WIDTH,
			height   = PANE_HEIGHT,
			channels = 4,
			depth    = 8,
		}
		pixels := pane_pixels(pane, frame - lead)
		append(&img.pixels, ..pixels)
		encoded: [dynamic]u8
		_ = png.save_to_buffer(&encoded, &img)
		_ = os.write_entire_file(fmt.tprintf("%s/frame%08d.png", dir, frame), encoded[:])
	}
	return {work = dir, clip = {movie_frame = lead, frames = MOMENTS, from = 100, to = 120, fps = 15, tick_hz = 60}}
}

// A new directory of the test's own (the odin and box3d-debug suites run the tests at once), removed by the caller.
@(private = "file")
test_dir :: proc() -> string {
	dir, _ := os.make_directory_temp("", "unified-side-by-side-*", context.allocator)
	return dir
}

@(test)
side_by_side_frames_are_each_views_same_moment :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir := test_dir()
	defer os.remove_all(dir)
	// the second view's play scene opened later: its clip starts two movie frames later than the first's
	panes := []cli.Render_Pane {
		write_pane(fmt.tprintf("%s/p1", dir), 0, 3),
		write_pane(fmt.tprintf("%s/p2", dir), 1, 5),
	}
	testing.expect_value(t, cli.render_panes_agree(panes), "")
	out := fmt.tprintf("%s/out", dir)
	_ = os.make_directory_all(out)
	bytes, problem := cli.render_side_by_side_png(panes, out)
	testing.expectf(t, problem == "" && bytes > 0, "PNG frames: %q, %d bytes", problem, bytes)
	for moment in 0 ..< MOMENTS {
		img, err := png.load_from_file(fmt.tprintf("%s/frame%08d.png", out, moment), {.alpha_add_if_missing})
		if !testing.expectf(t, err == nil, "frame %d loads", moment) do return
		if !testing.expect(t, img.width == 2 * PANE_WIDTH && img.height == PANE_HEIGHT) do return
		for pane in 0 ..< 2 {
			want := pane_pixels(pane, moment)
			row := PANE_WIDTH * 4
			for y in 0 ..< PANE_HEIGHT {
				got := img.pixels[(y * 2 + pane) * row:][:row]
				if string(got) != string(want[y * row:][:row]) {
					testing.expectf(
						t,
						false,
						"frame %d: view %d's half is not its frame of that moment (row %d)",
						moment,
						pane + 1,
						y,
					)
					break
				}
			}
		}
	}

	gif, stats, gif_problem := cli.render_side_by_side_gif(panes, 15, false)
	if !testing.expectf(t, gif_problem == "", "GIF: %s", gif_problem) do return
	read := test_gif_decode(gif)
	if !testing.expect(t, read.ok && read.width == 2 * PANE_WIDTH && read.height == PANE_HEIGHT, "the GIF decodes") do return
	testing.expect_value(t, len(read.frames), MOMENTS)
	for decoded, moment in read.frames {
		worst := 0.0
		for pane in 0 ..< 2 {
			want := pane_pixels(pane, moment)
			for y in 0 ..< PANE_HEIGHT {
				for x in 0 ..< PANE_WIDTH {
					source := want[(y * PANE_WIDTH + x) * 4:]
					got := decoded[(y * 2 * PANE_WIDTH + pane * PANE_WIDTH + x) * 3:]
					src := [3]f64{f64(source[0]), f64(source[1]), f64(source[2])}
					// how far the pixel came out past the nearest colour the palette has
					nearest := max(f64)
					for color in read.palette[:stats.colors] {
						delta := [3]f64{f64(color[0]), f64(color[1]), f64(color[2])} - src
						nearest = min(nearest, math.sqrt(delta.x * delta.x + delta.y * delta.y + delta.z * delta.z))
					}
					delta := [3]f64{f64(got[0]), f64(got[1]), f64(got[2])} - src
					worst = max(worst, math.sqrt(delta.x * delta.x + delta.y * delta.y + delta.z * delta.z) - nearest)
				}
			}
		}
		// the palette lookup's 6-bit cell: at most 2 * sqrt(3) * 2 past the nearest (gif_colours_stay_within_the_palette_error)
		testing.expectf(t, worst <= 7, "GIF frame %d: a pixel %.1f past its nearest palette colour", moment, worst)
	}

	// renders whose clips are not the same moments are refused
	late := panes[1]
	late.clip.from += 1
	testing.expect(t, strings.contains(cli.render_panes_agree({panes[0], late}), "the views' clips differ"))
}

@(test)
render_reads_its_players :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	players, ok := cli.render_players("")
	testing.expect(t, ok && len(players) == 1 && players[0] == 0, "none named: whoever recorded it")
	players, ok = cli.render_players("2")
	testing.expect(t, ok && len(players) == 1 && players[0] == 2)
	players, ok = cli.render_players("1, 2,3,4")
	testing.expect(t, ok && len(players) == 4 && players[3] == 4)
	for bad in ([]string{"1,2,3,4,5", "0", "1,,2", "x", "65"}) {
		_, ok = cli.render_players(bad)
		testing.expectf(t, !ok, "--player %s is refused", bad)
	}
}

// Writes RGBA pixels as a PNG.
@(private = "file")
write_png :: proc(path: string, pixels: []u8, width, height: int) {
	img := image.Image {
		width    = width,
		height   = height,
		channels = 4,
		depth    = 8,
	}
	append(&img.pixels, ..pixels)
	encoded: [dynamic]u8
	_ = png.save_to_buffer(&encoded, &img)
	_ = os.write_entire_file(path, encoded[:])
}

// A picture that hardly changes from moment to moment: pane_pixels' first moment with one white pixel moving across it
// (a game where little moves: each frame within the noise allowance of the next).
@(private = "file")
small_motion :: proc(_, moment: int) -> []u8 {
	pixels := pane_pixels(0, 0)
	at := (5 * PANE_WIDTH + moment * 3) * 4
	pixels[at], pixels[at + 1], pixels[at + 2] = 255, 255, 255
	return pixels
}

// The godot suite's check of a side-by-side render against a single one (render_views_in_sync): a view that is the
// single render's frame, or near it (a game's GPU particles drawn differently), passes; a view far from it fails, and
// one a frame late or early fails also where every frame is within the noise allowance of the next.
@(test)
side_by_side_check_tolerates_noise_not_a_frame_off :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir := test_dir()
	defer os.remove_all(dir)
	Picture :: proc(pane, moment: int) -> []u8
	singles :: proc(dir, name: string, picture: Picture) -> []string {
		paths := make([]string, MOMENTS)
		for &path, moment in paths {
			path = fmt.tprintf("%s/%s_single%d.png", dir, name, moment)
			write_png(path, picture(0, moment), PANE_WIDTH, PANE_HEIGHT)
		}
		return paths
	}
	// each view of the side-by-side frame m shows moment m + shift[view], `noise` added to a few pixels
	composed :: proc(dir, name: string, picture: Picture, noise: u8, shift: [2]int) -> []string {
		paths := make([]string, MOMENTS)
		for &path, moment in paths {
			whole := make([]u8, 2 * PANE_WIDTH * PANE_HEIGHT * 4)
			views := [2][]u8 {
				picture(0, clamp(moment + shift[0], 0, MOMENTS - 1)),
				picture(0, clamp(moment + shift[1], 0, MOMENTS - 1)),
			}
			for view in views do for i := 0; i < len(view); i += 4 * 7 do view[i] += noise // a flame's flicker
			cli.render_compose(views[:], PANE_WIDTH, PANE_HEIGHT, whole)
			path = fmt.tprintf("%s/%s%d.png", dir, name, moment)
			write_png(path, whole, 2 * PANE_WIDTH, PANE_HEIGHT)
		}
		return paths
	}
	single := singles(dir, "big", pane_pixels)
	testing.expect_value(t, cli.render_views_in_sync(composed(dir, "exact", pane_pixels, 0, {0, 0}), single, 2), "")
	testing.expect_value(t, cli.render_views_in_sync(composed(dir, "flicker", pane_pixels, 9, {0, 0}), single, 2), "")
	far := cli.render_views_in_sync(composed(dir, "far", pane_pixels, 120, {0, 0}), single, 2)
	testing.expectf(t, strings.contains(far, "from the single render's"), "a view far from it: %q", far)
	late := cli.render_views_in_sync(composed(dir, "late", pane_pixels, 0, {0, 1}), single, 2)
	testing.expectf(t, strings.has_prefix(late, "view 2"), "a view a frame late: %q", late)
	// little moves: each view within the noise allowance of every frame, only the clip as a whole tells
	quiet := singles(dir, "small", small_motion)
	testing.expect_value(t, cli.render_views_in_sync(composed(dir, "small", small_motion, 3, {0, 0}), quiet, 2), "")
	late = cli.render_views_in_sync(composed(dir, "small_late", small_motion, 0, {0, 1}), quiet, 2)
	testing.expectf(t, strings.contains(late, "view 2 is out of sync"), "a view a frame late: %q", late)
	early := cli.render_views_in_sync(composed(dir, "small_early", small_motion, 0, {-1, 0}), quiet, 2)
	testing.expectf(t, strings.contains(early, "view 1 is out of sync"), "a view a frame early: %q", early)
}
