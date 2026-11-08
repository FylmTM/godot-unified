// macOS: the SDK's HTTP layer completes requests through the main thread's run loop. Godot runs one;
// a plain CLI does not, so the thread that ticks EOS from main() pumps it.
package eos

import CF "core:sys/darwin/CoreFoundation"

foreign import pthread "system:System"

@(default_calling_convention = "c")
foreign pthread {
	pthread_main_np :: proc() -> i32 ---
}

pump_main_run_loop :: proc() {
	if pthread_main_np() != 0 {
		CF.RunLoopRunInMode(CF.kRunLoopDefaultMode, 0, true)
	}
}

foreign import security "system:Security.framework"

@(default_calling_convention = "c")
foreign security {
	SecKeychainSetUserInteractionAllowed :: proc(allowed: b8) -> i32 ---
}

// Headless tools: make keychain lookups fail instead of waiting for a dialog. EOS keeps the device
// ID in the login keychain with an access list naming the binary that created it; a rebuilt CLI
// (new ad-hoc signature) would otherwise block in SecItemCopyMatching until someone clicks Allow.
disable_keychain_prompts :: proc() {
	SecKeychainSetUserInteractionAllowed(false)
}
