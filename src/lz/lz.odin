// LZ compression: the decoded size u32, then sequences. A sequence is a token byte (its high nibble the literal count,
// its low nibble the match length less MIN_MATCH; 15 in either: more follows, bytes of 255 and one below it, added),
// the literal bytes, the match offset u16 (1 ..< 65536 bytes back in the output) and the match. The last sequence has
// literals only and a low nibble of 0; the stream ends with it. All little-endian, integer-only, so the same input
// encodes to the same bytes on every platform.
package lz

// Bytes before the first sequence: the decoded size.
HEADER :: 4
// The shortest match a sequence copies: shorter repeats cost more as a match than as literals.
MIN_MATCH :: 4
// The farthest back a match reaches, in output bytes (its offset is a u16).
MAX_OFFSET :: 65535
// The most output one input byte can stand for (a length byte of 255): decoded_size refuses a header claiming more.
MAX_RATIO :: 255

@(private)
HASH_BITS :: 13
@(private)
WAYS :: 2
// Per hash of 4 bytes, the positions after the last WAYS seen there, newest first (0: none): 64 KiB, on the stack.
@(private)
Table :: [1 << HASH_BITS][WAYS]u32
@(private)
GOOD_MATCH :: 64 // a match this long is taken without looking further
@(private)
SKIP_SHIFT :: 5 // after 32 positions without a match the search steps 2 bytes at a time, then 3, ...

// The most bytes `size` input bytes encode to: encode never writes past it.
bound :: proc(size: int) -> int {
	return HEADER + size + size / 255 + 16
}

// Encodes `src` into `out`, replacing what it held and keeping its capacity: a buffer encoded into again and again
// allocates only when an input outgrows the last one's bound. Returns out's bytes. Deterministic: the bytes depend on
// `src` alone. Asserts that `src` is shorter than 4 GiB.
encode :: proc(src: []u8, out: ^[dynamic]u8) -> []u8 {
	assert(u64(len(src)) <= u64(max(u32)), "lz: input of 4 GiB or more")
	non_zero_resize(out, bound(len(src)))
	dst := out[:]
	write_u32(dst, 0, u32(len(src)))
	pos := HEADER
	table: Table
	anchor := 0 // the first input byte no sequence holds yet
	i := 0
	misses := 0
	for i + MIN_MATCH <= len(src) {
		length, offset := find(&table, src, i)
		if length == 0 {
			misses += 1
			i += 1 + misses >> SKIP_SHIFT
			continue
		}
		misses = 0
		// Lazy: a longer match from the next byte on is worth a literal.
		for length < GOOD_MATCH && i + 1 + MIN_MATCH <= len(src) {
			next_length, next_offset := find(&table, src, i + 1)
			if next_length <= length do break
			i += 1
			length, offset = next_length, next_offset
		}
		for i > anchor && i - offset > 0 && src[i - 1] == src[i - offset - 1] {
			i -= 1
			length += 1
		}
		pos = write_sequence(dst, pos, src[anchor:i], offset, length)
		i += length
		anchor = i
		// The match's last two positions: where the next repeat often starts from. Every position inside it would
		// push out older ones that match better.
		for at in i - 2 ..< i {
			if at + MIN_MATCH <= len(src) do push(&table[hash(read_u32(src, at))], at)
		}
	}
	pos = write_sequence(dst, pos, src[anchor:], 0, 0)
	non_zero_resize(out, pos)
	return out[:]
}

// The longest match for the bytes at `i` among its bucket's earlier positions (length 0: none); then `i` goes into the
// bucket.
@(private)
find :: proc(table: ^Table, src: []u8, i: int) -> (length, offset: int) {
	value := read_u32(src, i)
	bucket := &table[hash(value)]
	for way in bucket {
		candidate := int(way) - 1
		if candidate < 0 || i - candidate > MAX_OFFSET || read_u32(src, candidate) != value {
			continue
		}
		if length > 0 && (i + length >= len(src) || src[candidate + length] != src[i + length]) {
			continue // it can't be longer than the best so far
		}
		candidate_length := MIN_MATCH + match_length(src, candidate + MIN_MATCH, i + MIN_MATCH)
		if candidate_length > length {
			length, offset = candidate_length, i - candidate
			if length >= GOOD_MATCH do break
		}
	}
	push(bucket, i)
	return
}

@(private)
push :: #force_inline proc(bucket: ^[WAYS]u32, i: int) {
	for k := WAYS - 1; k > 0; k -= 1 do bucket[k] = bucket[k - 1]
	bucket[0] = u32(i + 1)
}

// The size `data` decodes to, from its header. ok = false when it has no header and last token, or its header claims
// more than its bytes can stand for (MAX_RATIO): a caller can size a buffer from it without a hostile header making
// it allocate more than the data could fill.
decoded_size :: proc(data: []u8) -> (size: int, ok: bool) {
	if len(data) < HEADER + 1 {
		return 0, false
	}
	size = int(read_u32(data, 0))
	if size > MAX_RATIO * (len(data) - HEADER) {
		return 0, false
	}
	return size, true
}

