package cli

import "core:compress/deflate"
import "core:encoding/endian"
import "core:hash"
import "core:os"
import "core:strings"

// Zip archives (SPEC.md, Dependencies): reading the Godot editor, export templates (straight from the 1.3 GB
// archive over HTTP byte ranges), writing Windows release zips. Stored
// and deflated members, Zip64 sizes, Unix modes and symlinks.

Zip_Entry :: struct {
	name:         string,
	method:       u16, // 0 stored, 8 deflated
	crc:          u32,
	packed_size:  i64,
	size:         i64,
	local_offset: i64,
	mode:         u32, // Unix mode (0 when the archive was made elsewhere)
}

// Reads `n` bytes at `offset` of the archive.
Zip_Reader :: struct {
	size:      i64,
	read_at:   proc(reader: ^Zip_Reader, offset, count: i64) -> []byte,
	path:      string, // a local file
	url:       string, // or a remote one, read with ranged GETs
	fetched:   i64,
	cache:     []byte, // the archive's tail (the central directory), fetched once
	cache_off: i64,
}

// A reader over a local archive: members are read from disk as they are needed, never the whole file at once.
zip_open_file :: proc(path: string) -> Zip_Reader {
	info, err := os.stat(path, context.temp_allocator)
	if err != nil {
		fatal("cannot read %s", path)
	}
	return {
		size = info.size,
		path = path,
		read_at = proc(reader: ^Zip_Reader, offset, count: i64) -> []byte {
			file, err := os.open(reader.path)
			if err != nil {
				fatal("cannot open %s", reader.path)
			}
			defer os.close(file)
			buf := make([]byte, count)
			got, read_err := os.read_at(file, buf, offset)
			if read_err != nil || i64(got) != count {
				fatal("%s: short read at %d", reader.path, offset)
			}
			return buf
		},
	}
}

// A remote archive read in pieces with HTTP range requests (curl -r): pulling a few members out of a large archive
// costs a few requests, not the whole download.
zip_open_url :: proc(url: string) -> Zip_Reader {
	head := must_run({
			cmd     = {curl(), "-sSIL", "--retry", "5", url},
			capture = true,
			quiet   = true,
		}, aprintf("HEAD %s", url))
	size: i64 = -1
	text := head.stdout
	for line in strings.split_lines_iterator(&text) {
		lowered := strings.to_lower(strings.trim_space(line), context.temp_allocator)
		if strings.has_prefix(lowered, "content-length:") {
			size = parse_i64(strings.trim_space(lowered[len("content-length:"):])) // the last one: after redirects
		}
	}
	if size <= 0 {
		fatal("%s: no Content-Length", url)
	}
	return {
		size = size,
		url = url,
		read_at = proc(reader: ^Zip_Reader, offset, count: i64) -> []byte {
			if offset >= reader.cache_off &&
			   offset + count <= reader.cache_off + i64(len(reader.cache)) &&
			   len(reader.cache) > 0 {
				return reader.cache[offset - reader.cache_off:][:count]
			}
			tmp := join(state.project.out, "tmp", aprintf("range-%d", os.get_pid()))
			make_dirs(os.dir(tmp))
			must_run({
					cmd   = {
						curl(),
						"-fsSL",
						"--retry",
						"5",
						"--retry-all-errors",
						"-r",
						aprintf("%d-%d", offset, offset + count - 1),
						"-o",
						tmp,
						reader.url,
					},
					quiet = true,
				}, aprintf("range GET %s", reader.url))
			data, err := os.read_entire_file(tmp, context.allocator)
			os.remove(tmp)
			if err != nil || i64(len(data)) != count {
				fatal("%s: range %d+%d returned %d bytes", reader.url, offset, count, len(data))
			}
			reader.fetched += count
			return data
		},
	}
}

