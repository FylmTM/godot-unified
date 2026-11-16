#+build !windows
#+build !darwin
#+build !linux
package cli

// Not read on this OS: --screen takes Godot's index here.
os_screens :: proc() -> []Screen {
	return nil
}
