package cli

import "core:os"
import "core:strings"
import "core:time"

// The EOS C SDK files unified needs, in third_party/eos/ (git-ignored): the headers, VERSION, and each platform's
// shipping library. From the local SDK UNIFIED_EOS_SDK names (the unzipped root or its SDK/ directory), else this
// host's part of the draft release eos-sdk-<version> (needs gh with access to the repo), checked against its pin.

// Each release part: its libraries (each zip also holds SDK/Include/* and VERSION).
EOS_PARTS :: [][2]string {
	{"macos", "SDK/Bin/libEOSSDK-Mac-Shipping.dylib"},
	{"windows-x64", "SDK/Bin/EOSSDK-Win64-Shipping.dll"},
	{"windows-x64", "SDK/Lib/EOSSDK-Win64-Shipping.lib"},
	{"linux-x64", "SDK/Bin/libEOSSDK-Linux-Shipping.so"},
	{"linux-arm64", "SDK/Bin/libEOSSDK-LinuxArm64-Shipping.so"},
}
// The credentials a release build compiles in (from the environment, or .env); empty values are left out.
EOS_ENV_DEFINES :: []string {
	"EOS_PRODUCT_ID",
	"EOS_SANDBOX_ID",
	"EOS_DEPLOYMENT_ID",
	"EOS_CLIENT_ID",
	"EOS_CLIENT_SECRET",
}

eos_part :: proc() -> string {
	return ODIN_OS == .Darwin ? "macos" : PLATFORM
}

eos_root :: proc() -> string {
	return join(state.project.unified, "third_party", "eos")
}

// The SDK's runtime library for this host (src/eos/api.odin's LIB_NAME and each .gdextension's [dependencies] name
// it too).
eos_lib :: proc() -> string {
	when ODIN_OS == .Darwin {
		name :: "libEOSSDK-Mac-Shipping.dylib"
	} else when ODIN_OS == .Windows {
		name :: "EOSSDK-Win64-Shipping.dll"
	} else when ODIN_ARCH == .arm64 {
		name :: "libEOSSDK-LinuxArm64-Shipping.so"
	} else {
		name :: "libEOSSDK-Linux-Shipping.so"
	}
	return join(eos_root(), "SDK", "Bin", name)
}

eos_ready :: proc() -> bool {
	root := eos_root()
	v, ok := read_text(join(root, "VERSION"))
	if !ok ||
	   strings.trim_space(v) != pin("eos_sdk", "version") ||
	   !os.is_file(join(root, "SDK", "Include", "eos_sdk.h")) {
		return false
	}
	for p in EOS_PARTS {
		if p[0] == eos_part() && !os.is_file(join(root, p[1])) {
			return false
		}
	}
	return true
}

// The local SDK UNIFIED_EOS_SDK names, or "".
eos_local_sdk :: proc() -> string {
	p := os.get_env("UNIFIED_EOS_SDK", context.allocator)
	if p == "" {
		return ""
	}
	if os.base(p) == "SDK" {
		p = os.dir(p)
	}
	if !os.is_file(join(p, "SDK", "Include", "eos_sdk.h")) {
		fatal("UNIFIED_EOS_SDK=%s holds no SDK/Include/eos_sdk.h", p)
	}
	return p
}

// Makes third_party/eos/ hold the pinned SDK. Returns a message when it can't (the caller decides how bad that is).
ensure_eos :: proc() -> (problem: string) {
	if eos_ready() {
		return ""
	}
	start := time.tick_now()
	root := eos_root()
	if src := eos_local_sdk(); src != "" {
		log("uni: copying the EOS SDK from %s", src)
		remove_tree(root)
		for h in find_files(join(src, "SDK", "Include"), "") {
			copy_file(join(root, h[len(src) + 1:]), h)
		}
		for p in EOS_PARTS {
			if !os.is_file(join(src, p[1])) {
				return tprint("%s is missing in %s", p[1], src)
			}
			copy_file(join(root, p[1]), join(src, p[1]))
		}
		write_text(join(root, "VERSION"), tprint("%s\n", pin("eos_sdk", "version")))
	} else {
		if which("gh") == "" {
			return "no UNIFIED_EOS_SDK and no gh to fetch the SDK from the draft release"
		}
		part := eos_part()
		name := tprint("eos-sdk-%s-%s.zip", pin("eos_sdk", "version"), part)
		tmp := join(state.project.out, "eos-download")
		remove_tree(tmp)
		make_dirs(tmp)
		log("uni: downloading %s from the draft release", name)
		r := run_proc(
			{
				cmd = {
					"gh",
					"release",
					"download",
					tprint("eos-sdk-%s", pin("eos_sdk", "version")),
					"-R",
					pin("eos_sdk", "repo"),
					"-p",
					name,
					"-D",
					tmp,
				},
				capture = true,
				quiet = true,
			},
		)
		if !r.ok {
			return tprint("gh release download failed: %s", strings.trim_space(r.stderr))
		}
		zip := join(tmp, name)
		check_sha256(zip, pin("eos_sdk", part), name)
		remove_tree(root)
		z := zip_open_file(zip)
		zip_extract_all(&z, root)
		remove_tree(tmp)
		cold("EOS SDK download")
	}
	unquarantine(root)
	if !eos_ready() {
		return tprint("%s is incomplete after setup", root)
	}
	log("uni: EOS SDK %s ready in %.1fs", pin("eos_sdk", "version"), seconds_since(start))
	return ""
}

// macOS: a browser-downloaded SDK carries com.apple.quarantine, and dlopen of the dylib then blocks in a Gatekeeper
// check that may wait for a prompt. The staged copy is ours, so drop the flag from it.
unquarantine :: proc(dir: string) {
	when ODIN_OS == .Darwin {
		run_proc({cmd = {"xattr", "-dr", "com.apple.quarantine", dir}, capture = true, quiet = true})
	}
}

// Whether a game's extension imports unified:eos.
extension_uses_eos :: proc(g: Game) -> bool {
	return has_extension(g) && sources_import(join(g.dir, "simulation", "extension"), `"unified:eos"`)
}

// Copies the SDK's library next to the game's library (its .gdextension's [dependencies] ship it from there). The
// library is loaded at run time, so a missing SDK only disables online play: a warning here, an error for release.
stage_eos :: proc(g: Game) {
	if !extension_uses_eos(g) {
		return
	}
	if problem := ensure_eos(); problem != "" {
		log("uni: warning: EOS SDK not staged (%s); online play will be unavailable", problem)
		return
	}
	src := eos_lib()
	dst := join(g.dir, ".out", "bin", os.base(src))
	sfi, e1 := os.stat(src, context.temp_allocator)
	dfi, e2 := os.stat(dst, context.temp_allocator)
	if e1 == nil && (e2 != nil || sfi.size != dfi.size) {
		copy_file(dst, src)
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
