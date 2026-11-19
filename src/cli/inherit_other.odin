#+build !windows
package cli

import "core:os"

// Elsewhere a child gets only the descriptors process_start duplicates onto its stdio (the rest are close-on-exec).
@(private)
set_inheritable :: proc(file: ^os.File, inheritable: bool) {}
