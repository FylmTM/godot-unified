#+build !darwin
package cli

// Only macOS needs a focus guard (focus_darwin.odin): on Windows the no-focus window opens without activation
// (`with_window`).
start_focus_guard :: proc() {}

// Nothing to stop where no guard runs.
stop_focus_guard :: proc() {}
