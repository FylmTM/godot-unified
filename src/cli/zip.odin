package cli

import "core:compress/deflate"
import "core:encoding/endian"
import "core:hash"
import "core:os"
import "core:strings"

// Zip archives (SPEC.md, Dependencies): reading the Godot editor, export templates (straight from the 1.3 GB
// archive over HTTP byte ranges) and the EOS SDK parts, writing the EOS SDK parts and Windows release zips. Stored
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
	read_at:   proc(r: ^Zip_Reader, offset, n: i64) -> []byte,
	path:      string, // a local file
	url:       string, // or a remote one, read with ranged GETs
	fetched:   i64,
	cache:     []byte, // the archive's tail (the central directory), fetched once
	cache_off: i64,
}

zip_open_file :: proc(path: string) -> Zip_Reader {
	fi, err := os.stat(path, context.temp_allocator)
	if err != nil {
		fatal("cannot read %s", path)
	}
	return {size = fi.size, path = path, read_at = proc(r: ^Zip_Reader, offset, n: i64) -> []byte {
			f, err := os.open(r.path)
			if err != nil {
				fatal("cannot open %s", r.path)
			}
			defer os.close(f)
			buf := make([]byte, n)
			got, rerr := os.read_at(f, buf, offset)
			if rerr != nil || i64(got) != n {
				fatal("%s: short read at %d", r.path, offset)
			}
			return buf
		}}
}

// A remote archive read in pieces with HTTP range requests (curl -r): pulling a few members out of a large archive
// costs a few requests, not the whole download.
zip_open_url :: proc(url: string) -> Zip_Reader {
	head := must_run(
		{cmd = {curl(), "-sSIL", "--retry", "5", url}, capture = true, quiet = true},
		tprint("HEAD %s", url),
	)
	size: i64 = -1
	text := head.stdout
	for line in strings.split_lines_iterator(&text) {
		l := strings.to_lower(strings.trim_space(line), context.temp_allocator)
		if strings.has_prefix(l, "content-length:") {
			size = parse_i64(strings.trim_space(l[len("content-length:"):])) // the last one: after redirects
		}
	}
	if size <= 0 {
		fatal("%s: no Content-Length", url)
	}
	return {size = size, url = url, read_at = proc(r: ^Zip_Reader, offset, n: i64) -> []byte {
			if offset >= r.cache_off && offset + n <= r.cache_off + i64(len(r.cache)) && len(r.cache) > 0 {
				return r.cache[offset - r.cache_off:][:n]
			}
			tmp := join(state.project.out, "tmp", tprint("range-%d", os.get_pid()))
			make_dirs(os.dir(tmp))
			must_run(
				{
					cmd = {
						curl(),
						"-fsSL",
						"--retry",
						"5",
						"--retry-all-errors",
						"-r",
						tprint("%d-%d", offset, offset + n - 1),
						"-o",
						tmp,
						r.url,
					},
					quiet = true,
				},
				tprint("range GET %s", r.url),
			)
			data, err := os.read_entire_file(tmp, context.allocator)
			os.remove(tmp)
			if err != nil || i64(len(data)) != n {
				fatal("%s: range %d+%d returned %d bytes", r.url, offset, n, len(data))
			}
			r.fetched += n
			return data
		}}
}

// The archive's members, from its central directory.
zip_entries :: proc(r: ^Zip_Reader) -> []Zip_Entry {
	tail_len := min(r.size, 65536 + 22)
	tail := r.read_at(r, r.size - tail_len, tail_len)
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
		rec := r.read_at(r, rec_off, 56)
		count = i64(le64(rec, 32))
		cd_size = i64(le64(rec, 40))
		cd_off = i64(le64(rec, 48))
	}
	cd := r.read_at(r, cd_off, cd_size)
	r.cache, r.cache_off = cd, cd_off
	entries := make([]Zip_Entry, count)
	p := 0
	for i in 0 ..< count {
		if le32(cd, p) != 0x02014b50 {
			fatal("bad central directory entry %d", i)
		}
		e := &entries[i]
		made_by := le16(cd, p + 4)
		e.method = le16(cd, p + 10)
		e.crc = le32(cd, p + 16)
		e.packed_size = i64(le32(cd, p + 20))
		e.size = i64(le32(cd, p + 24))
		name_len := int(le16(cd, p + 28))
		extra_len := int(le16(cd, p + 30))
		comment_len := int(le16(cd, p + 32))
		external := le32(cd, p + 38)
		e.local_offset = i64(le32(cd, p + 42))
		e.name = strings.clone(string(cd[p + 46:][:name_len]))
		if made_by >> 8 == 3 {
			e.mode = external >> 16 // made on Unix
		}
		// Zip64 extra field: the 0xFFFFFFFF values follow in order.
		x := p + 46 + name_len
		for x + 4 <= p + 46 + name_len + extra_len {
			id, n := le16(cd, x), int(le16(cd, x + 2))
			if id == 1 {
				q := x + 4
				if e.size == 0xFFFFFFFF {
					e.size = i64(le64(cd, q))
					q += 8
				}
				if e.packed_size == 0xFFFFFFFF {
					e.packed_size = i64(le64(cd, q))
					q += 8
				}
				if e.local_offset == 0xFFFFFFFF {
					e.local_offset = i64(le64(cd, q))
				}
			}
			x += 4 + n
		}
		p += 46 + name_len + extra_len + comment_len
	}
	return entries
}

