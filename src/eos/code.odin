// Lobby codes: 6 characters from an alphabet without look-alikes (no 0/O, 1/I/L), so a code can be
// read out loud or typed from a screenshot. 31^6 ≈ 8.9e8 codes; collisions only matter between
// lobbies open at the same time in the same bucket.
package eos

import "core:crypto"

CODE_LEN :: 6
CODE_ALPHABET :: "23456789ABCDEFGHJKMNPQRSTUVWXYZ"

Code :: [CODE_LEN]u8

// A fresh random code. `random` fills a buffer with random bytes (crypto by default; tests pass a
// seeded one). Unbiased: bytes >= 248 (= 31 * 8) are rejected.
code_new :: proc(random: proc(buf: []u8) = crypto.rand_bytes) -> (code: Code) {
	N :: len(CODE_ALPHABET)
	LIMIT :: 256 - 256 % N
	alphabet := CODE_ALPHABET
	buf: [16]u8
	i := 0
	for i < CODE_LEN {
		random(buf[:])
		for random_byte in buf {
			if int(random_byte) >= LIMIT {
				continue
			}
			code[i] = alphabet[int(random_byte) % N]
			i += 1
			if i == CODE_LEN {
				break
			}
		}
	}
	return
}

// Parses what a player typed: case-insensitive, spaces and dashes ignored, and the look-alikes the
// alphabet leaves out are read as what they resemble only when that is unambiguous (O -> 0 is not,
// as 0 isn't in the alphabet either), so they are rejected.
code_parse :: proc(text: string) -> (code: Code, ok: bool) {
	count := 0
	for i in 0 ..< len(text) {
		char := text[i]
		switch char {
		case ' ', '-', '\t':
			continue
		case 'a' ..= 'z':
			char -= 'a' - 'A'
		}
		if !code_char_ok(char) || count == CODE_LEN {
			return {}, false
		}
		code[count] = char
		count += 1
	}
	return code, count == CODE_LEN
}

// Whether an (uppercase) character is in the code alphabet; code_parse checks each typed character with it.
@(private)
code_char_ok :: proc(char: u8) -> bool {
	for letter in transmute([]u8)string(CODE_ALPHABET) {
		if letter == char {
			return true
		}
	}
	return false
}
