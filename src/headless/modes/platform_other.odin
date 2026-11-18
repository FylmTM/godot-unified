#+build !windows
package modes

// Nothing to set up off Windows: sleeps there are already fine-grained enough for the 1 ms loops.
@(private)
platform_init :: proc() {}
