// Thread classes on Linux: plain sleeps (to be measured), nothing asked of the system for a session.
#+private
package godot

set_realtime_thread :: proc(tick_hz: int) {}

session_power_begin :: proc() {}

session_power_end :: proc() {}
