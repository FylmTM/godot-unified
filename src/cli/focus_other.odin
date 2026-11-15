#+build !darwin
package cli

// Only macOS needs a guard: on Windows the no-focus window opens without activation (`with_window`).
start_focus_guard :: proc() {}

stop_focus_guard :: proc() {}
