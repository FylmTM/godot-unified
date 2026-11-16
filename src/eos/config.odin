// EOS product credentials, under one set of names: UNIFIED_EOS_PRODUCT_ID, _SANDBOX_ID, _DEPLOYMENT_ID, _CLIENT_ID
// and _CLIENT_SECRET. Game builds compile them in (`-define:UNIFIED_EOS_PRODUCT_ID=...`, set by `uni build` and
// `uni release` from the same names); the environment is the fallback, which `uni` fills from the project's
// git-ignored .env (docs/EOS.md). Our code never logs them (the SDK's own boot line does, at info); the client
// secret ships inside game builds (EOS game clients work that way) but stays out of the repo.
package eos

import "core:os"

DEF_PRODUCT_ID :: #config(UNIFIED_EOS_PRODUCT_ID, "")
DEF_SANDBOX_ID :: #config(UNIFIED_EOS_SANDBOX_ID, "")
DEF_DEPLOYMENT_ID :: #config(UNIFIED_EOS_DEPLOYMENT_ID, "")
DEF_CLIENT_ID :: #config(UNIFIED_EOS_CLIENT_ID, "")
DEF_CLIENT_SECRET :: #config(UNIFIED_EOS_CLIENT_SECRET, "")

CREDENTIAL_NAMES :: [5]string {
	"UNIFIED_EOS_PRODUCT_ID",
	"UNIFIED_EOS_SANDBOX_ID",
	"UNIFIED_EOS_DEPLOYMENT_ID",
	"UNIFIED_EOS_CLIENT_ID",
	"UNIFIED_EOS_CLIENT_SECRET",
}

Credentials :: struct {
	product_id, sandbox_id, deployment_id, client_id, client_secret: string,
}

// Whether every credential field is set; the SDK cannot start without all five, so online mode stays off.
credentials_complete :: proc(credentials: Credentials) -> bool {
	return(
		credentials.product_id != "" &&
		credentials.sandbox_id != "" &&
		credentials.deployment_id != "" &&
		credentials.client_id != "" &&
		credentials.client_secret != "" \
	)
}

// Compiled-in values first, then the environment; each field independently. Strings are allocated with `allocator`.
credentials_load :: proc(allocator := context.allocator) -> (credentials: Credentials, source: string) {
	credentials = {
		product_id    = DEF_PRODUCT_ID,
		sandbox_id    = DEF_SANDBOX_ID,
		deployment_id = DEF_DEPLOYMENT_ID,
		client_id     = DEF_CLIENT_ID,
		client_secret = DEF_CLIENT_SECRET,
	}
	if credentials_complete(credentials) {
		return credentials, "compiled in"
	}
	fields := [5]^string {
		&credentials.product_id,
		&credentials.sandbox_id,
		&credentials.deployment_id,
		&credentials.client_id,
		&credentials.client_secret,
	}
	names := CREDENTIAL_NAMES
	for field, i in fields {
		if field^ == "" {
			field^ = os.get_env(names[i], allocator)
		}
	}
	return credentials, "environment"
}
