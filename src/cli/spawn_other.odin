#+build !darwin
#+private
package cli

import "core:os"

// Starts a process (spawn): core:os's own, everywhere but macOS (spawn_darwin.odin).
start_process :: proc(desc: os.Process_Desc) -> (os.Process, os.Error) {
	return os.process_start(desc)
}