// One member's content, checked against its CRC.
zip_read :: proc(r: ^Zip_Reader, e: Zip_Entry) -> []byte {
	local := r.read_at(r, e.local_offset, 30)
	if le32(local, 0) != 0x04034b50 {
		fatal("%s: bad local header", e.name)
	}
	start := e.local_offset + 30 + i64(le16(local, 26)) + i64(le16(local, 28))
	packed := r.read_at(r, start, e.packed_size)
	data: []byte
	switch e.method {
	case 0:
		data = packed
	case 8:
		out: [dynamic]byte
		if err := deflate.inflate_raw(&out, packed, int(e.size)); err != nil {
			fatal("%s: inflate failed: %v", e.name, err)
		}
		data = out[:]
	case:
		fatal("%s: unsupported compression method %d", e.name, e.method)
	}
	if i64(len(data)) != e.size || hash.crc32(data) != e.crc {
		fatal("%s: corrupt (size or CRC mismatch)", e.name)
	}
	return data
}

S_IFMT :: 0o170000
S_IFLNK :: 0o120000
S_IFDIR :: 0o040000

// Extracts every member under `dest` (refusing names that would escape it), keeping Unix modes and symlinks (a
// macOS .app has both).
zip_extract_all :: proc(r: ^Zip_Reader, dest: string) {
	for e in zip_entries(r) {
		if strings.has_prefix(e.name, "/") || strings.contains(e.name, "..") {
			fatal("unexpected path in the archive: %s", e.name)
		}
		path := join(dest, e.name)
		if strings.has_suffix(e.name, "/") || e.mode & S_IFMT == S_IFDIR {
			make_dirs(path)
			continue
		}
		data := zip_read(r, e)
		make_dirs(os.dir(path))
		if e.mode & S_IFMT == S_IFLNK {
			os.remove(path)
			if os.symlink(string(data), path) != nil {
				fatal("cannot create the symlink %s", path)
			}
			continue
		}
		if !write_file(path, data) {
			fatal("cannot write %s", path)
		}
		if e.mode & 0o111 != 0 {
			os.change_mode(path, os.perm_number(int(e.mode & 0o777)))
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
zip_add :: proc(w: ^Zip_Writer, name: string, data: []byte, mode: u32 = 0o644) {
	packed: [dynamic]byte
	if err := deflate.deflate_raw(&packed, data, .Level_6); err != nil {
		fatal("deflate failed for %s: %v", name, err)
	}
	crc := hash.crc32(data)
	if len(data) >= 0xFFFFFFFF || len(w.buf) >= 0xFFFFFFFF {
		fatal("%s: archives over 4 GB are not supported", name)
	}
	offset := u32(len(w.buf))
	DOS_DATE :: u16((1980 - 1980) << 9 | 1 << 5 | 1)
	// local header
	put32(&w.buf, 0x04034b50)
	put16(&w.buf, 20)
	put16(&w.buf, 0x0800) // UTF-8 names
	put16(&w.buf, 8)
	put16(&w.buf, 0)
	put16(&w.buf, DOS_DATE)
	put32(&w.buf, crc)
	put32(&w.buf, u32(len(packed)))
	put32(&w.buf, u32(len(data)))
	put16(&w.buf, u16(len(name)))
	put16(&w.buf, 0)
	append(&w.buf, name)
	append(&w.buf, ..packed[:])
	// central directory entry
	put32(&w.central, 0x02014b50)
	put16(&w.central, 3 << 8 | 20) // made on Unix
	put16(&w.central, 20)
	put16(&w.central, 0x0800)
	put16(&w.central, 8)
	put16(&w.central, 0)
	put16(&w.central, DOS_DATE)
	put32(&w.central, crc)
	put32(&w.central, u32(len(packed)))
	put32(&w.central, u32(len(data)))
	put16(&w.central, u16(len(name)))
	put16(&w.central, 0)
	put16(&w.central, 0)
	put16(&w.central, 0)
	put16(&w.central, 0)
	put32(&w.central, (0o100000 | mode) << 16)
	put32(&w.central, offset)
	append(&w.central, name)
	w.count += 1
	delete(packed)
}

zip_finish :: proc(w: ^Zip_Writer) -> []byte {
	cd_off := u32(len(w.buf))
	append(&w.buf, ..w.central[:])
	put32(&w.buf, 0x06054b50)
	put16(&w.buf, 0)
	put16(&w.buf, 0)
	put16(&w.buf, u16(w.count))
	put16(&w.buf, u16(w.count))
	put32(&w.buf, u32(len(w.central)))
	put32(&w.buf, cd_off)
	put16(&w.buf, 0)
	return w.buf[:]
}

@(private)
le16 :: proc(b: []byte, at: int) -> u16 {
	v, _ := endian.get_u16(b[at:], .Little)
	return v
}

@(private)
le32 :: proc(b: []byte, at: int) -> u32 {
	v, _ := endian.get_u32(b[at:], .Little)
	return v
}

@(private)
le64 :: proc(b: []byte, at: int) -> u64 {
	v, _ := endian.get_u64(b[at:], .Little)
	return v
}

@(private)
put16 :: proc(b: ^[dynamic]byte, v: u16) {
	append(b, byte(v), byte(v >> 8))
}

@(private)
put32 :: proc(b: ^[dynamic]byte, v: u32) {
	append(b, byte(v), byte(v >> 8), byte(v >> 16), byte(v >> 24))
}

parse_i64 :: proc(s: string) -> i64 {
	n: i64
	for c in s {
		if c < '0' || c > '9' {
			break
		}
		n = n * 10 + i64(c - '0')
	}
	return n
}
