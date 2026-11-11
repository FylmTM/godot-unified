package cli

import "core:os"
import "core:strings"

// The EOS C SDK is not ours to redistribute (Epic's EOS Developer Agreement), so nothing fetches it: each machine
// downloads it from Epic's developer portal and names it with UNIFIED_EOS_SDK (the unzipped root, or its SDK/
// directory; the environment or .env). It is read where it lies: its version (SDK/Include/eos_version.h) must match
// pins.cfg [eos_sdk], and a game's build copies this host's library next to the game's library. Without it a game
// builds and plays single player and LAN; online play needs it. CI has no SDK and no EOS credentials.

// The credentials a release build compiles in, from the environment or .env (empty values are left out). The same
// names are the dev builds' run-time source (src/eos/config.odin).
EOS_ENV_DEFINES :: []string {
	"UNIFIED_EOS_PRODUCT_ID",
	"UNIFIED_EOS_SANDBOX_ID",
	"UNIFIED_EOS_DEPLOYMENT_ID",
	"UNIFIED_EOS_CLIENT_ID",
	"UNIFIED_EOS_CLIENT_SECRET",
}

// This host's SDK runtime library (src/eos/api.odin's LIB_NAME and each .gdextension's [dependencies] name it too).
when ODIN_OS == .Darwin {
	EOS_LIB :: "libEOSSDK-Mac-Shipping.dylib"
} else when ODIN_OS == .Windows {
	EOS_LIB :: "EOSSDK-Win64-Shipping.dll"
} else when ODIN_ARCH == .arm64 {
	EOS_LIB :: "libEOSSDK-LinuxArm64-Shipping.so"
} else {
	EOS_LIB :: "libEOSSDK-Linux-Shipping.so"
}

// The SDK UNIFIED_EOS_SDK names (its root, the folder holding SDK/), or "" when it isn't set.
eos_sdk :: proc() -> string {
	p := os.get_env("UNIFIED_EOS_SDK", context.allocator)
	if p == "" {
		return ""
	}
	if os.base(p) == "SDK" {
		p = os.dir(p)
	}
	return p
}

// The SDK's version from its eos_version.h ("1.19.2.1"), or "" when it can't be read.
eos_sdk_version :: proc(sdk: string) -> string {
	text, ok := read_text(join(sdk, "SDK", "Include", "eos_version.h"))
	if !ok {
		return ""
	}
	parts: [4]string
	names := [4]string{"EOS_MAJOR_VERSION", "EOS_MINOR_VERSION", "EOS_PATCH_VERSION", "EOS_HOTFIX_VERSION"}
	for line in strings.split_lines(text, context.temp_allocator) {
		f := strings.fields(line, context.temp_allocator)
		if len(f) == 3 && f[0] == "#define" {
			for n, i in names do if f[1] == n do parts[i] = f[2]
		}
	}
	for p in parts do if p == "" do return ""
	return tprint("%s.%s.%s.%s", parts[0], parts[1], parts[2], parts[3])
}

// Why the SDK can't be used, or "" when it can: set, the pinned version, this host's library present.
eos_problem :: proc() -> string {
	sdk := eos_sdk()
	if sdk == "" {
		return "UNIFIED_EOS_SDK is not set (download the SDK from Epic's developer portal: docs/EOS.md)"
	}
	v := eos_sdk_version(sdk)
	if v == "" {
		return tprint("UNIFIED_EOS_SDK=%s holds no SDK/Include/eos_version.h", sdk)
	}
	if v != pin("eos_sdk", "version") {
		return tprint("UNIFIED_EOS_SDK=%s is version %s; pins.cfg wants %s", sdk, v, pin("eos_sdk", "version"))
	}
	if !os.is_file(eos_lib()) {
		return tprint("UNIFIED_EOS_SDK=%s has no SDK/Bin/%s", sdk, EOS_LIB)
	}
	return ""
}

eos_ready :: proc() -> bool {
	return eos_problem() == ""
}

eos_lib :: proc() -> string {
	return join(eos_sdk(), "SDK", "Bin", EOS_LIB)
}

// macOS: a browser-downloaded SDK carries com.apple.quarantine, and dlopen of the dylib then blocks in a Gatekeeper
// check that may wait for a prompt. Our copy of the library is ours to change, so drop the flag from it.
unquarantine :: proc(path: string) {
	when ODIN_OS == .Darwin {
		run_proc({cmd = {"xattr", "-d", "com.apple.quarantine", path}, capture = true, quiet = true})
	}
}

// Whether a game's extension imports unified:eos.
extension_uses_eos :: proc(g: Game) -> bool {
	return has_extension(g) && sources_import(join(g.dir, "simulation", "extension"), `"unified:eos"`)
}

// Copies the SDK's library next to the game's library (its .gdextension's [dependencies] ship it from there). The
// library is loaded at run time, so a missing SDK only disables online play: said once, not an error.
stage_eos :: proc(g: Game) {
	if !extension_uses_eos(g) {
		return
	}
	if problem := eos_problem(); problem != "" {
		log("uni: no online play for %s: %s", g.name, problem)
		return
	}
	src := eos_lib()
	dst := join(g.dir, ".out", "bin", EOS_LIB)
	sfi, e1 := os.stat(src, context.temp_allocator)
	dfi, e2 := os.stat(dst, context.temp_allocator)
	if e1 == nil && (e2 != nil || sfi.size != dfi.size) {
		copy_file(dst, src)
		unquarantine(dst)
	}
}

// The -define flags that compile the EOS credentials in, for an extension that imports unified:eos (odin rejects a
// -define nothing declares).
eos_defines :: proc(g: Game) -> []string {
	if !extension_uses_eos(g) {
		return nil
	}
	out: [dynamic]string
	for k in EOS_ENV_DEFINES {
		if v := os.get_env(k, context.allocator); v != "" {
			append(&out, tprint("-define:%s=%s", k, v))
		}
	}
	return out[:]
}
