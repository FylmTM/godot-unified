package main

import "unified:cli"

// `uni bench`'s gif row (this repo): the GIF encoder `uni render` writes a .gif with, on a synthetic 10 s 960x540
// clip at 15 fps (tests/cli/bench), no target: how long the encoding takes and how big the file is.
Gif_Report :: struct {
	seconds:    f64,
	bytes:      int,
	frames:     int,
	gif_frames: int,
	colors:     int,
	width:      int,
	height:     int,
	fps:        int,
}

gif_bench :: proc(work, binary: string) -> (data: any, ok: bool) {
	report := new(Gif_Report)
	if !cli.run_report(binary, {}, cli.join(work, "gif"), 120, report) {
		return nil, false
	}
	cli.log(
		"%-12s %d frames of %dx%d at %d fps encoded in %.2f s (%.1f ms a frame): %.1f MB, %d colours",
		"gif",
		report.frames,
		report.width,
		report.height,
		report.fps,
		report.seconds,
		report.seconds * 1000 / f64(max(report.frames, 1)),
		f64(report.bytes) / f64(1 << 20),
		report.colors,
	)
	return report^, true
}
