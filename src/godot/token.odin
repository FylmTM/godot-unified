// The LAN token: what the relay knows a player by when they come back to a LAN session (netcode.Token).
package godot

import "core:crypto"
import "core:fmt"
import "core:os"
import "core:strings"
import gd "unified:gdext"
import "unified:netcode"

TOKEN_INSTANCES :: 8 // copies of the game on one machine with tokens of their own

// A claimed token slot: its lock file, held open until token_release or the process ends.
Token_Lock :: distinct uintptr

@(private)
lan: struct {
	claimed: bool,
	token:   netcode.Token,
	lock:    Token_Lock,
}

// This process's LAN token, claimed in user:// on its first session and kept for all the others.
@(private)
client_token :: proc() -> netcode.Token {
	if !lan.claimed {
		lan.claimed = true
		lan.token, lan.lock, _ = token_claim(gd.OS_get_user_data_dir(gd.OS_singleton()))
	}
	return lan.token
}

// Claims a LAN token in `dir`: 16 random bytes kept as hex (netcode.token_text) in `unified_token_<slot>`, made on
// first use. Each running copy of the game on a machine (they share the directory) is someone else: it takes the
// first slot whose `unified_token_<slot>.lock` it can lock. The lock is an OS file lock, held until token_release or
// the process ends (a crash included), so a game restarted after a crash takes its own token back, while a second
// window takes another. With every slot held (or the directory unwritable) the token is fresh and kept nowhere:
// slot -1, lock 0.
token_claim :: proc(dir: string) -> (token: netcode.Token, lock: Token_Lock, slot: int) {
	for k in 0 ..< TOKEN_INSTANCES {
		path := fmt.tprintf("%s/unified_token_%d", dir, k)
		held, ok := lock_file(fmt.tprintf("%s.lock", path))
		if !ok do continue
		if text, err := os.read_entire_file(path, context.temp_allocator); err == nil {
			if kept, kept_ok := netcode.token_parse(strings.trim_space(string(text))); kept_ok {
				return kept, held, k
			}
		}
		crypto.rand_bytes(token[:])
		_ = os.write_entire_file(path, netcode.token_text(token))
		return token, held, k
	}
	crypto.rand_bytes(token[:])
	return token, 0, -1
}

// Lets go of a claimed slot (token_claim); the process's end does the same.
token_release :: proc(lock: Token_Lock) {
	if lock != 0 do unlock_file(lock)
}
