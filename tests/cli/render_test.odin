// `render`'s cutting of Godot's movie to the clip (src/cli/cmd_render.odin): an AVI laid out as Godot's MJPEG movie
// writer lays it out keeps exactly the asked frames with their sound, its counts and index rewritten; a WAV keeps
// their audio blocks; the game's clip line and the output's kind are read.
package test_cli

import "core:encoding/endian"
import "core:testing"
import "unified:cli"

@(private = "file")
put_u32 :: proc(out: ^[dynamic]u8, value: int) {
	bytes: [4]u8
	endian.put_u32(bytes[:], .Little, u32(value))
	append(out, ..bytes[:])
}

@(private = "file")
get_u32 :: proc(data: []u8, at: int) -> int {
	value, _ := endian.get_u32(data[at:at + 4], .Little)
	return int(value)
}

@(private = "file")
chunk :: proc(out: ^[dynamic]u8, id: string, data: []u8) {
	append(out, ..transmute([]u8)id)
	put_u32(out, len(data))
	append(out, ..data)
	if len(data) & 1 != 0 do append(out, 0)
}

// A frame's video bytes in the test AVI: odd sizes too (padded), each byte the frame's number.
@(private = "file")
video_bytes :: proc(frame: int) -> []u8 {
	data := make([]u8, 9 + frame % 4)
	for &value in data do value = u8(frame)
	return data
}

@(private = "file")
AUDIO_BLOCK :: 16

// An AVI of `frames` frames as Godot's movie writer lays one out: hdrl (avih; a video strl holding the odml list; an
// audio strl), movi (a video chunk, then an audio chunk, per frame), idx1.
@(private = "file")
godot_avi :: proc(frames: int) -> []u8 {
	strh :: proc(kind: string, length: int) -> []u8 {
		data := make([dynamic]u8)
		append(&data, ..transmute([]u8)kind)
		for _ in 0 ..< 7 do put_u32(&data, 0)
		put_u32(&data, length) // dwLength (at 32)
		for _ in 0 ..< 3 do put_u32(&data, 0)
		return data[:]
	}
	list :: proc(out: ^[dynamic]u8, kind: string, contents: []u8) {
		data := make([dynamic]u8)
		append(&data, ..transmute([]u8)kind)
		append(&data, ..contents)
		chunk(out, "LIST", data[:])
	}
	avih := make([dynamic]u8)
	for field in 0 ..< 14 do put_u32(&avih, field == 4 ? frames : 0) // dwTotalFrames at 16
	odml := make([dynamic]u8)
	dmlh := make([dynamic]u8)
	put_u32(&dmlh, frames)
	chunk(&odml, "dmlh", dmlh[:])
	video := make([dynamic]u8)
	chunk(&video, "strh", strh("vids", frames))
	chunk(&video, "strf", make([]u8, 40))
	list(&video, "odml", odml[:])
	audio := make([dynamic]u8)
	chunk(&audio, "strh", strh("auds", frames * 1600))
	chunk(&audio, "strf", make([]u8, 16))
	hdrl := make([dynamic]u8)
	chunk(&hdrl, "avih", avih[:])
	list(&hdrl, "strl", video[:])
	list(&hdrl, "strl", audio[:])
	movi := make([dynamic]u8)
	for frame in 0 ..< frames {
		chunk(&movi, "00db", video_bytes(frame))
		sound := make([]u8, AUDIO_BLOCK)
		for &value in sound do value = u8(100 + frame)
		chunk(&movi, "01wb", sound)
	}
	body := make([dynamic]u8)
	append(&body, ..transmute([]u8)string("AVI "))
	list(&body, "hdrl", hdrl[:])
	list(&body, "movi", movi[:])
	chunk(&body, "idx1", make([]u8, 32 * frames)) // its entries don't matter: trim writes its own
	out := make([dynamic]u8)
	chunk(&out, "RIFF", body[:])
	return out[:]
}

