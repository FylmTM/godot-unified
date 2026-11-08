// EOS product credentials. Release builds compile them in (`-define:EOS_PRODUCT_ID=...`, set by the
// build from the EOS_* environment variables); dev builds read them at run time from the
// environment or from `~/.config/unified/eos.ini` (section [eos], see docs/EOS.md). The values are
// never logged; the client secret ships inside game builds (EOS game clients work that way) but
// stays out of the repo.
package eos

import "core:encoding/ini"
import "core:os"
import "core:path/filepath"
import "core:strings"

DEF_PRODUCT_ID :: #config(EOS_PRODUCT_ID, "")
DEF_SANDBOX_ID :: #config(EOS_SANDBOX_ID, "")
DEF_DEPLOYMENT_ID :: #config(EOS_DEPLOYMENT_ID, "")
DEF_CLIENT_ID :: #config(EOS_CLIENT_ID, "")
DEF_CLIENT_SECRET :: #config(EOS_CLIENT_SECRET, "")

Credentials :: struct {
	product_id, sandbox_id, deployment_id, client_id, client_secret: string,
}

credentials_complete :: proc(c: Credentials) -> bool {
	return(
		c.product_id != "" &&
		c.sandbox_id != "" &&
		c.deployment_id != "" &&
		c.client_id != "" &&
		c.client_secret != "" \
	)
}

// Where the dev credentials file lives: $UNIFIED_EOS_INI, else <home>/.config/unified/eos.ini
// (home = $HOME, or %USERPROFILE% on Windows).
ini_path :: proc(allocator := context.allocator) -> string {
	if p := os.get_env("UNIFIED_EOS_INI", allocator); p != "" {
		return p
	}
	home := os.get_env("HOME", context.temp_allocator)
	if home == "" {
		home = os.get_env("USERPROFILE", context.temp_allocator)
	}
	if home == "" {
		return ""
	}
	p, _ := filepath.join({home, ".config", "unified", "eos.ini"}, allocator)
	return p
}

// Compiled-in values first, then the environment (EOS_PRODUCT_ID, ...), then the ini file; each
// field independently. Strings are allocated with `allocator`.
credentials_load :: proc(allocator := context.allocator) -> (c: Credentials, source: string) {
	c = {
		product_id    = DEF_PRODUCT_ID,
		sandbox_id    = DEF_SANDBOX_ID,
		deployment_id = DEF_DEPLOYMENT_ID,
		client_id     = DEF_CLIENT_ID,
		client_secret = DEF_CLIENT_SECRET,
	}
	if credentials_complete(c) {
		return c, "compiled in"
	}
	source = "environment"
	fields := [5]^string{&c.product_id, &c.sandbox_id, &c.deployment_id, &c.client_id, &c.client_secret}
	envs := [5]string{"EOS_PRODUCT_ID", "EOS_SANDBOX_ID", "EOS_DEPLOYMENT_ID", "EOS_CLIENT_ID", "EOS_CLIENT_SECRET"}
	for f, i in fields {
		if f^ == "" {
			f^ = os.get_env(envs[i], allocator)
		}
	}
	if credentials_complete(c) {
		return
	}
	path := ini_path(context.temp_allocator)
	if path == "" {
		return c, ""
	}
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return c, ""
	}
	keys := [5]string{"product_id", "sandbox_id", "deployment_id", "client_id", "client_secret"}
	m, merr := ini.load_map_from_string(string(data), context.temp_allocator)
	if merr != nil {
		return c, ""
	}
	sec := m["eos"]
	for f, i in fields {
		if f^ == "" {
			if v, has := sec[keys[i]]; has {
				f^ = strings.clone(strings.trim_space(v), allocator)
			}
		}
	}
	return c, "ini"
}