// The archive's members, from its central directory.
zip_entries :: proc(reader: ^Zip_Reader) -> []Zip_Entry {
	tail_len := min(reader.size, 65536 + 22)
	tail := reader.read_at(reader, reader.size - tail_len, tail_len)
	eocd := -1
	for i := len(tail) - 22; i >= 0; i -= 1 {
		if le32(tail, i) == 0x06054b50 {
			eocd = i
			break
		}
	}
	if eocd < 0 {
		fatal("not a zip archive (no end of central directory)")
	}
	count := i64(le16(tail, eocd + 10))
	cd_size := i64(le32(tail, eocd + 12))
	cd_off := i64(le32(tail, eocd + 16))
	if cd_off == 0xFFFFFFFF || count == 0xFFFF || cd_size == 0xFFFFFFFF {
		// Zip64: the locator sits right before the end record and points at the Zip64 end record.
		loc := eocd - 20
		if loc < 0 || le32(tail, loc) != 0x07064b50 {
			fatal("zip64 archive without its locator")
		}
		rec_off := i64(le64(tail, loc + 8))
		rec := reader.read_at(reader, rec_off, 56)
		count = i64(le64(rec, 32))
		cd_size = i64(le64(rec, 40))
		cd_off = i64(le64(rec, 48))
	}
	cd := reader.read_at(reader, cd_off, cd_size)
	reader.cache, reader.cache_off = cd, cd_off
	entries := make([]Zip_Entry, count)
	cursor := 0
	for i in 0 ..< count {
		if le32(cd, cursor) != 0x02014b50 {
			fatal("bad central directory entry %d", i)
		}
		entry := &entries[i]
		made_by := le16(cd, cursor + 4)
		entry.method = le16(cd, cursor + 10)
		entry.crc = le32(cd, cursor + 16)
		entry.packed_size = i64(le32(cd, cursor + 20))
		entry.size = i64(le32(cd, cursor + 24))
		name_len := int(le16(cd, cursor + 28))
		extra_len := int(le16(cd, cursor + 30))
		comment_len := int(le16(cd, cursor + 32))
		external := le32(cd, cursor + 38)
		entry.local_offset = i64(le32(cd, cursor + 42))
		entry.name = strings.clone(string(cd[cursor + 46:][:name_len]))
		if made_by >> 8 == 3 {
			entry.mode = external >> 16 // made on Unix
		}
		// Zip64 extra field: the 0xFFFFFFFF values follow in order.
		extra_pos := cursor + 46 + name_len
		for extra_pos + 4 <= cursor + 46 + name_len + extra_len {
			id, field_len := le16(cd, extra_pos), int(le16(cd, extra_pos + 2))
			if id == 1 {
				value_pos := extra_pos + 4
				if entry.size == 0xFFFFFFFF {
					entry.size = i64(le64(cd, value_pos))
					value_pos += 8
				}
				if entry.packed_size == 0xFFFFFFFF {
					entry.packed_size = i64(le64(cd, value_pos))
					value_pos += 8
				}
				if entry.local_offset == 0xFFFFFFFF {
					entry.local_offset = i64(le64(cd, value_pos))
				}
			}
			extra_pos += 4 + field_len
		}
		cursor += 46 + name_len + extra_len + comment_len
	}
	return entries
}

// One member's content, checked against its CRC.
zip_read :: proc(reader: ^Zip_Reader, entry: Zip_Entry) -> []byte {
	local := reader.read_at(reader, entry.local_offset, 30)
	if le32(local, 0) != 0x04034b50 {
		fatal("%s: bad local header", entry.name)
	}
	start := entry.local_offset + 30 + i64(le16(local, 26)) + i64(le16(local, 28))
	packed := reader.read_at(reader, start, entry.packed_size)
	data: []byte
	switch entry.method {
	case 0:
		data = packed
	case 8:
		out: [dynamic]byte
		if err := deflate.inflate_raw(&out, packed, int(entry.size)); err != nil {
			fatal("%s: inflate failed: %v", entry.name, err)
		}
		data = out[:]
	case:
		fatal("%s: unsupported compression method %d", entry.name, entry.method)
	}
	if i64(len(data)) != entry.size || hash.crc32(data) != entry.crc {
		fatal("%s: corrupt (size or CRC mismatch)", entry.name)
	}
	return data
}

S_IFMT :: 0o170000
S_IFLNK :: 0o120000
S_IFDIR :: 0o040000

// Extracts every member under `dest` (refusing names that would escape it), keeping Unix modes and symlinks (a
// macOS .app has both). `strip_top`: an archive of one top folder, whose contents go straight into `dest`.
zip_extract_all :: proc(reader: ^Zip_Reader, dest: string, strip_top := false) {
	for entry in zip_entries(reader) {
		if strings.has_prefix(entry.name, "/") || strings.contains(entry.name, "..") {
			fatal("unexpected path in the archive: %s", entry.name)
		}
		name := entry.name
		if strip_top {
			slash := strings.index_byte(name, '/')
			if slash < 0 {
				fatal("%s is outside the archive's top folder", entry.name)
			}
			name = name[slash + 1:]
			if name == "" {
				continue
			}
		}
		path := join(dest, name)
		if strings.has_suffix(entry.name, "/") || entry.mode & S_IFMT == S_IFDIR {
			make_dirs(path)
			continue
		}
		data := zip_read(reader, entry)
		make_dirs(os.dir(path))
		if entry.mode & S_IFMT == S_IFLNK {
			os.remove(path)
			if os.symlink(string(data), path) != nil {
				fatal("cannot create the symlink %s", path)
			}
			continue
		}
		if !write_file(path, data) {
			fatal("cannot write %s", path)
		}
		if entry.mode & 0o111 != 0 {
			os.change_mode(path, os.perm_number(int(entry.mode & 0o777)))
		}
		delete(data)
	}
}

