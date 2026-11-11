package cli

import "core:os"
import "core:slice"
import "core:strings"

// The public commands (SPEC.md, Commands): every project's CLI has them.
public_commands :: proc() -> []Command {
	return slice.clone(
		[]Command {
			{
				name = "version",
				summary = "the CLI's source hash, Odin, and the pins",
				budget = 1,
				run = cmd_version,
			},
		},
	)
}

@(private)
cmd_version :: proc(args: []string) -> Result {
	Opts :: struct {}
	opts: Opts
	parse(&opts, args)
	exe, _ := os.get_executable_path(context.temp_allocator)
	Version :: struct {
		cli:      string,
		odin:     string,
		platform: string,
		project:  string,
		unified:  string,
		env:      []string,
		pins:     map[string]map[string]string,
	}
	v := new(Version)
	v^ = {
		cli      = os.base(exe),
		odin     = tprint("%s:%s", ODIN_VERSION, ODIN_VERSION_HASH),
		platform = PLATFORM,
		project  = state.project.root,
		unified  = state.project.unified,
		env      = state.env_keys,
		pins     = state.pins.sections,
	}
	return {ok = true, summary = strings.join({v.cli, v.odin, v.platform}, " "), data = v^}
}