// Decodes `data` into `dst`, which must be exactly decoded_size(data) bytes long. False when `data` is malformed: cut
// short, trailing bytes, a length past the output, an offset before its start. Never reads outside `data` nor writes
// outside `dst`; on false, `dst` holds whatever was decoded before the fault.
decode :: proc(data: []u8, dst: []u8) -> bool {
	size, size_ok := decoded_size(data)
	if !size_ok || size != len(dst) {
		return false
	}
	pos := HEADER
	out := 0
	for pos < len(data) {
		token := data[pos]
		pos += 1
		literals, literals_ok := read_length(data, &pos, int(token >> 4))
		if !literals_ok || literals > len(data) - pos || literals > len(dst) - out {
			return false
		}
		copy(dst[out:out + literals], data[pos:pos + literals])
		pos += literals
		out += literals
		if pos == len(data) {
			return token & 15 == 0 && out == len(dst) // the last sequence: literals only
		}
		if len(data) - pos < 2 {
			return false
		}
		offset := int(data[pos]) | int(data[pos + 1]) << 8
		pos += 2
		length, length_ok := read_length(data, &pos, int(token & 15))
		length += MIN_MATCH
		if !length_ok || offset == 0 || offset > out || length > len(dst) - out {
			return false
		}
		from := out - offset
		if offset >= length {
			copy(dst[out:out + length], dst[from:from + length])
		} else {
			for k in 0 ..< length do dst[out + k] = dst[from + k] // overlapping: a run repeats its last `offset` bytes
		}
		out += length
	}
	return false // no last sequence
}

@(private)
hash :: #force_inline proc(value: u32) -> u32 {
	return (value * 2654435761) >> (32 - HASH_BITS)
}

@(private)
read_u32 :: #force_inline proc(bytes: []u8, at: int) -> u32 {
	return u32(transmute(u32le)(^[4]u8)(raw_data(bytes[at:][:4]))^)
}

@(private)
read_u64 :: #force_inline proc(bytes: []u8, at: int) -> u64 {
	return u64(transmute(u64le)(^[8]u8)(raw_data(bytes[at:][:8]))^)
}

@(private)
write_u32 :: proc(bytes: []u8, at: int, value: u32) {
	(^[4]u8)(raw_data(bytes[at:][:4]))^ = transmute([4]u8)u32le(value)
}

// How many bytes from `ahead` on repeat those from `behind` on (behind < ahead), up to the end of `src`.
@(private)
match_length :: proc(src: []u8, behind, ahead: int) -> int {
	length := 0
	for ahead + length + 8 <= len(src) && read_u64(src, behind + length) == read_u64(src, ahead + length) {
		length += 8
	}
	for ahead + length < len(src) && src[behind + length] == src[ahead + length] {
		length += 1
	}
	return length
}

// One sequence at `pos`: `literals`, then a match of `length` bytes `offset` back (length 0: the last sequence).
// Returns the position after it.
@(private)
write_sequence :: proc(dst: []u8, pos: int, literals: []u8, offset, length: int) -> int {
	pos := pos
	match_rest := length > 0 ? length - MIN_MATCH : 0
	dst[pos] = nibble(len(literals)) << 4 | nibble(match_rest)
	pos = write_length(dst, pos + 1, len(literals))
	copy(dst[pos:pos + len(literals)], literals)
	pos += len(literals)
	if length > 0 {
		dst[pos] = u8(offset)
		dst[pos + 1] = u8(offset >> 8)
		pos = write_length(dst, pos + 2, match_rest)
	}
	return pos
}

// A length's token nibble: itself up to 14, else 15 (more follows).
@(private)
nibble :: #force_inline proc(length: int) -> u8 {
	return length < 15 ? u8(length) : 15
}

// The bytes of a length past its token's nibble (15 or more): 255 while more remains, then the rest.
@(private)
write_length :: proc(dst: []u8, pos: int, length: int) -> int {
	if length < 15 {
		return pos
	}
	pos := pos
	rest := length - 15
	for rest >= 255 {
		dst[pos] = 255
		pos += 1
		rest -= 255
	}
	dst[pos] = u8(rest)
	return pos + 1
}

// A token nibble's length: `nibble`, or at 15 the bytes after it added. False when they run past `data`.
@(private)
read_length :: proc(data: []u8, pos: ^int, nibble: int) -> (length: int, ok: bool) {
	length = nibble
	if nibble < 15 {
		return length, true
	}
	for pos^ < len(data) {
		value := data[pos^]
		pos^ += 1
		length += int(value)
		if value != 255 {
			return length, true
		}
	}
	return 0, false
}
