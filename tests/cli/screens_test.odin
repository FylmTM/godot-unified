// The OS's screen lists behind `--screen left|right|primary` (src/cli/godot.odin, screens_*.odin).
package test_cli

import "core:testing"
import "unified:cli"

// `--screen left|right|primary` on Linux reads `xrandr --listmonitors`.
@(test)
xrandr_monitors_in_order :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	screens := cli.parse_xrandr_monitors(
		"Monitors: 3\n 0: +*DP-1 2560/597x1440/336+0+0  DP-1\n 1: +HDMI-1 1920/527x1080/296+2560+180  HDMI-1\n 2: +eDP-1 1280/290x800/180+-1280+0  eDP-1\n",
	)
	testing.expect_value(t, len(screens), 3)
	if len(screens) == 3 {
		testing.expect_value(t, screens[0], cli.Screen{0, 2560, true})
		testing.expect_value(t, screens[1], cli.Screen{2560, 4480, false})
		testing.expect_value(t, screens[2], cli.Screen{-1280, 0, false})
	}
	testing.expect_value(t, len(cli.parse_xrandr_monitors("")), 0)
	testing.expect_value(t, len(cli.parse_xrandr_monitors("Can't open display\n")), 0)
}

// The OS's screen list (Windows: the monitors; macOS: CoreGraphics' displays, the menu bar's first, as Godot numbers
// them): at least one where a desktop runs (developers' machines, CI's Windows and macOS runners), exactly one
// primary, each with a width. Linux reads xrandr, absent on CI's runners: checked only when it lists any.
@(test)
os_screens_have_one_primary :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	screens := cli.os_screens()
	when ODIN_OS == .Windows || ODIN_OS == .Darwin {
		testing.expect(t, len(screens) > 0, "no screens read")
	}
	primaries := 0
	for screen in screens {
		primaries += screen.primary ? 1 : 0
		testing.expectf(t, screen.left < screen.right, "a screen without a width: %v", screen)
	}
	if len(screens) > 0 {
		testing.expect_value(t, primaries, 1)
	}
	when ODIN_OS == .Darwin {
		if len(screens) > 0 {
			testing.expect(t, screens[0].primary, "Godot's screen 0 on macOS is the main display")
		}
	}
}

// `uni tool --window --size WxH`: the size's text (UnifiedTool places the window: tests/godot_views' tool check).
@(test)
a_window_size_reads_as_width_by_height :: proc(t: ^testing.T) {
	testing.expect_value(t, cli.parse_window_size("2560x1440"), [2]int{2560, 1440})
}
