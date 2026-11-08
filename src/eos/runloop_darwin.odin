// macOS specifics. The SDK's HTTP layer completes requests through the main thread's run loop
// (Godot runs one; a plain CLI does not, so the thread that ticks EOS from main() pumps it). The SDK
// keeps the device-ID token in the login keychain (generic password, service KEYCHAIN_SERVICE,
// account = product ID), owned by the binary that created it: another build (a new ad-hoc
// signature) must be allowed by the user, through a dialog, to read or delete it.
package eos

import CF "core:sys/darwin/CoreFoundation"

foreign import system "system:System"
foreign import security "system:Security.framework"

@(default_calling_convention = "c")
foreign system {
	pthread_main_np :: proc() -> i32 ---
}

@(default_calling_convention = "c")
foreign security {
	SecKeychainSetUserInteractionAllowed :: proc(allowed: b8) -> i32 ---
}

KEYCHAIN_SERVICE :: "com.epicgames.sdk.connect.access_token"

pump_main_run_loop :: proc() {
	if pthread_main_np() != 0 {
		CF.RunLoopRunInMode(CF.kRunLoopDefaultMode, 0, true)
	}
}

// Keychain access that needs the user's approval fails at once instead of showing a dialog (which
// would block the thread that ticks EOS until answered). Process-wide; for headless tools.
disable_keychain_prompts :: proc() {
	SecKeychainSetUserInteractionAllowed(false)
}