@(test)
avi_trim_keeps_the_clips_frames :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	avi := godot_avi(9)
	out, problem := cli.avi_trim(avi, 2, 5)
	if !testing.expect_value(t, problem, "") do return
	testing.expect_value(t, string(out[:4]), "RIFF")
	testing.expect_value(t, get_u32(out, 4), len(out) - 8)
	// the counts: the main header's, each stream's, OpenDML's (nested in the video stream's list, as Godot writes it)
	find :: proc(data: []u8, id: string) -> int {
		for at in 0 ..< len(data) - 4 do if string(data[at:at + 4]) == id do return at
		return -1
	}
	testing.expect_value(t, get_u32(out, find(out, "avih") + 8 + 16), 5)
	testing.expect_value(t, get_u32(out, find(out, "dmlh") + 8), 5)
	vids := find(out, "vids")
	testing.expect_value(t, get_u32(out, vids + 32), 5)
	auds := find(out, "auds")
	testing.expect_value(t, get_u32(out, auds + 32), 5 * 1600)
	// movi: frames 2 to 6, video then sound, in order
	movi := find(out, "movi")
	at := movi + 4
	for frame in 2 ..< 7 {
		testing.expect_value(t, string(out[at:at + 4]), "00db")
		size := get_u32(out, at + 4)
		testing.expect_value(t, size, 9 + frame % 4)
		testing.expect_value(t, out[at + 8], u8(frame))
		at += 8 + size + (size & 1)
		testing.expect_value(t, string(out[at:at + 4]), "01wb")
		testing.expect_value(t, out[at + 8], u8(100 + frame))
		at += 8 + AUDIO_BLOCK
	}
	testing.expect_value(t, get_u32(out, movi - 4), at - movi) // the movi list's size
	// idx1: an entry per chunk, its offset from the movi fourcc to the chunk
	testing.expect_value(t, string(out[at:at + 4]), "idx1")
	testing.expect_value(t, get_u32(out, at + 4), 10 * 16)
	for entry in 0 ..< 10 {
		base := at + 8 + entry * 16
		target := movi + get_u32(out, base + 8)
		testing.expect_value(t, string(out[target:target + 4]), string(out[base:base + 4]))
		testing.expect_value(t, get_u32(out, target + 4), get_u32(out, base + 12))
	}
	testing.expect_value(t, at + 8 + 10 * 16, len(out))
	// the last frames, and frames it doesn't have
	_, problem = cli.avi_trim(avi, 7, 2)
	testing.expect_value(t, problem, "")
	_, problem = cli.avi_trim(avi, 8, 2)
	testing.expect(t, problem != "", "frames past the end are refused")
	_, problem = cli.avi_trim(avi[:100], 0, 1)
	testing.expect(t, problem != "", "a cut file is refused")
}

@(test)
wav_trim_keeps_the_clips_audio :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	rate, align, fps := 48_000, 8, 30
	block := rate / fps * align
	wav := make([dynamic]u8)
	append(&wav, ..transmute([]u8)string("RIFF"))
	put_u32(&wav, 0)
	append(&wav, ..transmute([]u8)string("WAVEfmt "))
	put_u32(&wav, 16)
	append(&wav, 1, 0, 2, 0)
	put_u32(&wav, rate)
	put_u32(&wav, rate * align)
	append(&wav, u8(align), 0, 32, 0)
	append(&wav, ..transmute([]u8)string("data"))
	put_u32(&wav, 6 * block)
	for frame in 0 ..< 6 do for _ in 0 ..< block do append(&wav, u8(frame))
	out, ok := cli.wav_trim(wav[:], 1, 3, fps)
	if !testing.expect(t, ok) do return
	data := len(out) - 3 * block
	testing.expect_value(t, string(out[data - 8:data - 4]), "data")
	testing.expect_value(t, get_u32(out, data - 4), 3 * block)
	testing.expect_value(t, get_u32(out, 4), len(out) - 8)
	testing.expect_value(t, out[data], 1)
	testing.expect_value(t, out[len(out) - 1], 3)
	_, ok = cli.wav_trim(transmute([]u8)string("not a wav"), 0, 1, fps)
	testing.expect(t, !ok)
}

@(test)
render_reads_its_output_and_the_clip_line :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	testing.expect_value(t, cli.render_format("clip.AVI"), "avi")
	testing.expect_value(t, cli.render_format("docs/clip.gif"), "gif")
	testing.expect_value(t, cli.render_format("frames/"), "png")
	testing.expect_value(t, cli.render_format("clip.mp4"), "")
	output :=
		"Godot Engine v4.7\nunified: result {}\n" +
		`UNIFIED_CLIP {"movie_frame":3,"frames":150,"from":12,"to":652,"fps":15,"tick_hz":64,"speed":1}` +
		"\n"
	clip, found := cli.render_clip_line(output)
	testing.expect(t, found)
	testing.expect_value(t, clip.movie_frame, 3)
	testing.expect_value(t, clip.frames, 150)
	testing.expect_value(t, clip.from, 12)
	testing.expect_value(t, clip.to, 652)
	_, found = cli.render_clip_line("a game that quit early\n")
	testing.expect(t, !found)
}
