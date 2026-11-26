#+build !windows
#+build !linux
package cli

import "core:os"

// Nothing to close here: os.process_open holds no handle on this OS.
@(private)
process_handle_close :: proc(process: os.Process) {}
