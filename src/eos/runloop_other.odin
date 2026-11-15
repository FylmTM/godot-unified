#+build !darwin
package eos

// Nothing to pump off macOS: the SDK's HTTP layer needs no run loop there.
pump_main_run_loop :: proc() {}

// Nothing to disable off macOS: there is no keychain dialog to block on.
disable_keychain_prompts :: proc() {}
