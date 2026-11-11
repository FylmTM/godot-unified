package main

import "core:os"
import "core:strings"

import "unified:cli"

// `eos upload`: packs the pruned EOS SDK, one reproducible zip per part (the headers, VERSION and one platform's
// libraries; fixed timestamps, sorted entries), from the full SDK UNIFIED_EOS_SDK names, and uploads them to the
// draft release eos-sdk-<version> (never published: no git tag exists until then). Prints the hashes to pin in
// pins.cfg [eos_sdk].
cmd_eos :: proc(args: []string) -> cli.Result {
	if len(args) == 0 || args[0] != "upload" {
		if len(args) > 0 && (args[0] == "-h" || args[0] == "--help") {
			Opts :: struct {}
			opts: Opts
			cli.parse(&opts, args)
		}
		cli.usage("eos upload")
	}
	Opts :: struct {}
	opts: Opts
	cli.parse(&opts, args[1:])
	src := cli.eos_local_sdk()
	if src == "" {
		cli.fatal("eos upload packs the full SDK: set UNIFIED_EOS_SDK (the environment or .env)")
	}
	version := cli.pin("eos_sdk", "version")
	repo := cli.pin("eos_sdk", "repo")
	release := cli.tprint("eos-sdk-%s", version)
	headers := cli.find_files(cli.join(src, "SDK", "Include"), "")
	parts: [dynamic]string
	for p in cli.EOS_PARTS {
		found := false
		for q in parts {
			found = found || q == p[0]
		}
		if !found {
			append(&parts, p[0])
		}
	}
	zips: [dynamic]string
	pins := strings.builder_make()
	for part in parts {
		w: cli.Zip_Writer
		cli.zip_add(&w, "VERSION", transmute([]byte)cli.tprint("%s\n", version))
		files: [dynamic]string
		for h in headers {
			append(&files, h[len(src) + 1:])
		}
		for p in cli.EOS_PARTS {
			if p[0] == part {
				append(&files, p[1])
			}
		}
		for f in files {
			rel, _ := strings.replace_all(f, "\\", "/")
			cli.zip_add(&w, rel, transmute([]byte)cli.must_read(cli.join(src, f)))
		}
		out := cli.join(cli.state.project.out, cli.tprint("%s-%s.zip", release, part))
		if !cli.write_file(out, cli.zip_finish(&w)) {
			cli.fatal("cannot write %s", out)
		}
		sum, _ := cli.sha256_file(out)
		strings.write_string(&pins, cli.tprint("%s = \"%s\"\n", part, sum))
		append(&zips, out)
		cli.log("eos: packed %s", os.base(out))
	}
	if !cli.run_proc({cmd = cli.strs("gh", "release", "view", release, "-R", repo), capture = true, quiet = true}).ok {
		cli.must_run(
			{
				cmd = cli.strs(
					"gh",
					"release",
					"create",
					release,
					"-R",
					repo,
					"--draft",
					"--title",
					cli.tprint("EOS SDK %s (CI dependency)", version),
					"--notes",
					"Pruned EOS C SDK for CI (headers + macOS/Windows/Linux x64+arm64 shipping libraries). Fetched by `unified setup`. Not a game release; never publish.",
				),
			},
			"creating the release",
		)
	}
	for z in zips {
		cli.must_run(
			{cmd = cli.strs("gh", "release", "upload", release, z, "-R", repo, "--clobber")},
			cli.tprint("uploading %s", os.base(z)),
		)
	}
	cli.log("eos: pin these in pins.cfg [eos_sdk]:\n%s", strings.to_string(pins))
	return {ok = true, summary = cli.tprint("eos: uploaded %d parts to the draft release %s", len(zips), release)}
}
