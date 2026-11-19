#+build !windows
package cli

// Elsewhere a program gets its arguments as the shell split them, quotes kept: nothing to recover.
@(private)
raw_command_line :: proc() -> string {return ""}
