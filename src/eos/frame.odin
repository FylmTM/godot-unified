// Datagram framing over EOS P2P. An EOS packet carries at most 1170 bytes; netcode.MAX_DATAGRAM
// fits in one, but the link doesn't rely on it: larger datagrams are split:
//
//   whole    = u8 0, bytes                                  (<= 1169 bytes of payload)
//   fragment = u8 1, u16 id, u8 index, u8 count, bytes      (<= 1165 bytes per part)
//
// A datagram is delivered once all its parts arrived; losing any part loses the datagram, which the
// channel above treats like any other loss. Pure code, no EOS calls: tested without the network.
package eos

P2P_MAX_PACKET :: 1170
FRAME_WHOLE :: 0
FRAME_PART :: 1
PART_HEADER :: 5
PART_MAX :: P2P_MAX_PACKET - PART_HEADER
MAX_PARTS :: 4 // datagrams up to 4 * PART_MAX = 4660 bytes
REASM_SLOTS :: 4

// Splits `bytes` into EOS packets; calls `emit` for each. `next_id` numbers fragmented datagrams. A
// datagram of more than MAX_PARTS parts (the receiver could never reassemble it) is not sent: false.
frame_split :: proc(bytes: []u8, next_id: ^u16, emit: proc(user: rawptr, pkt: []u8), user: rawptr) -> bool {
	buf: [P2P_MAX_PACKET]u8
	if len(bytes) + 1 <= P2P_MAX_PACKET {
		buf[0] = FRAME_WHOLE
		copy(buf[1:], bytes)
		emit(user, buf[:1 + len(bytes)])
		return true
	}
	count := (len(bytes) + PART_MAX - 1) / PART_MAX
	if count > MAX_PARTS {
		return false
	}
	id := next_id^
	next_id^ += 1
	for i in 0 ..< count {
		part := bytes[i * PART_MAX:min((i + 1) * PART_MAX, len(bytes))]
		buf[0] = FRAME_PART
		buf[1] = u8(id)
		buf[2] = u8(id >> 8)
		buf[3] = u8(i)
		buf[4] = u8(count)
		copy(buf[PART_HEADER:], part)
		emit(user, buf[:PART_HEADER + len(part)])
	}
	return true
}

Reasm_Slot :: struct {
	used:  bool,
	id:    u16,
	count: u8,
	have:  u8, // bitmask of parts received
	age:   u32,
	lens:  [MAX_PARTS]u16,
	data:  [MAX_PARTS * PART_MAX]u8,
}

// Per-peer reassembly state; a few datagrams may be in flight at once (packets are unordered).
Reasm :: struct {
	slots: [REASM_SLOTS]Reasm_Slot,
	clock: u32,
}

// Feeds one EOS packet. Returns the complete datagram (copied into `out`) when this packet
// finished one, or ok = false. Malformed packets are dropped.
frame_join :: proc(r: ^Reasm, pkt: []u8, out: []u8) -> (n: int, ok: bool) {
	if len(pkt) < 1 {
		return
	}
	switch pkt[0] {
	case FRAME_WHOLE:
		if len(pkt) - 1 > len(out) {
			return
		}
		return copy(out, pkt[1:]), true
	case FRAME_PART:
		if len(pkt) < PART_HEADER {
			return
		}
		id := u16(pkt[1]) | u16(pkt[2]) << 8
		index := int(pkt[3])
		count := int(pkt[4])
		part := pkt[PART_HEADER:]
		if count < 2 || count > MAX_PARTS || index >= count || len(part) > PART_MAX {
			return
		}
		// Every part but the last is full size.
		if index < count - 1 && len(part) != PART_MAX {
			return
		}
		r.clock += 1
		s: ^Reasm_Slot
		for &x in r.slots {
			if x.used && x.id == id {
				s = &x
				break
			}
		}
		if s == nil {
			// Take a free slot or evict the oldest.
			s = &r.slots[0]
			for &x in r.slots {
				if !x.used {
					s = &x
					break
				}
				if x.age < s.age {
					s = &x
				}
			}
			s^ = Reasm_Slot {
				used  = true,
				id    = id,
				count = u8(count),
			}
		}
		if int(s.count) != count {
			s.used = false
			return
		}
		s.age = r.clock
		s.lens[index] = u16(len(part))
		copy(s.data[index * PART_MAX:], part)
		s.have |= 1 << u8(index)
		if s.have != u8((1 << uint(count)) - 1) {
			return
		}
		s.used = false
		total := (count - 1) * PART_MAX + int(s.lens[count - 1])
		if total > len(out) {
			return
		}
		return copy(out, s.data[:total]), true
	}
	return
}
