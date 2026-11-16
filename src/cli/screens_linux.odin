package cli

// The monitors in Godot's screen order on Linux under X11 (and XWayland), XRandR's: what `xrandr --listmonitors`
// lists (the same XRRGetMonitors call Godot's X11 display server makes). Run only when --screen names a side; none
// without xrandr or a display (then --screen takes Godot's index).
os_screens :: proc() -> []Screen {
	xrandr := which("xrandr")
	if xrandr == "" {
		return nil
	}
	ran := run_proc({cmd = strs(xrandr, "--listmonitors"), capture = true, quiet = true, timeout = XRANDR_TIMEOUT})
	if !ran.ok {
		return nil
	}
	return parse_xrandr_monitors(ran.stdout)
}
