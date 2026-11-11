#+build !windows
package cli

// Not read on macOS and Linux yet: --screen takes Godot's index there.
@(private)
os_screens :: proc() -> []Screen {
	return nil
}
