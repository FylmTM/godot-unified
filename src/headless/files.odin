// Input logs as files: the replay a headless run or a recorded session leaves (sim keeps the bytes: log_encode,
// log_decode, Log_Sink).
package headless

import "core:os"

import "unified:sim"

// Writes the log to a file (sim.log_encode's bytes).
log_write :: proc(path: string, input_log: ^sim.Input_Log($G)) -> bool {
	data := sim.log_encode(input_log)
	defer delete(data)
	return write_file(path, data)
}

// Reads a log file written by log_write (or a relay's recording) for a replay; false when it is missing or does
// not decode for game G.
log_read :: proc(path: string, $G: typeid) -> (input_log: sim.Input_Log(G), ok: bool) {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil do return
	defer delete(data)
	return sim.log_decode(data, G)
}

// Writes `data` to a file, replacing it; true on success. (Non-generic: log_write's home for core:os.)
@(private)
write_file :: proc(path: string, data: []u8) -> bool {
	return os.write_entire_file(path, data) == nil
}

@(private)
File_Sink :: struct {
	file:    ^os.File,
	pending: [dynamic]u8, // appended bytes not written yet, from offset `written`
	written: int,
	ok:      bool,
}

@(private)
file_sink_flush :: proc(sink: ^File_Sink) {
	if len(sink.pending) > 0 {
		_, err := os.write_at(sink.file, sink.pending[:], i64(sink.written))
		sink.ok &&= err == nil
		sink.written += len(sink.pending)
		clear(&sink.pending)
	}
}

// A log sink (sim.Log_Sink) into a new file at `path` (64 KB written at a time): a relay's recording. The sink owns
// the file: close flushes and closes it.
log_sink_file :: proc(path: string) -> (sink: sim.Log_Sink, ok: bool) {
	file, err := os.create(path)
	if err != nil {
		return
	}
	file_sink := new(File_Sink)
	file_sink.file = file
	file_sink.ok = true
	sink.user = file_sink
	sink.write = proc(user: rawptr, offset: int, bytes: []u8) -> bool {
		file_sink := (^File_Sink)(user)
		if offset == file_sink.written + len(file_sink.pending) {
			append(&file_sink.pending, ..bytes)
			if len(file_sink.pending) >= 64 * 1024 {
				file_sink_flush(file_sink)
			}
		} else {
			file_sink_flush(file_sink)
			_, err := os.write_at(file_sink.file, bytes, i64(offset))
			file_sink.ok &&= err == nil
		}
		return file_sink.ok
	}
	sink.close = proc(user: rawptr) {
		file_sink := (^File_Sink)(user)
		file_sink_flush(file_sink)
		os.close(file_sink.file)
		delete(file_sink.pending)
		free(file_sink)
	}
	return sink, true
}