// --- writing ----------------------------------------------------------------------------------------------------

Zip_Writer :: struct {
	buf:     [dynamic]byte,
	central: [dynamic]byte,
	count:   int,
}

// Adds a file. Fixed timestamps (1980-01-01) make the archive reproducible: packing the same files gives the same
// bytes.
zip_add :: proc(writer: ^Zip_Writer, name: string, data: []byte, mode: u32 = 0o644) {
	packed: [dynamic]byte
	if err := deflate.deflate_raw(&packed, data, .Level_6); err != nil {
		fatal("deflate failed for %s: %v", name, err)
	}
	crc := hash.crc32(data)
	if len(data) >= 0xFFFFFFFF || len(writer.buf) >= 0xFFFFFFFF {
		fatal("%s: archives over 4 GB are not supported", name)
	}
	if writer.count >= 0xFFFF { 	// the count fields are u16, and 0xFFFF means Zip64 to a reader
		fatal("%s: archives over %d members are not supported", name, 0xFFFF - 1)
	}
	offset := u32(len(writer.buf))
	DOS_DATE :: u16((1980 - 1980) << 9 | 1 << 5 | 1)
	// local header
	put32(&writer.buf, 0x04034b50)
	put16(&writer.buf, 20)
	put16(&writer.buf, 0x0800) // UTF-8 names
	put16(&writer.buf, 8)
	put16(&writer.buf, 0)
	put16(&writer.buf, DOS_DATE)
	put32(&writer.buf, crc)
	put32(&writer.buf, u32(len(packed)))
	put32(&writer.buf, u32(len(data)))
	put16(&writer.buf, u16(len(name)))
	put16(&writer.buf, 0)
	append(&writer.buf, name)
	append(&writer.buf, ..packed[:])
	// central directory entry
	put32(&writer.central, 0x02014b50)
	put16(&writer.central, 3 << 8 | 20) // made on Unix
	put16(&writer.central, 20)
	put16(&writer.central, 0x0800)
	put16(&writer.central, 8)
	put16(&writer.central, 0)
	put16(&writer.central, DOS_DATE)
	put32(&writer.central, crc)
	put32(&writer.central, u32(len(packed)))
	put32(&writer.central, u32(len(data)))
	put16(&writer.central, u16(len(name)))
	put16(&writer.central, 0)
	put16(&writer.central, 0)
	put16(&writer.central, 0)
	put16(&writer.central, 0)
	put32(&writer.central, (0o100000 | mode) << 16)
	put32(&writer.central, offset)
	append(&writer.central, name)
	writer.count += 1
	delete(packed)
}

// Appends the central directory to the members zip_add packed and returns the whole archive, ready for
// write_file.
zip_finish :: proc(writer: ^Zip_Writer) -> []byte {
	if len(writer.buf) >= 0xFFFFFFFF || len(writer.central) >= 0xFFFFFFFF {
		fatal("archives over 4 GB are not supported")
	}
	cd_off := u32(len(writer.buf))
	append(&writer.buf, ..writer.central[:])
	put32(&writer.buf, 0x06054b50)
	put16(&writer.buf, 0)
	put16(&writer.buf, 0)
	put16(&writer.buf, u16(writer.count))
	put16(&writer.buf, u16(writer.count))
	put32(&writer.buf, u32(len(writer.central)))
	put32(&writer.buf, cd_off)
	put16(&writer.buf, 0)
	return writer.buf[:]
}

@(private)
le16 :: proc(bytes: []byte, at: int) -> u16 {
	value, _ := endian.get_u16(bytes[at:], .Little)
	return value
}

@(private)
le32 :: proc(bytes: []byte, at: int) -> u32 {
	value, _ := endian.get_u32(bytes[at:], .Little)
	return value
}

@(private)
le64 :: proc(bytes: []byte, at: int) -> u64 {
	value, _ := endian.get_u64(bytes[at:], .Little)
	return value
}

@(private)
put16 :: proc(bytes: ^[dynamic]byte, value: u16) {
	append(bytes, byte(value), byte(value >> 8))
}

@(private)
put32 :: proc(bytes: ^[dynamic]byte, value: u32) {
	append(bytes, byte(value), byte(value >> 8), byte(value >> 16), byte(value >> 24))
}

// The leading decimal digits of a text as a number (0 when there are none), ignoring what follows: reads sizes
// such as an HTTP Content-Length.
parse_i64 :: proc(text: string) -> i64 {
	number: i64
	for character in text {
		if character < '0' || character > '9' {
			break
		}
		number = number * 10 + i64(character - '0')
	}
	return number
}
